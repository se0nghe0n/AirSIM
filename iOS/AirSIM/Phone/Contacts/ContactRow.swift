import Foundation

/// One Contacts row, ready to draw: a contact on the Contacts tab, or one of its numbers in the picker.
struct ContactRow: Equatable, Identifiable {
    let id: String
    let contact: ContactStore.Contact
    /// The number under the name: the contact's first on the tab, the number the row chooses in the picker.
    let phone: String

    /// A Contacts tab row.
    init(contact: ContactStore.Contact) {
        id = contact.id
        self.contact = contact
        phone = contact.phones.first ?? ""
    }

    /// A picker row for one of the contact's numbers.
    init(contact: ContactStore.Contact, phone: String) {
        id = contact.id + phone
        self.contact = contact
        self.phone = phone
    }

    var name: String { contact.name }
    var photo: Data? { contact.photoData }
    /// Each of the contact's numbers once, for its details.
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
