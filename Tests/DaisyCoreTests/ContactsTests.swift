import Foundation
import DaisyCore

/// How daisy-contacts matches a name, nickname, number or email address, and what it prints: names,
/// phone numbers and email addresses, nothing else.
final class ContactsTests {
    let book = [
        ContactRecord(fullName: "Robert Lukose", given: "Robert", family: "Lukose", nickname: "Bubba",
                      phones: [.init(label: "mobile", value: "+1 (555) 010-4477"), .init(label: "home", value: "555.010.4477")],
                      emails: [.init(label: "home", value: "Rob@Example.com")]),
        ContactRecord(fullName: "Robin Lukose", given: "Robin", family: "Lukose", phones: [.init(label: "mobile", value: "+1 555 010 9000")]),
        ContactRecord(fullName: "José Álvarez", given: "José", family: "Álvarez", emails: [.init(label: "work", value: "jose@example.com")]),
        ContactRecord(organization: "Dr. Patel's Office", phones: [.init(label: "work", value: "+1 555 010 2222")]),
        ContactRecord(fullName: "Rob Stone", given: "Rob", family: "Stone"),
        ContactRecord()
    ]

    func testQueriesAreNamesNumbersOrEmails() {
        expectEqual(ContactsSearch.query("Bubba"), .name("bubba"))
        expectEqual(ContactsSearch.query("  robert   LUKOSE "), .name("robert lukose"))
        expectEqual(ContactsSearch.query("+1 (555) 010-4477"), .phone("15550104477"))
        expectEqual(ContactsSearch.query("Rob@Example.com"), .email("rob@example.com"))
        expectEqual(ContactsSearch.query("Room 555"), .name("room 555"))
    }

    func testNicknameThenWholeNameThenFirstNameThenPartial() {
        expectEqual(ContactsSearch.search(book, for: "bubba").map(\.name), ["Robert Lukose"])
        expectEqual(ContactsSearch.search(book, for: "bubba").first?.match, "nickname")
        expectEqual(ContactsSearch.search(book, for: "Robert Lukose").first?.match, "exact")
        let rob = ContactsSearch.search(book, for: "Rob")
        expectEqual(rob.map(\.name), ["Rob Stone", "Robert Lukose", "Robin Lukose"])
        expectEqual(rob.map(\.match), ["name", "partial", "partial"])
        expectEqual(ContactsSearch.search(book, for: "Lukose").map(\.name), ["Robert Lukose", "Robin Lukose"])
        expectEqual(ContactsSearch.search(book, for: "jose alvarez").map(\.name), ["José Álvarez"])
        expectEqual(ContactsSearch.search(book, for: "patel").map(\.name), ["Dr. Patel's Office"])
        expectEqual(ContactsSearch.search(book, for: "nobody").count, 0)
        expectEqual(ContactsSearch.search(book, for: "Lukose", limit: 1).count, 1)
    }

    func testNumbersAndEmailsFindTheirOwner() {
        expectEqual(ContactsSearch.search(book, for: "555-010-4477").map(\.name), ["Robert Lukose"])
        expectEqual(ContactsSearch.search(book, for: "+15550109000").map(\.name), ["Robin Lukose"])
        expectEqual(ContactsSearch.search(book, for: "ROB@example.com").first?.match, "email")
        expectEqual(ContactsSearch.search(book, for: "555-010-0000").count, 0)
    }

    func testOutputIsNamesNumbersAndEmailsOnly() throws {
        let match = try unwrap(ContactsSearch.search(book, for: "Bubba").first)
        // The same number written two ways shows once.
        expectEqual(match.phones.map(\.number), ["+1 (555) 010-4477"])
        expectEqual(match.emails.map(\.address), ["Rob@Example.com"])
        let json = ContactsSearch.output(status: "ok", query: "Bubba", contacts: [match])
        let object = try unwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        expectEqual(object["status"] as? String, "ok")
        let first = try unwrap((object["contacts"] as? [[String: Any]])?.first)
        expectEqual(Set(first.keys), ["name", "match", "phones", "emails"])
        let phone = try unwrap((first["phones"] as? [[String: Any]])?.first)
        expectEqual(Set(phone.keys), ["label", "number"])
        let denied = ContactsSearch.output(status: "denied", message: "Daisy isn't allowed to read Contacts.")
        expectEqual(denied, #"{"message":"Daisy isn't allowed to read Contacts.","status":"denied"}"#)
    }
}
