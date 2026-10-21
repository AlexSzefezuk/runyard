import Foundation

public enum LogReader {
    public static let escapePattern = "\u{1B}\\[([0-9;?]*)[ -/]*([@-~])|\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)|\u{1B}[()][A-Z0-9]"
    private static let escapes = try! NSRegularExpression(pattern: escapePattern)

    public static func size(_ url: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    public static func read(_ url: URL, from offset: UInt64, to end: UInt64) -> (text: String, end: UInt64) {
        guard end > offset, let handle = try? FileHandle(forReadingFrom: url) else { return ("", offset) }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        let data = (try? handle.read(upToCount: Int(end - offset))) ?? Data()
        let length = completeLength(data)
        let text = String(decoding: data.prefix(length), as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        return (text, offset + UInt64(length))
    }

    public static func lastLines(_ url: URL, count: Int, compact: Bool = true) -> [String] {
        let end = size(url)
        var window: UInt64 = 16_384
        while true {
            let start = end > window ? end - window : 0
            var lines = clean(read(url, from: start, to: end).text)
                .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                .map(String.init)
            if start > 0, !lines.isEmpty {
                lines.removeFirst()
            }
            if compact {
                lines = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            } else if lines.last == "" {
                lines.removeLast()
            }
            if lines.count >= count || start == 0 {
                return Array(lines.suffix(count))
            }
            window *= 4
        }
    }

    public static func clean(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return escapes.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    private static func completeLength(_ data: Data) -> Int {
        let tail = Array(data.suffix(4))
        for back in stride(from: 1, through: tail.count, by: 1) {
            let byte = tail[tail.count - back]
            if byte & 0xC0 == 0x80 { continue }
            let needed = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
            return needed > back ? data.count - back : data.count
        }
        return data.count
    }
}
