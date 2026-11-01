import Foundation

/// Owns a block-based NotificationCenter observer and removes it when released. Main-actor owners hold one instead of
/// the raw token because their nonisolated deinit cannot read a non-Sendable token.
final class NotificationObservation {
    private let token: NSObjectProtocol

    init(
        _ name: Notification.Name,
        object: Any? = nil,
        using block: @escaping @Sendable (Notification) -> Void
    ) {
        token = NotificationCenter.default.addObserver(forName: name, object: object, queue: .main, using: block)
    }

    deinit {
        NotificationCenter.default.removeObserver(token)
    }
}
