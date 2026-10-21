import Foundation

enum LogReader {
    private static let escapes = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]|\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)|\u{1B}[()][A-Z0-9]")

    static func size(_ url: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    static func read(_ url: URL, from offset: UInt64, to end: UInt64) -> (text: String, end: UInt64) {
        guard end > offset, let handle = try? FileHandle(forReadingFrom: url) else { return ("", offset) }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        let data = (try? handle.read(upToCount: Int(end - offset))) ?? Data()
        let length = completeLength(data)
        return (clean(String(decoding: data.prefix(length), as: UTF8.self)), offset + UInt64(length))
    }

    static func lastLines(_ url: URL, count: Int) -> [String] {
        let end = size(url)
        let start = end > 16_384 ? end - 16_384 : 0
        var lines = read(url, from: start, to: end).text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if start > 0, !lines.isEmpty {
            lines.removeFirst()
        }
        return Array(lines.filter { !$0.isEmpty }.suffix(count))
    }

    static func clean(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return escapes.stringByReplacingMatches(in: text, range: range, withTemplate: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
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
