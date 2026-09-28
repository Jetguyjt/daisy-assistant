import Contacts
import DaisyCore
import Foundation

/// daisy-contacts: who a name, nickname, phone number or email address means, from the Mac's Contacts.
///
///     daisy-contacts search Bubba     → {"status":"ok","query":"Bubba","contacts":[{"name":…,"phones":…,"emails":…}]}
///     daisy-contacts status           → {"status":"ok"} once access is granted
///
/// Prints names, phone numbers and email addresses only, never notes, addresses or birthdays. The
/// Daisy plugin for Hermes runs it for contacts_search (hermes/daisy/tools/contacts.py). It lives in
/// Daisy.app, and hermes-acp is started by Daisy, so the Contacts permission prompt and the setting in
/// Privacy & Security belong to Daisy. Exit status: 0 answered, 2 bad arguments, 3 no permission,
/// 1 anything else.
@main struct DaisyContacts {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        switch (arguments.first, arguments.count) {
        case ("search", 2):
            exit(await search(arguments[1]))
        case ("status", 1):
            exit(await allowed() ? answer(ContactsSearch.output(status: "ok"), 0) : denied())
        default:
            FileHandle.standardError.write(Data("usage: daisy-contacts search <name, nickname, number or email> | status\n".utf8))
            exit(2)
        }
    }

    static func search(_ text: String) async -> Int32 {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 100 else {
            return answer(ContactsSearch.output(status: "error", message: "The query must be 1 to 100 characters."), 2)
        }
        guard await allowed() else { return denied() }
        do {
            let records = try read()
            return answer(ContactsSearch.output(status: "ok", query: query, contacts: ContactsSearch.search(records, for: query)), 0)
        } catch {
            return answer(ContactsSearch.output(status: "error", message: error.localizedDescription), 1)
        }
    }

    /// Asks for access the first time; macOS shows its prompt for the app that started this (Daisy).
    static func allowed() async -> Bool {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: return true
        case .notDetermined: return (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
        case .denied, .restricted: return false
        @unknown default: return true  // a limited grant still lets the shared contacts be read
        }
    }

    static func denied() -> Int32 {
        let status = CNContactStore.authorizationStatus(for: .contacts) == .restricted ? "restricted" : "denied"
        return answer(ContactsSearch.output(status: status, message: "Daisy isn't allowed to read Contacts."), 3)
    }

    /// Every contact's name fields, phone numbers and email addresses.
    static func read() throws -> [ContactRecord] {
        let keys: [CNKeyDescriptor] = [CNContactGivenNameKey, CNContactMiddleNameKey, CNContactFamilyNameKey, CNContactNicknameKey,
                                       CNContactOrganizationNameKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey]
            .map { $0 as CNKeyDescriptor } + [CNContactFormatter.descriptorForRequiredKeys(for: .fullName)]
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.unifyResults = true
        var records: [ContactRecord] = []
        try CNContactStore().enumerateContacts(with: request) { contact, _ in
            records.append(ContactRecord(
                fullName: CNContactFormatter.string(from: contact, style: .fullName) ?? "",
                given: contact.givenName, middle: contact.middleName, family: contact.familyName,
                nickname: contact.nickname, organization: contact.organizationName,
                phones: contact.phoneNumbers.map { .init(label: label($0.label), value: $0.value.stringValue) },
                emails: contact.emailAddresses.map { .init(label: label($0.label), value: $0.value as String) }))
        }
        return records
    }

    static func label(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        return CNLabeledValue<NSString>.localizedString(forLabel: raw)
    }

    static func answer(_ json: String, _ status: Int32) -> Int32 {
        print(json)
        return status
    }
}
