import Foundation

/// Turns a Markdown answer into text worth hearing. The model writes Markdown for the screen;
/// espeak reads "*" as "asterisk" and "#" as "hash", a URL letter by letter, and a line with no
/// end punctuation runs straight into the next one. Numbers, times, dates, money and common
/// abbreviations come out as words (`SpokenWords`). Plain string work, no model involved.
public enum SpeechText {
    public static let codeNote = "Code is shown on screen."
    /// A chunk shorter than this sounds clipped on its own, so it's merged into a neighbour.
    public static let shortFragment = 24

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
            // A line that started with a number or symbol ("1. Open it", "$5 is fine") still starts
            // with a capital once that's a word.
            let numbered = line.first?.isLetter == false
            line = SpokenWords.expand(line).trimmingCharacters(in: .whitespaces)
            guard let first = line.first else { continue }
            if numbered, first.isLowercase { line = first.uppercased() + line.dropFirst() }
            if let last = line.last(where: { !closers.contains($0) }), !".!?:;,".contains(last) { line += "." }
            lines.append(line)
        }
        let joined = lines.joined(separator: " ").replacing(pattern: "\\s+", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return truncated(joined, limit: limit)
    }

    /// Chunks for sentence-by-sentence synthesis: the first is short so audio starts early, later
    /// ones are longer so the voice keeps its flow. Boundaries are sentence ends only, and a piece
    /// too short to sound right alone joins its neighbour: under `SpeechFeed.minimumChunk` for the
    /// first chunk ("Sure."), so a real first sentence still starts the audio, and under
    /// `shortFragment` after that ("Found it.").
    public static func sentences(from spoken: String, firstTarget: Int = 60, target: Int = 160, maximum: Int = 600) -> [String] {
        let text = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let characters = Array(text)
        var pieces: [String] = []
        var start = 0
        for end in sentenceBreaks(in: characters) + [characters.count] where end > start {
            let piece = String(characters[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { pieces.append(piece) }
            start = end
        }
        var chunks: [String] = []
        var chunk = ""
        for piece in pieces {
            let goal = chunks.isEmpty ? firstTarget : target
            let short = chunks.isEmpty ? SpeechFeed.minimumChunk : shortFragment
            let grown = chunk.count + piece.count + 1
            if !chunk.isEmpty, grown > maximum || (chunk.count >= short && (chunk.count >= goal || grown > goal + goal / 2)) {
                chunks.append(chunk); chunk = ""
            }
            chunk = chunk.isEmpty ? piece : chunk + " " + piece
            while chunk.count > maximum, let cut = chunk.prefix(maximum).lastIndex(of: " ") {
                chunks.append(String(chunk[..<cut])); chunk = String(chunk[chunk.index(after: cut)...])
            }
        }
        if !chunk.isEmpty {
            if chunk.count < shortFragment, let last = chunks.last, last.count + chunk.count + 1 <= maximum {
                chunks[chunks.count - 1] = last + " " + chunk
            } else {
                chunks.append(chunk)
            }
        }
        return chunks
    }

    /// Quotes, brackets and Markdown marks that can close a sentence after its final mark ("**Done.**").
    static let closers: Set<Character> = ["\"", "'", "”", "’", ")", "]", "*", "`"]
    /// Words after which a period rarely ends the sentence: lowercased, without the period.
    /// Dotted ones ("e.g.", "U.S.", "p.m.") are caught by their inner period.
    static let abbreviations: Set<String> = ["mr", "mrs", "ms", "dr", "prof", "st", "jr", "sr", "vs", "etc", "approx", "no",
        "inc", "ltd", "co", "corp", "dept", "est", "fig", "vol", "mt",
        "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec"]

    /// Where each sentence ends: just past its mark and any closing quotes or brackets, when a
    /// space or the end of the text follows. A period only counts after a real word: not after a
    /// number ("1." in a list, "3.5"), an initial ("J."), "..." or an abbreviation ("Dr.", "e.g.").
    static func sentenceBreaks(in characters: [Character]) -> [Int] {
        var breaks: [Int] = []
        for index in characters.indices where ".!?".contains(characters[index]) {
            var end = index + 1
            while end < characters.count, closers.contains(characters[end]) { end += 1 }
            guard end == characters.count || characters[end].isWhitespace else { continue }
            if characters[index] == "." {
                // The word itself, without Markdown or brackets around it: "**Oct." is "oct".
                var start = index
                while start > 0, characters[start - 1].isLetter || characters[start - 1].isNumber || ".'’".contains(characters[start - 1]) {
                    start -= 1
                }
                let word = String(characters[start..<index]).lowercased()
                if let last = word.last, last.isNumber || word.contains(".") || abbreviations.contains(word) || (word.count == 1 && last.isLetter) {
                    continue
                }
            }
            breaks.append(end)
        }
        return breaks
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
        // "#3" and "~5" are words ("number three", "about five"); elsewhere they're Markdown.
        line = line.replacing(pattern: "[*`]+|#+(?!\\d)|~+(?!\\d)", with: "")
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

/// Numbers, times, dates, money and abbreviations written out the way an American reads them.
/// espeak gets these wrong: the point in "3.5" and the periods in "e.g." turn into full stops,
/// "$4.50" comes out as "dollar four. fifty", "3:30" as "three: thirty", 2026-10-15 with "dash"es.
/// Rules see one line and at most the word after a match, and `SpeechFeed` never cuts an answer
/// right after an abbreviation, so a streamed answer reads the same as the whole one.
enum SpokenWords {
    static func expand(_ line: String) -> String {
        rules.reduce(line) { text, rule in rule.apply(to: text) }
    }

    private static let monthNames = "Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec|January|February|March|April|June|July|August|September|October|November|December"
    /// "5", "1,299", "4.50"; never ending on the comma in "$5, not $10".
    private static let amount = #"\d(?:[\d,]*\d)?(?:\.\d+)?"#

    private static let rules: [Rewrite] = [
        // A spaced hyphen is a dash, which Kokoro pauses on; between two numbers it's left for the ranges below.
        Rewrite(#"(?<=(\S)) - (?=(\S))"#) { match in
            match[1]?.first?.isNumber == true && match[2]?.first?.isNumber == true ? nil : " — "
        },
        // Symbols that stand for words.
        Rewrite(#"[~≈]\s?(?=[\d$€£.])"#) { _ in "about " },
        Rewrite(#"±\s?"#) { _ in "plus or minus " },
        Rewrite(#"≥\s?"#) { _ in "at least " },
        Rewrite(#"≤\s?"#) { _ in "at most " },
        Rewrite(#"\s?×\s?"#) { _ in " times " },
        Rewrite(#"#(?=\d)"#) { _ in "number " },
        Rewrite(#"\b[Nn]o\.\s?(?=\d)"#) { _ in "number " },

        // Abbreviations.
        Rewrite(#"\b([Ee])\.\s?g\.(,)?"#) { match in cased("for example", like: match[1]) + match.comma },
        Rewrite(#"\b([Ii])\.\s?e\.(,)?"#) { match in cased("that is", like: match[1]) + match.comma },
        Rewrite(#"(?<![\w.])(?:[Aa]\.[Kk]\.[Aa]\.|aka|AKA)(?!\w)"#) { _ in "also known as" },
        Rewrite(#"\b[Ww]/o\b"#) { _ in "without" },
        Rewrite(#"\b[Ww]/(?=\s)"#) { _ in "with" },
        Rewrite(#"\b([Vv])s\.?(?=\s)"#) { match in cased("versus", like: match[1]) },
        Rewrite(#"\b([Aa])pprox\.(?=\s)"#) { match in cased("approximately", like: match[1]) },
        Rewrite(#"\b(Mr|Mrs|Ms|Dr|Prof)\.?\s+(?=[A-Z])"#) { match in
            ["Mr": "Mister ", "Mrs": "Missus ", "Ms": "Miz ", "Dr": "Doctor ", "Prof": "Professor "][match[1] ?? ""]
        },
        Rewrite(#"\bSt\.(?=\s+[A-Z]|\s*$)"#) { match in match.followsCapitalizedWord ? "Street" + match.period : "Saint" },
        Rewrite(#"\b(Jr|Sr)\."#) { match in (match[1] == "Jr" ? "Junior" : "Senior") + match.period },
        Rewrite(#"\bPh\.\s?D\."#) { match in "PhD" + match.period },
        Rewrite(#"\b([Ee])tc\."#) { match in cased("et cetera", like: match[1]) + match.period },

        // Phone numbers, digit by digit.
        Rewrite(#"(?<![\w-])(?:\((\d{3})\)\s?|(\d{3})[-.\s])(\d{3})[-.](\d{4})(?![\w-])"#) { match in
            [match[1] ?? match[2] ?? "", match[3] ?? "", match[4] ?? ""].map { digits($0) }.joined(separator: ", ")
        },

        // Dates: 2026-10-15, 10/15/2026 (or 15/10/2026 when 15 can't be a month), Oct. 15, October 15th, 2026, October 2026.
        Rewrite(#"(?<![\w.-])(\d{4})-(\d{2})-(\d{2})(?![\w-])"#) { match in
            date(month: match.int(2), day: match.int(3), year: match.int(1))
        },
        Rewrite(#"(?<![\w/.])(\d{1,2})/(\d{1,2})/(\d{4}|\d{2})(?![\w/])"#) { match in
            guard let first = match.int(1), let second = match.int(2), let year = match.int(3) else { return nil }
            let full = (match[3]?.count == 2 ? 2000 : 0) + year
            return date(month: first, day: second, year: full) ?? date(month: second, day: first, year: full)
        },
        Rewrite(#"\b(\#(monthNames))\.?\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s+(\d{4}))?(?!\w|:\d)"#) { match in
            date(month: month(match[1]), day: match.int(2), year: match.int(3), yearOptional: true)
        },
        Rewrite(#"\b(\#(monthNames))\.?\s+(\d{4})(?!\w)"#) { match in
            guard let number = month(match[1]), let year = match.int(2) else { return nil }
            return months[number - 1] + " " + Self.year(year)
        },

        // Times: 3:30 pm, 10:05am, 3 p.m., then 15:30, 10:00 and John 3:16.
        Rewrite(#"(?<![\w:.])(\d{1,2})(?::(\d{2}))?\s?([AaPp])(\.\s?[Mm]\.|\s?[Mm](?!\w))"#) { match in
            guard let hour = match.int(1), hour <= 12 else { return nil }
            let minutes = match.int(2) ?? 0
            guard minutes < 60 else { return nil }
            let half = match[3]?.lowercased() == "a" ? " AM" : " PM"
            return clock(hour: hour == 0 ? 12 : hour, minutes: minutes) + half + (match[4]?.hasSuffix(".") == true ? match.period : "")
        },
        Rewrite(#"(?<![\w:.])(\d{1,2}):(\d{2})(?![\w:]|\.\d)"#) { match in
            guard let hour = match.int(1), let minutes = match.int(2), hour < 24, minutes < 60 else { return nil }
            if hour == 0 { return clock(hour: 12, minutes: minutes) + " AM" }
            if hour > 12 { return clock(hour: hour - 12, minutes: minutes) + " PM" }
            return minutes == 0 ? cardinal(hour) + " o'clock" : clock(hour: hour, minutes: minutes)
        },

        // Money: $4.50, $1,299.99, $3.5 million, $5k, $5-10, €5, £10.
        Rewrite(#"([$€£])\s?(\#(amount))(?:\s?[-–]\s?[$€£]?(\#(amount)))?(?:\s?(thousand|million|billion|trillion)\b|([kKMB]|bn|mn)(?!\w))?"#) { match in
            money(symbol: match[1] ?? "$", amount: match[2] ?? "", upper: match[3], scale: match[4] ?? match[5])
        },
        // Percentages: 50%, 12.5%, -3%, 10-20%.
        Rewrite(#"(?<![\w.])([-−]?)(\#(amount))(?:\s?[-–]\s?(\#(amount)))?\s?%"#) { match in
            guard let first = number(match[2] ?? "") else { return nil }
            let second = match[3].flatMap { number($0) }
            return (match[1]?.isEmpty == false ? "minus " : "") + first + (second.map { " to " + $0 } ?? "") + " percent"
        },
        // Decades: the 1990s, the '90s, in their 30s.
        Rewrite(#"(?<![\w'’])(1[1-9]|20)(\d)0s\b"#) { match in
            Int((match[1] ?? "") + (match[2] ?? "") + "0").map { plural(year($0)) }
        },
        Rewrite(#"(?<!\w)['’]([1-9])0s\b"#) { match in match.int(1).map { plural(cardinal($0 * 10)) } },
        Rewrite(#"(?<![\w'’])([2-9])0s\b"#) { match in match.int(1).map { plural(cardinal($0 * 10)) } },
        // Ordinals: 1st, 22nd, 100th.
        Rewrite(#"(?<![\w.])(\d{1,3}(?:,\d{3})+|\d{1,15})(?:st|nd|rd|th)\b"#) { match in
            Int((match[1] ?? "").replacingOccurrences(of: ",", with: "")).map { ordinal($0) }
        },
        // 2x, 1.5x
        Rewrite(#"(?<![\w.])(\d+(?:\.\d+)?)[xX](?!\w)"#) { match in number(match[1] ?? "").map { $0 + " times" } },
        // Fractions people say as words.
        Rewrite(#"(?<![\w/.])(1/2|1/3|2/3|1/4|3/4|24/7|50/50)(?![\w/])"#) { match in
            ["1/2": "one half", "1/3": "one third", "2/3": "two thirds", "1/4": "one quarter", "3/4": "three quarters",
             "24/7": "twenty-four seven", "50/50": "fifty-fifty"][match[1] ?? ""]
        },
        Rewrite(#"(?<=\d)([½¼¾])"#) { match in
            [" and a half", " and a quarter", " and three quarters"][["½", "¼", "¾"].firstIndex(of: match[1] ?? "") ?? 0]
        },
        Rewrite(#"[½⅓⅔¼¾]"#) { match in
            ["½": "one half", "⅓": "one third", "⅔": "two thirds", "¼": "one quarter", "¾": "three quarters"][match[0] ?? ""]
        },
        // Degrees and units after a number: 70°F, 5 km, 16GB, 200 ms.
        Rewrite(#"(?<![\w.])([-−]?\#(amount))\s?°\s?([FC])(?!\w)"#) { match in
            signed(match[1] ?? "").map { $0 + " degrees " + (match[2] == "F" ? "Fahrenheit" : "Celsius") }
        },
        Rewrite(#"\s?°"#) { _ in " degrees" },
        Rewrite(#"(?<![\w.])(\#(amount))\s?(km|kg|mg|cm|mm|mph|ms|mi|lbs?|oz|ft|GB|MB|KB|TB|GHz|MHz|kHz|Hz|mins?|hrs?|h|secs?)(?!\w)"#) { match in
            guard let value = match[1], let words = number(value), let unit = units[match[2] ?? ""] else { return nil }
            return words + " " + (value == "1" ? unit.one : unit.many)
        },
        // Rates: $5/mo, 20 tokens/s, 100 km/h.
        Rewrite(#"(?<=\w)/(s|sec|min|h|hr|day|wk|week|mo|month|yr|year)\b"#) { match in
            ["s": " per second", "sec": " per second", "min": " per minute", "h": " per hour", "hr": " per hour", "day": " per day",
             "wk": " per week", "week": " per week", "mo": " per month", "month": " per month", "yr": " per year", "year": " per year"][match[1] ?? ""]
        },
        // Ranges: 5-10, 2020–2026.
        Rewrite(#"(?<![\w.,\-−])(\#(amount))\s?[-–]\s?(\#(amount))(?!\w|[-–.]\d)"#) { match in
            guard let low = number(match[1] ?? "", years: true), let high = number(match[2] ?? "", years: true) else { return nil }
            return low + " to " + high
        },
        // Negative numbers.
        Rewrite(#"(?<![^\s(\[])[-−](\#(amount))(?!\w)"#) { match in number(match[1] ?? "").map { "minus " + $0 } },
        // "qwen3.5" is "qwen 3.5", so the number below can be read.
        Rewrite(#"(?<=[A-Za-z])(?=\d+(?:\.\d+)+(?!\w))"#) { _ in " " },
        // Decimals and versions: 3.5, .5, 1,234.56, 1.2.10.
        Rewrite(#"(?<![\w.])(\d[\d,]*(?:\.\d+)+|\.\d+)(?!\w|\.\d)"#) { match in number(match[1] ?? "") },
        // Whole numbers, four-digit ones from 1100 to 2099 read as years.
        Rewrite(#"(?<![\w.])(\d{1,3}(?:,\d{3})+|\d+)(?!\w|\.\d)"#) { match in number(match[1] ?? "", years: true) },

        // Dotted initials: U.S., U.K., a.m. on its own.
        Rewrite(#"(?<![\w.])((?:[A-Za-z]\.)+[A-Za-z])(\.)?(?!\w)"#) { match in
            (match[1] ?? "").replacingOccurrences(of: ".", with: "").uppercased() + (match[2] == nil ? "" : match.period)
        },
        // Hosts, files and emails: docs.ollama.com, config.json, josh@example.com.
        Rewrite(#"(?<=\w)\.(?=[A-Za-z])"#) { _ in " dot " },
        Rewrite(#"(?<=\w)@(?=\w)"#) { _ in " at " },
    ]

    // MARK: Numbers as words

    private static let ones = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                               "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
    private static let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
    private static let scales = [(1_000_000_000_000, "trillion"), (1_000_000_000, "billion"), (1_000_000, "million"), (1_000, "thousand")]
    private static let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
    private static let units: [String: (one: String, many: String)] = [
        "km": ("kilometer", "kilometers"), "kg": ("kilogram", "kilograms"), "mg": ("milligram", "milligrams"),
        "cm": ("centimeter", "centimeters"), "mm": ("millimeter", "millimeters"), "mph": ("mile per hour", "miles per hour"),
        "ms": ("millisecond", "milliseconds"), "mi": ("mile", "miles"), "lb": ("pound", "pounds"), "lbs": ("pound", "pounds"),
        "oz": ("ounce", "ounces"), "ft": ("foot", "feet"), "GB": ("gigabyte", "gigabytes"), "MB": ("megabyte", "megabytes"),
        "KB": ("kilobyte", "kilobytes"), "TB": ("terabyte", "terabytes"), "GHz": ("gigahertz", "gigahertz"),
        "MHz": ("megahertz", "megahertz"), "kHz": ("kilohertz", "kilohertz"), "Hz": ("hertz", "hertz"),
        "min": ("minute", "minutes"), "mins": ("minute", "minutes"), "h": ("hour", "hours"), "hr": ("hour", "hours"), "hrs": ("hour", "hours"),
        "sec": ("second", "seconds"), "secs": ("second", "seconds"),
    ]

    /// 21 is "twenty-one", 1905 is "one thousand nine hundred five". American: no "and".
    static func cardinal(_ number: Int) -> String {
        if number < 0 { return "minus " + cardinal(-number) }
        if number < 20 { return ones[number] }
        if number < 100 { return tens[number / 10] + (number % 10 == 0 ? "" : "-" + ones[number % 10]) }
        if number < 1000 { return ones[number / 100] + " hundred" + (number % 100 == 0 ? "" : " " + cardinal(number % 100)) }
        for (size, name) in scales where number >= size {
            return cardinal(number / size) + " " + name + (number % size == 0 ? "" : " " + cardinal(number % size))
        }
        return String(number)
    }
    static func ordinal(_ number: Int) -> String {
        let words = cardinal(number)
        let cut = words.lastIndex(where: { $0 == " " || $0 == "-" }).map { words.index(after: $0) } ?? words.startIndex
        let head = String(words[..<cut]), last = String(words[cut...])
        let irregular = ["one": "first", "two": "second", "three": "third", "five": "fifth", "eight": "eighth", "nine": "ninth", "twelve": "twelfth"]
        if let word = irregular[last] { return head + word }
        if last.hasSuffix("y") { return head + last.dropLast() + "ieth" }
        return head + last + "th"
    }
    /// 1999 is "nineteen ninety-nine", 1905 "nineteen oh five", 2005 "two thousand five", 2026 "twenty twenty-six".
    static func year(_ number: Int) -> String {
        switch number {
        case 2000...2009: return "two thousand" + (number == 2000 ? "" : " " + ones[number - 2000])
        case 1100...1999, 2010...2099:
            let century = cardinal(number / 100), rest = number % 100
            if rest == 0 { return century + " hundred" }
            return century + (rest < 10 ? " oh " + ones[rest] : " " + cardinal(rest))
        default: return cardinal(number)
        }
    }
    static func digits<S: StringProtocol>(_ text: S) -> String {
        text.compactMap { $0.wholeNumberValue }.map { ones[$0] }.joined(separator: " ")
    }
    /// "nineteen ninety" to "nineteen nineties".
    static func plural(_ words: String) -> String {
        words.hasSuffix("y") ? words.dropLast() + "ies" : words + "s"
    }
    private static func clock(hour: Int, minutes: Int) -> String {
        cardinal(hour) + (minutes == 0 ? "" : minutes < 10 ? " oh " + ones[minutes] : " " + cardinal(minutes))
    }
    private static func month(_ name: String?) -> Int? {
        guard let name else { return nil }
        let start = String(name.prefix(3))
        return months.firstIndex { $0.hasPrefix(start) }.map { $0 + 1 }
    }
    private static func date(month: Int?, day: Int?, year: Int?, yearOptional: Bool = false) -> String? {
        guard let month, let day, (1...12).contains(month), (1...31).contains(day) else { return nil }
        let spoken = months[month - 1] + " " + ordinal(day)
        guard let year else { return yearOptional ? spoken : nil }
        return spoken + ", " + Self.year(year)
    }
    /// A numeral as words: "1,234", "3.5", ".5", "1.2.10"; with `years`, 1100 to 2099 read as years.
    static func number(_ token: String, years: Bool = false) -> String? {
        guard !token.isEmpty else { return nil }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if parts.count > 2 {
            let words = parts.map { whole($0) }
            return words.contains(nil) ? nil : words.compactMap { $0 }.joined(separator: " point ")
        }
        let head = parts[0].isEmpty ? "" : whole(parts[0], years: years && parts.count == 1)
        guard let head else { return nil }
        guard parts.count == 2 else { return head }
        guard !parts[1].isEmpty, parts[1].allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return (head.isEmpty ? "" : head + " ") + "point " + digits(parts[1])
    }
    private static func whole(_ token: String, years: Bool = false) -> String? {
        let plain = token.replacingOccurrences(of: ",", with: "")
        guard !plain.isEmpty, plain.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        if plain.count > 1, plain.hasPrefix("0") || plain.count > 15 { return digits(plain) }
        guard let value = Int(plain) else { return nil }
        if years, !token.contains(","), plain.count == 4, (1100...2099).contains(value) { return year(value) }
        return cardinal(value)
    }
    private static func signed(_ token: String) -> String? {
        if let first = token.first, first == "-" || first == "−" { return number(String(token.dropFirst())).map { "minus " + $0 } }
        return number(token)
    }
    private static func money(symbol: String, amount: String, upper: String?, scale: String?) -> String? {
        let names: (one: String, many: String, cent: String, cents: String) = symbol == "€" ? ("euro", "euros", "cent", "cents")
            : symbol == "£" ? ("pound", "pounds", "penny", "pence") : ("dollar", "dollars", "cent", "cents")
        let size = scale.map { ["k": "thousand", "K": "thousand", "M": "million", "mn": "million", "B": "billion", "bn": "billion"][$0] ?? $0 }
        guard let words = number(amount) else { return nil }
        if let upper {
            guard let high = number(upper) else { return nil }
            return words + " to " + high + (size.map { " " + $0 } ?? "") + " " + names.many
        }
        if let size { return words + " " + size + " " + names.many }
        let parts = amount.split(separator: ".", omittingEmptySubsequences: false)
        guard let dollars = whole(String(parts[0])) else { return nil }
        let count = Int(parts[0].replacingOccurrences(of: ",", with: ""))
        if parts.count == 1 || parts[1].allSatisfy({ $0 == "0" }) {
            return dollars + " " + (count == 1 ? names.one : names.many)
        }
        guard parts.count == 2, parts[1].count == 2, let cents = Int(parts[1]) else { return words + " " + names.many }
        let change = cardinal(cents) + " " + (cents == 1 ? names.cent : names.cents)
        if count == 0 { return change }
        return dollars + " " + (count == 1 ? names.one : names.many) + " and " + change
    }
    private static func cased(_ words: String, like original: String?) -> String {
        guard let first = original?.first, first.isUppercase else { return words }
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}

/// A pattern and what each match becomes; nil leaves the match as it was.
private struct Rewrite {
    let regex: NSRegularExpression
    let replace: (RewriteMatch) -> String?
    init(_ pattern: String, _ replace: @escaping (RewriteMatch) -> String?) {
        // The patterns are constants; the tests run every one of them.
        regex = try! NSRegularExpression(pattern: pattern)
        self.replace = replace
    }
    func apply(to text: String) -> String {
        let source = text as NSString
        var result = "", cursor = 0
        for found in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            guard let replacement = replace(RewriteMatch(found: found, text: source)) else { continue }
            result += source.substring(with: NSRange(location: cursor, length: found.range.location - cursor)) + replacement
            cursor = found.range.location + found.range.length
        }
        return result + source.substring(from: cursor)
    }
}

private struct RewriteMatch {
    let found: NSTextCheckingResult
    let text: NSString
    subscript(_ group: Int) -> String? {
        guard group < found.numberOfRanges else { return nil }
        let range = found.range(at: group)
        return range.location == NSNotFound ? nil : text.substring(with: range)
    }
    func int(_ group: Int) -> Int? { self[group].flatMap { Int($0) } }
    private var after: Substring { Substring(text.substring(from: found.range.location + found.range.length)) }

    /// "etc.", "U.S." and "p.m." can end a sentence or sit inside one. They end it, and keep a
    /// period, when the line ends there or the next word starts with a capital letter and isn't a
    /// day, a month or a time zone ("5 p.m. Friday").
    var period: String {
        let rest = after.drop { SpeechText.closers.contains($0) }
        guard let next = rest.first else { return "." }
        guard next.isWhitespace else { return "" }
        let word = rest.drop { $0.isWhitespace }.prefix { $0.isLetter }
        guard let first = rest.first(where: { !$0.isWhitespace }) else { return "." }
        return first.isUppercase && !Self.continuing.contains(String(word)) ? "." : ""
    }
    private static let continuing: Set<String> = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday",
        "Mon", "Tue", "Tues", "Wed", "Thu", "Thur", "Thurs", "Fri", "January", "February", "March", "April", "May", "June", "July",
        "August", "September", "October", "November", "December", "ET", "CT", "MT", "PT", "EST", "EDT", "CST", "CDT", "MST", "MDT",
        "PST", "PDT", "UTC", "GMT"]
    /// After "e.g." or "i.e.", a comma when words follow.
    var comma: String {
        if self[2] != nil { return "," }
        guard after.first?.isWhitespace == true, let next = after.first(where: { !$0.isWhitespace }) else { return "" }
        return next.isLetter || next.isNumber ? "," : ""
    }
    /// "Main St." rather than "St. Louis".
    var followsCapitalizedWord: Bool {
        let before = text.substring(to: found.range.location).trimmingCharacters(in: .whitespaces)
        guard let word = before.split(separator: " ").last, let first = word.first else { return false }
        return first.isUppercase
    }
}

private extension String {
    func replacing(pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return self }
        return regex.stringByReplacingMatches(in: self, range: NSRange(startIndex..., in: self), withTemplate: template)
    }
    func matches(_ pattern: String) -> Bool { range(of: pattern, options: .regularExpression) != nil }
}
