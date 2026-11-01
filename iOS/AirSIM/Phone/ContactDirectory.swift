import Foundation

/// The address book as the UI sees it, with the app's one number-matching policy.
struct ContactDirectory: Equatable, Sendable {
    var all: [ContactStore.Contact] = []
    var isAuthorized = false
    var authorization: ContactAuthorizationState = .notDetermined

    /// An exact normalized match, else a match on the last seven digits.
    func contact(for number: String) -> ContactStore.Contact? {
        let target = ContactStore.normalized(number)
        guard !target.isEmpty else { return nil }
        if let exact = all.first(where: { $0.phones.contains(target) }) {
            return exact
        }
        guard target.count >= 7 else { return nil }
        return all.first { contact in
            contact.phones.contains { $0.count >= 7 && $0.hasSuffix(target.suffix(7)) }
        }
    }

    /// The contact's name, else the number, else "Unknown Number".
    func displayName(for number: String?) -> String {
        guard let number, !number.isEmpty else { return "Unknown Number" }
        return contact(for: number)?.name ?? number
    }

    /// Every contact for a blank query, else those whose name or any number contains the trimmed query,
    /// ignoring case.
    func contacts(matching query: String) -> [ContactStore.Contact] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return all }
        return all.filter { contact in
            contact.name.localizedCaseInsensitiveContains(query)
                || contact.phones.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    /// The first five contacts that could complete a typed recipient: those whose name or any number contains the
    /// trimmed text, ignoring case, or whose number ends with it. None while the recipient is blank or already
    /// names a contact.
    func suggestions(for recipient: String) -> [ContactStore.Contact] {
        let query = recipient.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, contact(for: recipient) == nil else { return [] }
        let matches = all.filter { contact in
            contact.name.localizedCaseInsensitiveContains(query)
                || contact.phones.contains { $0.localizedCaseInsensitiveContains(query) || $0.hasSuffix(query) }
        }
        return Array(matches.prefix(5))
    }
}
