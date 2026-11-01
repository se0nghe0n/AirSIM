import UIKit

@MainActor
func phoneEmptyState(_ title: String, image: String, detail: String) -> UIView {
    let symbol = UIImageView(image: UIImage(systemName: image))
    symbol.tintColor = .secondaryLabel
    symbol.contentMode = .scaleAspectFit
    symbol.heightAnchor.constraint(equalToConstant: Metrics.iconSize).isActive = true
    let heading = phoneLabel(title)
    heading.font = UIFontMetrics(forTextStyle: .headline).scaledFont(for: .systemFont(ofSize: 17, weight: .semibold))
    heading.textAlignment = .center
    let subtitle = phoneLabel(detail, size: Metrics.detailSize, color: .secondaryLabel)
    subtitle.textAlignment = .center
    let stack = UIStackView(
        [symbol, heading, subtitle],
        axis: .vertical,
        spacing: Metrics.spacing,
        alignment: .center
    )
    NSLayoutConstraint.activate([
        heading.widthAnchor.constraint(equalTo: stack.widthAnchor),
        subtitle.widthAnchor.constraint(equalTo: stack.widthAnchor),
    ])
    let container = UIView()
    stack.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(stack)
    NSLayoutConstraint.activate([
        stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Metrics.horizontalInset),
        stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Metrics.horizontalInset),
        stack.topAnchor.constraint(greaterThanOrEqualTo: container.topAnchor, constant: Metrics.verticalPadding),
        stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -Metrics.verticalPadding),
    ])
    return container
}

@MainActor
func nativePhoneEmptyState(_ title: String, image: String, detail: String, minimumHeight: CGFloat) -> UIView {
    var configuration = UIContentUnavailableConfiguration.empty()
    configuration.text = title
    configuration.image = UIImage(systemName: image)
    configuration.secondaryText = detail
    let title3 = UIFontMetrics(forTextStyle: .title3)
    configuration.textProperties.font = title3.scaledFont(for: .boldSystemFont(ofSize: 20))
    configuration.secondaryTextProperties.font = title3.scaledFont(for: .systemFont(ofSize: 20))
    configuration.imageProperties.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 44)
    let view = UIContentUnavailableView(configuration: configuration)
    view.heightAnchor.constraint(greaterThanOrEqualToConstant: minimumHeight).isActive = true
    return view
}

private enum Metrics {
    static let iconSize: CGFloat = 34
    static let detailSize: CGFloat = 15
    static let spacing: CGFloat = 12
    static let horizontalInset: CGFloat = 16
    static let verticalPadding: CGFloat = 40
}

#if DEBUG
#Preview("Component · Custom Empty State") {
    AirSIMPreviewFixtures.canvas(
        phoneEmptyState("No recordings yet", image: "waveform", detail: "Tap Record during a connected call."),
        height: 260
    )
}

#Preview("Component · Native Empty State") {
    AirSIMPreviewFixtures.canvas(
        nativePhoneEmptyState(
            "No Recents",
            image: "phone.arrow.up.right",
            detail: "Your call history appears here after a call.",
            minimumHeight: 300
        ),
        height: 320
    )
}
#endif
