import AppKit
import RunyardCore

final class LogFormatter {
    private static let escapes = try! NSRegularExpression(pattern: LogReader.escapePattern)
    private static let highlights: [(NSRegularExpression, Int, (String) -> NSColor?)] = [
        (regex("^===== .* =====$"), 0, { $0.contains("código 0") ? .systemGreen : $0.contains("encerrado") || $0.contains("falha") ? .systemRed : .systemBlue }),
        (regex("\\b(fatal|panic|critical|emergency|alert|error|err|exception|failed|failure|uncaught|erro|falha|falhou)\\b", insensitive: true), 0, { _ in .systemRed }),
        (regex("\\b(warn|warning|deprecated|aviso)\\b", insensitive: true), 0, { _ in .systemOrange }),
        (regex("\\b(info|notice|ready|success|started|listening)\\b", insensitive: true), 0, { _ in .systemGreen }),
        (regex("\\b(debug|trace|verbose)\\b", insensitive: true), 0, { _ in .secondaryLabelColor }),
        (regex("\\b(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)\\b"), 0, { _ in .systemPurple }),
        (regex("\\b(?:GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)\\b.*?\\b([1-5]\\d{2})\\b"), 1, { statusColor($0) }),
        (regex("\\d{4}-\\d{2}-\\d{2}[T ]\\d{2}:\\d{2}:\\d{2}(?:[.,]\\d+)?(?:Z|[+-]\\d{2}:?\\d{2})?"), 0, { _ in .tertiaryLabelColor }),
        (regex("\\b\\d{2}:\\d{2}:\\d{2}(?:[.,]\\d+)?\\b"), 0, { _ in .tertiaryLabelColor }),
        (regex("(?<=\\s)[A-Za-z_][\\w.-]*(?==)"), 0, { _ in .secondaryLabelColor })
    ]
    private static let urls = regex("https?://[^\\s\"'<>()\\[\\]]+")
    private static let levelNames: [Int: String] = [10: "TRACE", 20: "DEBUG", 30: "INFO", 40: "WARN", 50: "ERROR", 60: "FATAL"]

    private let font: NSFont
    private let boldFont: NSFont
    private var color: NSColor?
    private var bold = false
    private var dim = false

    init(font: NSFont) {
        self.font = font
        boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    }

    func reset() {
        color = nil
        bold = false
        dim = false
    }

    func format(_ raw: String) -> NSAttributedString {
        let output = parseEscapes(organizeJSON(raw))
        let text = output.string
        let range = NSRange(location: 0, length: output.length)

        Self.urls.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match, let url = URL(string: (text as NSString).substring(with: match.range)) else { return }
            output.addAttribute(.link, value: url, range: match.range)
        }
        for (pattern, group, pick) in Self.highlights {
            pattern.enumerateMatches(in: text, range: range) { match, _, _ in
                guard let target = match?.range(at: group), target.location != NSNotFound,
                      output.attribute(.foregroundColor, at: target.location, effectiveRange: nil) == nil,
                      output.attribute(.link, at: target.location, effectiveRange: nil) == nil,
                      let color = pick((text as NSString).substring(with: target)) else { return }
                output.addAttribute(.foregroundColor, value: color, range: target)
            }
        }
        output.enumerateAttribute(.foregroundColor, in: range) { value, subrange, _ in
            if value == nil {
                output.addAttribute(.foregroundColor, value: NSColor.labelColor, range: subrange)
            }
        }
        return output
    }

    private func parseEscapes(_ raw: String) -> NSMutableAttributedString {
        let output = NSMutableAttributedString()
        let source = raw as NSString
        var cursor = 0
        Self.escapes.enumerateMatches(in: raw, range: NSRange(location: 0, length: source.length)) { match, _, _ in
            guard let match else { return }
            append(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)), to: output)
            cursor = match.range.location + match.range.length
            let final = match.range(at: 2)
            if final.location != NSNotFound, source.substring(with: final) == "m" {
                apply(source.substring(with: match.range(at: 1)))
            }
        }
        append(source.substring(from: cursor), to: output)
        return output
    }

    private func append(_ text: String, to output: NSMutableAttributedString) {
        guard !text.isEmpty else { return }
        var attributes: [NSAttributedString.Key: Any] = [.font: bold ? boldFont : font]
        if let color {
            attributes[.foregroundColor] = dim ? color.withAlphaComponent(0.6) : color
        } else if dim {
            attributes[.foregroundColor] = NSColor.secondaryLabelColor
        }
        output.append(NSAttributedString(string: text, attributes: attributes))
    }

    private func apply(_ parameters: String) {
        var codes = parameters.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        if codes.isEmpty {
            codes = [0]
        }
        var index = 0
        while index < codes.count {
            let code = codes[index]
            switch code {
            case 0:
                reset()
            case 1:
                bold = true
            case 2:
                dim = true
            case 22:
                bold = false
                dim = false
            case 30...37:
                color = Self.basic(code - 30)
            case 90...97:
                color = Self.basic(code - 90 + 8)
            case 39:
                color = nil
            case 38 where index + 2 < codes.count && codes[index + 1] == 5:
                color = Self.indexed(codes[index + 2])
                index += 2
            case 38 where index + 4 < codes.count && codes[index + 1] == 2:
                color = NSColor(srgbRed: CGFloat(codes[index + 2]) / 255, green: CGFloat(codes[index + 3]) / 255, blue: CGFloat(codes[index + 4]) / 255, alpha: 1)
                index += 4
            case 48 where index + 1 < codes.count:
                index += codes[index + 1] == 5 ? 2 : codes[index + 1] == 2 ? 4 : 0
            default:
                break
            }
            index += 1
        }
    }

    private func organizeJSON(_ raw: String) -> String {
        guard raw.contains("{") else { return raw }
        return raw.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}"),
                  let data = trimmed.data(using: .utf8),
                  var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return String(line) }
            var parts: [String] = []
            if let time = Self.take(&object, ["time", "timestamp", "datetime", "ts", "@timestamp"]) {
                parts.append(Self.describeTime(time))
            }
            if let level = Self.take(&object, ["level", "level_name", "severity", "lvl"]) {
                parts.append(Self.describeLevel(level))
            }
            if let message = Self.take(&object, ["msg", "message"]) {
                parts.append("\(message)")
            }
            for key in object.keys.sorted() {
                parts.append("\(key)=\(Self.describe(object[key] as Any))")
            }
            return parts.joined(separator: " ")
        }.joined(separator: "\n")
    }

    private static func take(_ object: inout [String: Any], _ keys: [String]) -> Any? {
        for key in keys {
            if let value = object.removeValue(forKey: key) { return value }
        }
        return nil
    }

    private static func describeLevel(_ value: Any) -> String {
        if let number = value as? Int {
            return levelNames[number] ?? "\(number)"
        }
        return "\(value)".uppercased()
    }

    private static func describeTime(_ value: Any) -> String {
        guard let number = value as? Double else { return "\(value)" }
        let seconds = number > 1_000_000_000_000 ? number / 1000 : number
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date(timeIntervalSince1970: seconds))
    }

    private static func describe(_ value: Any) -> String {
        if let string = value as? String {
            return string.contains(" ") ? "\"\(string)\"" : string
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) {
            return String(decoding: data, as: UTF8.self)
        }
        return "\(value)"
    }

    private static func statusColor(_ code: String) -> NSColor? {
        switch code.first {
        case "2": .systemGreen
        case "3": .systemTeal
        case "4": .systemOrange
        case "5": .systemRed
        default: nil
        }
    }

    private static func basic(_ index: Int) -> NSColor {
        switch index % 8 {
        case 0: index >= 8 ? .secondaryLabelColor : .tertiaryLabelColor
        case 1: .systemRed
        case 2: .systemGreen
        case 3: .systemYellow
        case 4: .systemBlue
        case 5: .systemPink
        case 6: .systemTeal
        default: .labelColor
        }
    }

    private static func indexed(_ index: Int) -> NSColor {
        switch index {
        case 0..<16:
            return basic(index)
        case 16..<232:
            let value = index - 16
            let level = { (step: Int) in step == 0 ? 0 : CGFloat(55 + step * 40) / 255 }
            return NSColor(srgbRed: level(value / 36), green: level(value / 6 % 6), blue: level(value % 6), alpha: 1)
        default:
            let gray = CGFloat(8 + (index - 232) * 10) / 255
            return NSColor(white: gray, alpha: 1)
        }
    }

    private static func regex(_ pattern: String, insensitive: Bool = false) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: insensitive ? [.caseInsensitive, .anchorsMatchLines] : [.anchorsMatchLines])
    }
}
