import ComposableArchitecture
import UIKit

/// The app's sheet style, built without presenting so state-driven presentation can present it.
@MainActor
func phoneSheet(_ controller: UIViewController) -> UINavigationController {
    controller.loadViewIfNeeded()
    let nav = UINavigationController(rootViewController: controller)
    if controller.navigationItem.rightBarButtonItem == nil {
        let done = UIAction { [weak nav] _ in nav?.dismiss(animated: true) }
        controller.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: done)
    }
    if let sheet = nav.sheetPresentationController {
        sheet.detents = [.medium(), .large()]
        sheet.prefersGrabberVisible = true
    }
    return nav
}

extension UIViewController {
    func showPhoneSheet(_ controller: UIViewController) {
        present(phoneSheet(controller), animated: true)
    }

    /// Shows a screen's alert above whatever is already presented, even from a hidden tab: present(item:) would
    /// first dismiss an unrelated sheet. Button actions are sent as `.presented`; an alert closed from beneath,
    /// e.g. with its sheet, sends `.dismiss`, so state cannot hold an alert nobody sees and later errors still show.
    func presentAlert<State: ObservableState, Action, AlertAction>(
        from store: Store<State, Action>,
        state alert: KeyPath<State, AlertState<AlertAction>?>,
        action: CaseKeyPath<Action, PresentationAction<AlertAction>>
    ) {
        let presenter = StateAlertPresenter(
            owner: self,
            alert: { store.state[keyPath: alert] },
            send: { store.send(action($0)) }
        )
        observe { transaction in presenter.render(animated: !transaction.uiKit.disablesAnimations) }
    }

    func confirmPhoneAction(
        _ title: String,
        message: String,
        actionTitle: String = "Delete",
        action: @escaping () -> Void
    ) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: actionTitle, style: .destructive) { _ in action() })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.popoverPresentationController?.sourceView = view
        let center = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        alert.popoverPresentationController?.sourceRect = center
        present(alert, animated: true)
    }
}

@MainActor
private final class StateAlertPresenter<Action> {
    private weak var owner: UIViewController?
    private let alert: () -> AlertState<Action>?
    private let send: (PresentationAction<Action>) -> Void
    private var shown: (id: UUID, controller: UIAlertController)?

    init(
        owner: UIViewController,
        alert: @escaping () -> AlertState<Action>?,
        send: @escaping (PresentationAction<Action>) -> Void
    ) {
        self.owner = owner
        self.alert = alert
        self.send = send
    }

    func render(animated: Bool) {
        let state = alert()
        if let shown, shown.id != state?.id {
            self.shown = nil
            // Through its presenter, so an alert presented above it goes too instead of it staying up alone.
            if let presenter = shown.controller.presentingViewController, !shown.controller.isBeingDismissed {
                presenter.dismiss(animated: animated)
            }
        }
        guard let state, shown == nil, let host = topmostController() else { return }
        if let transition = host.presentedViewController?.transitionCoordinator ?? host.transitionCoordinator {
            transition.animate(alongsideTransition: nil) { [weak self] _ in
                Task { @MainActor [weak self] in self?.render(animated: animated) }
            }
            return
        }
        guard host.viewIfLoaded?.window != nil else { return }
        show(state, on: host, animated: animated)
    }

    private func topmostController() -> UIViewController? {
        guard var host = owner else { return nil }
        while let parent = host.parent {
            host = parent
        }
        while let next = host.presentedViewController, !next.isBeingDismissed {
            host = next
        }
        return host
    }

    private func show(_ state: AlertState<Action>, on host: UIViewController, animated: Bool) {
        let controller = StateAlertController(state: state) { [weak self] action in
            guard let self, self.alert()?.id == state.id else { return }
            self.send(action.map { .presented($0) } ?? .dismiss)
        }
        controller.onDisappear = { [weak self, weak controller] in
            // Button handlers run after the alert disappears; one still in state then left without a button.
            Task { @MainActor [weak self] in
                guard let self,
                      let controller,
                      self.shown?.controller === controller,
                      controller.presentingViewController == nil
                else { return }
                self.shown = nil
                if self.alert()?.id == state.id {
                    self.send(.dismiss)
                }
            }
        }
        shown = (state.id, controller)
        host.present(controller, animated: animated)
    }
}

/// Reports leaving the screen, including when a sheet beneath it closes and takes it along.
final class StateAlertController: UIAlertController {
    var alertID: UUID?
    weak var hostWindow: UIWindow?
    var onDisappear: (() -> Void)?

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        onDisappear?()
    }
}
