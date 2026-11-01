import Foundation

struct ContactRow: Equatable, Identifiable {
    let id: String
    let contact: ContactStore.Contact
    let phone: String

    init(contact: ContactStore.Contact) {
        id = contact.id
        self.contact = contact
        phone = contact.phones.first ?? ""
    }

    init(contact: ContactStore.Contact, phone: String) {
        id = contact.id + phone
        self.contact = contact
        self.phone = phone
    }

    var name: String { contact.name }
    var photo: Data? { contact.photoData }
    var phones: [String] { ContactPhoneListPolicy.displayPhones(for: contact.phones) }
}

/// A contact may store duplicate entries for the same phone number; since duplicate rows are interchangeable
/// during selection and dialing, deduplicate by number so phone-derived table row IDs stay unique.
enum ContactPhoneListPolicy {
    static func displayPhones(for phones: [String]) -> [String] {
        var seen = Set<String>()
        return phones.filter { seen.insert($0).inserted }
    }
}
