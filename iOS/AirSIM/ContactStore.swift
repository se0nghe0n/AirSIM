import Contacts
import Foundation

enum ContactAuthorizationState: Equatable {
    case notDetermined
    case authorized
    case denied
}

enum ContactAccessAction: Equatable {
    case request
    case load
    case waitForUser
    case blocked
}

enum ContactAccessPolicy {
    static func action(
        for state: ContactAuthorizationState,
        userInitiated: Bool
    ) -> ContactAccessAction {
        switch state {
        case .authorized: return .load
        case .notDetermined: return userInitiated ? .request : .waitForUser
        case .denied: return .blocked
        }
    }
}

/// Non-main-thread contact reader to avoid holding CNContactStore across threads in Swift 6.
struct ContactFetcher: Sendable {
    func authorizationState() -> ContactAuthorizationState {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .authorized { return .authorized }
        if #available(iOS 18.0, *), status == .limited { return .authorized }
        return status == .notDetermined ? .notDetermined : .denied
    }

    func requestAccess() async throws -> Bool {
        try await CNContactStore().requestAccess(for: .contacts)
    }

    func fetchAll() throws -> [ContactStore.Contact] {
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor,
            CNContactIdentifierKey as CNKeyDescriptor,
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.sortOrder = .userDefault
        var contacts: [ContactStore.Contact] = []
        try store.enumerateContacts(with: request) { contact, _ in
            let cjkName = Self.containsCJK(contact.givenName + contact.familyName)
            let nameParts = cjkName
                ? [contact.familyName, contact.givenName]
                : [contact.givenName, contact.familyName]
            let separator = cjkName ? "" : " "
            let name = nameParts.filter { !$0.isEmpty }.joined(separator: separator)
            let phones = contact.phoneNumbers
                .map { ContactStore.normalized($0.value.stringValue) }
                .filter { !$0.isEmpty }
            guard !name.isEmpty, !phones.isEmpty else { return }
            contacts.append(.init(
                id: contact.identifier,
                name: name,
                phones: phones,
                emails: contact.emailAddresses.map { $0.value as String },
                photoData: contact.thumbnailImageData
            ))
        }
        return contacts
    }

    func displayName(for number: String) throws -> String? {
        guard authorizationState() == .authorized else { return nil }
        let target = ContactStore.normalized(number)
        guard !target.isEmpty else { return nil }
        let contacts = try fetchAll()
        if let exact = contacts.first(where: { $0.phones.contains(target) }) {
            return exact.name
        }
        guard target.count >= 7 else { return nil }
        let suffix = target.suffix(7)
        return contacts.first { contact in
            contact.phones.contains { $0.count >= 7 && $0.hasSuffix(suffix) }
        }?.name
    }

    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x3040...0x30FF:
                return true
            default:
                return false
            }
        }
    }
}

@MainActor
@Observable
final class ContactStore {
    struct Contact: Codable, Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let phones: [String]
        let emails: [String]
        let photoData: Data?
    }

    private(set) var contacts: [Contact] = []
    private(set) var isAuthorized = false
    private(set) var authorizationState: ContactAuthorizationState = .notDetermined
    var errorMessage: String?
    @ObservationIgnored private let cache: ContactCacheStore

    init(fileManager: FileManager = .default) {
        cache = ContactCacheStore(fileManager: fileManager)
        // Contacts belong to phone data. Show the local copy first while the module is offline or the system contacts DB is temporarily unreadable.
        contacts = cache.load()
        let state = ContactFetcher().authorizationState()
        authorizationState = state
        isAuthorized = state == .authorized
    }

    nonisolated static func normalized(_ phone: String) -> String {
        var value = phone.filter { $0.isNumber || $0 == "+" }
        if value.hasPrefix("+86") {
            value.removeFirst(3)
        } else if value.hasPrefix("86"), value.count > 11 {
            value.removeFirst(2)
        }
        return value
    }

    func loadIfAuthorized() async {
        await refresh(userInitiated: false)
    }

    func requestAccessAndLoad() async {
        await refresh(userInitiated: true)
    }

    private func refresh(userInitiated: Bool) async {
        do {
            // After a reboot, an empty array may be read before data protection unlocks; retry the disk cache on every foreground refresh.
            let cachedContacts = cache.load()
            if !cachedContacts.isEmpty {
                contacts = cachedContacts
            }

            var state = await Task.detached(priority: .userInitiated) {
                ContactFetcher().authorizationState()
            }.value
            authorizationState = state

            switch ContactAccessPolicy.action(for: state, userInitiated: userInitiated) {
            case .request:
                let granted = try await Task.detached(priority: .userInitiated) {
                    try await ContactFetcher().requestAccess()
                }.value
                state = granted ? .authorized : .denied
                authorizationState = state
                guard granted else {
                    isAuthorized = false
                    errorMessage = "Contacts access has not been granted"
                    return
                }
            case .load:
                break
            case .waitForUser:
                isAuthorized = false
                errorMessage = nil
                return
            case .blocked:
                isAuthorized = false
                errorMessage = "Contacts access is disabled. Enable it in Settings."
                return
            }

            isAuthorized = true
            // Prefer the restored cache for non-user-initiated refreshes to avoid enumerating all contacts on every tab switch.
            guard userInitiated || contacts.isEmpty else {
                errorMessage = nil
                return
            }
            contacts = try await Task.detached(priority: .userInitiated) {
                try ContactFetcher().fetchAll()
            }.value
            guard cache.save(contacts) else {
                errorMessage = "Contacts loaded, but could not be saved locally"
                return
            }
            errorMessage = nil
        } catch {
            isAuthorized = false
            errorMessage = error.localizedDescription
        }
    }

    func contact(for number: String) -> Contact? {
        let target = Self.normalized(number)
        guard !target.isEmpty else { return nil }
        if let exact = contacts.first(where: { $0.phones.contains(target) }) { return exact }
        guard target.count >= 7 else { return nil }
        let suffix = target.suffix(7)
        return contacts.first { contact in
            contact.phones.contains { $0.count >= 7 && $0.hasSuffix(suffix) }
        }
    }

    func displayName(for number: String?) -> String {
        guard let number, !number.isEmpty else { return "Unknown Number" }
        return contact(for: number)?.name ?? number
    }
}

/// Contact cache is stored only inside the app sandbox and is never uploaded to the module or Push Relay.
private final class ContactCacheStore {
    private let fileManager: FileManager
    private let fileURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let durableRoot = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Documents", isDirectory: true)
        let directory = durableRoot.appendingPathComponent("AirSIM", isDirectory: true)
        fileURL = directory.appendingPathComponent("contacts.json")
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func load() -> [ContactStore.Contact] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        do {
            return try JSONDecoder().decode([ContactStore.Contact].self, from: data)
        } catch {
            Self.log("Failed to read contact cache: \(error.localizedDescription)")
            return []
        }
    }

    @discardableResult
    func save(_ contacts: [ContactStore.Contact]) -> Bool {
        do {
            let data = try JSONEncoder().encode(contacts)
            try data.write(to: fileURL, options: [.atomic])
            return true
        } catch {
            Self.log("Failed to save contact cache: \(error.localizedDescription)")
            return false
        }
    }

    private static func log(_ message: String) {
#if DEBUG
        print("[AirSIM Contacts] \(message)")
#endif
    }
}
