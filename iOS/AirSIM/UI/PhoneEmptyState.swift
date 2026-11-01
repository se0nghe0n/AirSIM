import UIKit

@MainActor
func phoneEmptyState(_ title: String, image: String, detail: String, minimumHeight: CGFloat = 300, iconSize: CGFloat = 44, detailSize: CGFloat = 20, spacing: CGFloat = 8, verticalPadding: CGFloat = 24, headingSize: CGFloat = 20) -> UIView {
    let container = UIView()
    let symbol = UIImageView(image: UIImage(systemName: image)); symbol.tintColor = .secondaryLabel; symbol.contentMode = .scaleAspectFit
    symbol.heightAnchor.constraint(equalToConstant: iconSize).isActive = true
    let heading = phoneLabel(title, size: headingSize); heading.font = UIFontMetrics(forTextStyle: .headline).scaledFont(for: .systemFont(ofSize: headingSize, weight: headingSize == 17 ? .semibold : .bold)); heading.textAlignment = .center
    let subtitle = phoneLabel(detail, size: detailSize, color: .secondaryLabel); subtitle.textAlignment = .center
    let stack = UIStackView(arrangedSubviews: [symbol, heading, subtitle]); stack.axis = .vertical; stack.spacing = spacing; stack.alignment = .center
    heading.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true; subtitle.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    stack.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(stack)
    NSLayoutConstraint.activate([container.heightAnchor.constraint(greaterThanOrEqualToConstant: minimumHeight), stack.centerYAnchor.constraint(equalTo: container.centerYAnchor), stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16), stack.topAnchor.constraint(greaterThanOrEqualTo: container.topAnchor, constant: verticalPadding), stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -verticalPadding)])
    return container
}

@MainActor
func nativePhoneEmptyState(_ title: String, image: String, detail: String, minimumHeight: CGFloat) -> UIView {
    var configuration = UIContentUnavailableConfiguration.empty()
    configuration.text = title; configuration.image = UIImage(systemName: image); configuration.secondaryText = detail
    configuration.textProperties.font = UIFontMetrics(forTextStyle: .title3).scaledFont(for: .boldSystemFont(ofSize: 20))
    configuration.secondaryTextProperties.font = UIFontMetrics(forTextStyle: .title3).scaledFont(for: .systemFont(ofSize: 20))
    configuration.imageProperties.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 44)
    let view = UIContentUnavailableView(configuration: configuration)
    view.heightAnchor.constraint(greaterThanOrEqualToConstant: minimumHeight).isActive = true
    return view
}

#if DEBUG
#Preview("Component · Custom Empty State") {
    AirSIMPreviewFixtures.canvas(phoneEmptyState("No recordings yet", image: "waveform", detail: "Tap Record during a connected call.", minimumHeight: 0, iconSize: 34, detailSize: 15, spacing: 12, verticalPadding: 40, headingSize: 17), height: 260)
}

#Preview("Component · Native Empty State") {
    AirSIMPreviewFixtures.canvas(nativePhoneEmptyState("No Recents", image: "phone.arrow.up.right", detail: "Your call history appears here after a call.", minimumHeight: 300), height: 320)
}
#endif
