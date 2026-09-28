import Foundation

/// The block structure of an answer: paragraphs, headings, lists, code, quotes, tables, rules.
/// Inline styling (bold, code spans, links) is left to the view. Works on partial text too, so a
/// streaming answer with an unclosed code fence renders as code so far.
public enum MarkdownBlock: Equatable, Sendable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case list(ordered: Bool, items: [String])
    case code(language: String?, text: String)
    case quote(String)
    case table(rows: [[String]])
    case rule
}

public enum MarkdownBlocks {
    public static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var table: [[String]] = []
        var list: (ordered: Bool, items: [String])?
        var code: (language: String?, lines: [String])?

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] }
            if !table.isEmpty { blocks.append(.table(rows: table)); table = [] }
            if let current = list { blocks.append(.list(ordered: current.ordered, items: current.items)); list = nil }
        }

        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if var open = code {
                if line.hasPrefix("```") { blocks.append(.code(language: open.language, text: open.lines.joined(separator: "\n"))); code = nil }
                else { open.lines.append(raw); code = open }
                continue
            }
            if line.hasPrefix("```") {
                flush()
                let language = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                code = (language.isEmpty ? nil : language, [])
                continue
            }
            if line.isEmpty { flush(); continue }
            if let level = heading(line) {
                flush()
                blocks.append(.heading(level: level, text: String(line.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if isRule(line) { flush(); blocks.append(.rule); continue }
            if line.hasPrefix("|") {
                if table.isEmpty { flush() }
                let cells = line.trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                // The |---|:---:| row only separates the header.
                let separator = cells.allSatisfy { !$0.isEmpty && $0.allSatisfy { "-: ".contains($0) } }
                if !separator { table.append(cells) }
                continue
            }
            if line.hasPrefix(">") {
                if quote.isEmpty { flush() }
                quote.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            if let (ordered, item) = listItem(line) {
                if list == nil || list?.ordered != ordered { flush(); list = (ordered, []) }
                list?.items.append(item)
                continue
            }
            if list != nil, raw.hasPrefix("  "), var current = list, !current.items.isEmpty {
                // An indented line continues the previous item.
                current.items[current.items.count - 1] += " " + line
                list = current
                continue
            }
            if !quote.isEmpty || !table.isEmpty || list != nil { flush() }
            paragraph.append(line)
        }
        if let open = code { blocks.append(.code(language: open.language, text: open.lines.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    static func heading(_ line: String) -> Int? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    static func isRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    static func listItem(_ line: String) -> (Bool, String)? {
        if let first = line.first, "-*+•".contains(first), line.dropFirst().first == " " {
            return (false, String(line.dropFirst(2)))
        }
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let marker = rest.first, marker == "." || marker == ")", rest.dropFirst().first == " " else { return nil }
        return (true, String(rest.dropFirst(2)))
    }
}
