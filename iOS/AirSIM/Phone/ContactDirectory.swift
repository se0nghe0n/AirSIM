import Foundation

struct ContactDirectory: Equatable, Sendable {
    var all: [ContactStore.Contact] = []
    var isAuthorized = false
    var authorization: ContactAuthorizationState = .notDetermined

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

    func displayName(for number: String?) -> String {
        guard let number, !number.isEmpty else { return "Unknown Number" }
        return contact(for: number)?.name ?? number
    }

    func contacts(matching query: String) -> [ContactStore.Contact] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return all }
        return all.filter { contact in
            contact.name.localizedCaseInsensitiveContains(query)
                || contact.phones.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

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
