import UIKit

extension UIStackView {
    convenience init(
        _ arrangedSubviews: [UIView] = [],
        axis: NSLayoutConstraint.Axis,
        spacing: CGFloat = 0,
        alignment: Alignment = .fill,
        distribution: Distribution = .fill
    ) {
        self.init(arrangedSubviews: arrangedSubviews)
        self.axis = axis
        self.spacing = spacing
        self.alignment = alignment
        self.distribution = distribution
    }
}

extension UIView {
    func addPinnedSubview(_ subview: UIView, insets: UIEdgeInsets = .zero) {
        subview.translatesAutoresizingMaskIntoConstraints = false
        addSubview(subview)
        NSLayoutConstraint.activate([
            subview.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
            subview.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right),
            subview.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
            subview.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom),
        ])
    }
}
