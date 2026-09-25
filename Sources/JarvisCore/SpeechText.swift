import Foundation

/// Turns a Markdown answer into text worth hearing. The model writes Markdown for the screen;
/// espeak reads "*" as "asterisk" and "#" as "hash", a URL letter by letter, and a line with no
/// end punctuation runs straight into the next one. Plain string work, no model involved.
public enum SpeechText {
    public static let codeNote = "Code is shown on screen."

    public static func spoken(from text: String, limit: Int = 2200) -> String {
        var body = text.replacingOccurrences(of: "\r\n", with: "\n")
        body = body.replacingOccurrences(of: "[Response length limit reached.]", with: "")
        body = body.replacing(pattern: "(?s)```.*?(?:```|\\z)", with: "\n\(codeNote)\n")
        var lines: [String] = []
        for raw in body.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = String(raw).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.matches("^([-*_]\\s*){3,}$") { continue }
            if line.matches("^[\\s|:\\-]+$") && line.contains("-") { continue }
            if line.hasPrefix("|") {
                line = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: ", ")
            }
            line = line.replacing(pattern: "^#{1,6}\\s+", with: "")
            line = line.replacing(pattern: "^(>\\s*)+", with: "")
            line = line.replacing(pattern: "^[-*+]\\s+", with: "")
            line = line.replacing(pattern: "^(\\d+)[.)]\\s+", with: "$1. ")
            line = inline(line)
            guard !line.isEmpty else { continue }
            if let last = line.last, !".!?:;,".contains(last) { line += "." }
            lines.append(line)
        }
        let joined = lines.joined(separator: " ").replacing(pattern: "\\s+", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return truncated(joined, limit: limit)
    }

    static func inline(_ text: String) -> String {
        var line = text
        line = line.replacing(pattern: "!?\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1")
        line = line.replacing(pattern: "<(https?://[^>\\s]+)>", with: "$1")
        line = hosts(in: line)
        line = line.replacing(pattern: "`([^`\\n]*)`", with: "$1")
        line = line.replacing(pattern: "\\*\\*(.+?)\\*\\*", with: "$1")
        line = line.replacing(pattern: "__(.+?)__", with: "$1")
        line = line.replacing(pattern: "~~(.+?)~~", with: "$1")
        line = line.replacing(pattern: "\\*([^*\\n]+)\\*", with: "$1")
        line = line.replacing(pattern: "(?<![\\w])_([^_\\n]+)_(?![\\w])", with: "$1")
        line = line.replacing(pattern: "\\s*(?:->|=>|→|⇒)\\s*", with: " to ")
        line = String(String.UnicodeScalarView(line.unicodeScalars.filter { !isEmoji($0) }))
        line = line.replacing(pattern: "[*#`~]+", with: "")
        line = line.replacing(pattern: "[ \\t]+", with: " ")
        return line.trimmingCharacters(in: .whitespaces)
    }

    /// A URL read letter by letter is noise; the host is enough to tell the listener where to look.
    static func hosts(in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "https?://[^\\s)\\]>]+") else { return text }
        let result = NSMutableString(string: text)
        let trailing = CharacterSet(charactersIn: ".,;:!?")
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            let full = result.substring(with: match.range)
            let trimmed = full.trimmingCharacters(in: trailing)
            let suffix = String(full.dropFirst(trimmed.count))
            var host = URL(string: trimmed)?.host ?? ""
            if host.hasPrefix("www.") { host.removeFirst(4) }
            result.replaceCharacters(in: match.range, with: host + suffix)
        }
        return result as String
    }

    static func isEmoji(_ scalar: Unicode.Scalar) -> Bool {
        if [0xFE0F, 0x200D, 0x20E3].contains(scalar.value) { return true }
        let properties = scalar.properties
        return properties.isEmojiPresentation || (properties.isEmoji && scalar.value >= 0x2600)
    }

    static func truncated(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let head = String(text.prefix(limit))
        if let end = head.lastIndex(where: { ".!?".contains($0) }) { return String(head[...end]) }
        if let space = head.lastIndex(of: " ") { return String(head[..<space]) + "." }
        return head
    }
}

private extension String {
    func replacing(pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return self }
        return regex.stringByReplacingMatches(in: self, range: NSRange(startIndex..., in: self), withTemplate: template)
    }
    func matches(_ pattern: String) -> Bool { range(of: pattern, options: .regularExpression) != nil }
}
