import ComposableArchitecture
import UIKit

/// The in-call keypad sheet. Each key sends one DTMF tone; the label shows the digits sent so far.
@MainActor
@ViewAction(for: KeypadFeature.self)
final class DTMFKeypadViewController: ObservingViewController {
    // MARK: Store

    let store: StoreOf<KeypadFeature>

    // MARK: Views

    private let stack = UIStackView(axis: .vertical, spacing: Metrics.rowSpacing, alignment: .center)
    private let digitsLabel = phoneLabel(size: 20)

    // MARK: Lifecycle

    init(store: StoreOf<KeypadFeature>) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Call Keypad"
        view.backgroundColor = .systemBackground
        buildStack()
        buildKeys()
    }

    // MARK: Rendering

    override func render() {
        digitsLabel.text = store.displayText
        digitsLabel.accessibilityLabel = store.digitsAccessibilityLabel
    }

    // MARK: Layout

    /// The digits over the key rows, centered in the safe area.
    private func buildStack() {
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        let safeArea = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: safeArea.centerYAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: safeArea.topAnchor, constant: Metrics.verticalMargin),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: safeArea.bottomAnchor, constant: -Metrics.verticalMargin),
        ])
        stack.addArrangedSubview(digitsLabel)
    }

    private func buildKeys() {
        for digits in [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["*", "0", "#"]] {
            let row = UIStackView(axis: .horizontal, spacing: Metrics.keySpacing)
            for digit in digits {
                row.addArrangedSubview(keyButton(digit))
            }
            stack.addArrangedSubview(row)
        }
    }

    private func keyButton(_ digit: String) -> UIButton {
        let key = phoneButton(digit, color: .label) { [weak self] in
            self?.keyTapped(digit)
        }
        key.accessibilityLabel = "Send DTMF \(digit)"
        NSLayoutConstraint.activate([
            key.widthAnchor.constraint(equalToConstant: Metrics.keyWidth),
            key.heightAnchor.constraint(equalToConstant: Metrics.keyHeight),
        ])
        return key
    }

    // MARK: Actions

    private func keyTapped(_ digit: String) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        send(.digitTapped(digit))
    }
}

private enum Metrics {
    static let rowSpacing: CGFloat = 12
    static let verticalMargin: CGFloat = 8
    static let keySpacing: CGFloat = 24
    static let keyWidth: CGFloat = 62
    static let keyHeight: CGFloat = 54
}

#if DEBUG
#Preview("Call · DTMF Keypad") {
    let store = AirSIMPreviewFixtures.presentation(callState: "active").store
    store.send(.activeCall(.view(.keypadButtonTapped)))
    let keypad = store.scope(state: \.activeCall.keypad, action: \.activeCall.keypad.presented)!
    return AirSIMPreviewFixtures.navigation(DTMFKeypadViewController(store: keypad))
}
#endif
