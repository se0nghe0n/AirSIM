import UIKit

@MainActor
final class PhoneBackdropView: UIView {
    private let gradient = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.addSublayer(gradient)
        updateColors()
        registerForTraitChanges(UITraitCollection.systemTraitsAffectingColorAppearance) { (view: Self, _) in
            view.updateColors()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = bounds
    }

    private func updateColors() {
        if traitCollection.userInterfaceStyle == .dark {
            backgroundColor = UIColor(red: 0.008, green: 0.016, blue: 0.035, alpha: 1)
            gradient.colors = [
                UIColor.clear.cgColor,
                UIColor(red: 0.018, green: 0.075, blue: 0.16, alpha: 0.72).cgColor,
                UIColor(red: 0.025, green: 0.2, blue: 0.48, alpha: 0.62).cgColor,
            ]
        } else {
            backgroundColor = .white
            gradient.colors = [UIColor.clear.cgColor, UIColor.clear.cgColor]
        }
    }
}

#if DEBUG
#Preview("Component · Phone Backdrop") {
    AirSIMPreviewFixtures.canvas(PhoneBackdropView(), height: 560, dark: true)
}
#endif
