import ComposableArchitecture
import UIKit

@MainActor
final class DTMFKeypadViewController: ObservingViewController {
    let store: StoreOf<KeypadFeature>
    private let digits = phoneLabel("Tap keys to send DTMF tones", size: 20)
    init(store: StoreOf<KeypadFeature>) { self.store = store; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "Call Keypad"; view.backgroundColor = .systemBackground
        let stack = UIStackView(); stack.axis = .vertical; stack.spacing = 12; stack.alignment = .center; stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: view.centerXAnchor), stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor), stack.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: 8), stack.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8)])
        digits.accessibilityLabel = "No digits entered"; stack.addArrangedSubview(digits)
        let digitRows: [[String]] = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["*", "0", "#"]]
        for rowDigits in digitRows {
            let row = UIStackView(); row.axis = .horizontal; row.spacing = 24
            for digit in rowDigits {
                let key = phoneButton(digit, color: .label) { [weak self] in
                    guard let self else { return }; UIImpactFeedbackGenerator(style: .light).impactOccurred(); self.store.send(.digitTapped(digit))
                }; key.accessibilityLabel = "Send DTMF \(digit)"; key.widthAnchor.constraint(equalToConstant: 62).isActive = true; key.heightAnchor.constraint(equalToConstant: 54).isActive = true; row.addArrangedSubview(key)
            }; stack.addArrangedSubview(row)
        }
    }
    override func render() { let entered = store.digits; digits.text = entered.isEmpty ? "Tap keys to send DTMF tones" : entered; digits.accessibilityLabel = entered.isEmpty ? "No digits entered" : entered }
}

#if DEBUG
#Preview("Call · DTMF Keypad") {
    let model = AirSIMPreviewFixtures.presentation(callState: "active")
    model.store.send(.keypadButtonTapped)
    return AirSIMPreviewFixtures.navigation(DTMFKeypadViewController(store: model.store.scope(state: \.keypad, action: \.keypad.presented)!))
}
#endif
