import Foundation

/// A contact as the daisy-contacts helper reads it from Contacts: the name fields it matches on, and
/// the phone numbers and email addresses it can hand back. Nothing else from the address book.
public struct ContactRecord: Sendable, Equatable {
    public struct Handle: Sendable, Equatable {
        public var label: String
        public var value: String
        public init(label: String, value: String) { self.label = label; self.value = value }
    }
    public var fullName: String
    public var given: String
    public var middle: String
    public var family: String
    public var nickname: String
    public var organization: String
    public var phones: [Handle]
    public var emails: [Handle]

    public init(fullName: String = "", given: String = "", middle: String = "", family: String = "", nickname: String = "",
                organization: String = "", phones: [Handle] = [], emails: [Handle] = []) {
        self.fullName = fullName; self.given = given; self.middle = middle; self.family = family
        self.nickname = nickname; self.organization = organization; self.phones = phones; self.emails = emails
    }

    /// What to call them: the formatted name, else the company, else the nickname.
    public var displayName: String {
        let formatted = fullName.isEmpty ? [given, middle, family].filter { !$0.isEmpty }.joined(separator: " ") : fullName
        return [formatted, organization, nickname].first { !$0.isEmpty } ?? ""
    }
}

/// One match, as JSON for the Hermes plugin (hermes/daisy/tools/contacts.py).
public struct ContactMatch: Codable, Sendable, Equatable {
    public struct Phone: Codable, Sendable, Equatable { public let label: String; public let number: String }
    public struct Email: Codable, Sendable, Equatable { public let label: String; public let address: String }
    public let name: String
    /// How it matched: "nickname", "exact" (the whole name), "name" (a first or last name), "partial",
    /// "phone" or "email".
    public let match: String
    public let phones: [Phone]
    public let emails: [Email]
}

/// Finds who a name, nickname, number or email address means, for "text Bubba".
public enum ContactsSearch {
    public enum Query: Equatable {
        case name(String)
        /// Digits only.
        case phone(String)
        case email(String)
    }

    public static let limit = 8
    static let handles = 6

    public static func query(_ text: String) -> Query {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("@"), !text.contains(where: \.isWhitespace) { return .email(text.lowercased()) }
        let digits = text.filter(\.isNumber)
        if digits.count >= 7, text.allSatisfy({ $0.isNumber || " +-().".contains($0) }) { return .phone(String(digits)) }
        return .name(fold(text))
    }

    /// The best matches first, at most `limit`.
    public static func search(_ contacts: [ContactRecord], for text: String, limit: Int = limit) -> [ContactMatch] {
        let wanted = query(text)
        let scored: [(score: Int, match: String, contact: ContactRecord)] = contacts.compactMap { contact in
            guard !contact.displayName.isEmpty, let (score, how) = score(contact, wanted) else { return nil }
            return (score, how, contact)
        }
        return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.contact.displayName < $1.contact.displayName }
            .prefix(limit).map { match(for: $0.contact, how: $0.match) }
    }

    static func score(_ contact: ContactRecord, _ query: Query) -> (Int, String)? {
        switch query {
        case .email(let address):
            return contact.emails.contains { $0.value.lowercased() == address } ? (100, "email") : nil
        case .phone(let digits):
            let wanted = String(digits.suffix(10))
            return contact.phones.contains { phone in
                let have = String(phone.value.filter(\.isNumber).suffix(10))
                return have.count >= 7 && (have.hasSuffix(wanted) || wanted.hasSuffix(have))
            } ? (100, "phone") : nil
        case .name(let name):
            guard !name.isEmpty else { return nil }
            let nickname = fold(contact.nickname), full = fold(contact.displayName)
            let parts = [contact.given, contact.middle, contact.family].map(fold).filter { !$0.isEmpty }
            if !nickname.isEmpty && nickname == name { return (100, "nickname") }
            if full == name || parts.joined(separator: " ") == name { return (90, "exact") }
            if parts.contains(name) { return (70, "name") }
            if !contact.organization.isEmpty && fold(contact.organization) == name { return (65, "name") }
            let words = (parts + [nickname, fold(contact.organization)]).flatMap { $0.split(separator: " ") }
            if name.split(separator: " ").allSatisfy({ token in words.contains { $0.hasPrefix(token) } }) { return (50, "partial") }
            if [full, nickname, fold(contact.organization)].contains(where: { !$0.isEmpty && $0.contains(name) }) { return (30, "partial") }
            return nil
        }
    }

    static func match(for contact: ContactRecord, how: String) -> ContactMatch {
        // The same number written two ways ("+1 (555) 010-4477", "555.010.4477") shows once.
        var numbers = Set<String>(), addresses = Set<String>()
        let phones = contact.phones.filter { !$0.value.isEmpty && numbers.insert(String($0.value.filter(\.isNumber).suffix(10))).inserted }
            .prefix(handles).map { ContactMatch.Phone(label: $0.label, number: $0.value) }
        let emails = contact.emails.filter { !$0.value.isEmpty && addresses.insert($0.value.lowercased()).inserted }
            .prefix(handles).map { ContactMatch.Email(label: $0.label, address: $0.value) }
        return ContactMatch(name: contact.displayName, match: how, phones: Array(phones), emails: Array(emails))
    }

    /// Case, accents and extra spaces don't count: "José" finds "jose".
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The helper's whole answer. status is "ok", "denied", "restricted" or "error".
    public static func output(status: String, query: String? = nil, contacts: [ContactMatch] = [], message: String? = nil) -> String {
        struct Output: Encodable {
            let status: String
            let query: String?
            let contacts: [ContactMatch]?
            let message: String?
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let body = Output(status: status, query: query, contacts: status == "ok" ? contacts : nil, message: message)
        return (try? encoder.encode(body)).map { String(decoding: $0, as: UTF8.self) } ?? #"{"status":"error"}"#
    }
}
