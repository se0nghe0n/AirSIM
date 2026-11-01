import UIKit

@MainActor
final class PhoneListContentView: UIView {
    init(name: String, subtitle: String, photo: Data?, avatarName: String, time: String? = nil, missed: Bool = false, callAction: (() -> Void)? = nil) {
        super.init(frame: .zero)
        let avatar = UIImageView(image: phoneAvatar(name: avatarName, photo: photo, size: 50)); avatar.contentMode = .scaleAspectFill
        avatar.widthAnchor.constraint(equalToConstant: 50).isActive = true; avatar.heightAnchor.constraint(equalToConstant: 50).isActive = true
        let title = phoneLabel(name); title.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17, weight: .semibold)); title.numberOfLines = 1; title.textColor = missed ? .systemRed : .label
        let detail = phoneLabel(subtitle, size: 15, color: missed ? .systemRed : .secondaryLabel); detail.numberOfLines = 1
        let text = UIStackView(arrangedSubviews: [title, detail]); text.axis = .vertical; text.spacing = 3
        let row = UIStackView(arrangedSubviews: [avatar, text]); row.axis = .horizontal; row.spacing = 11; row.alignment = .center
        if let time { let label = phoneLabel(time, size: 15, color: .secondaryLabel); label.numberOfLines = 1; label.textAlignment = .right; label.adjustsFontSizeToFitWidth = true; label.minimumScaleFactor = 0.78; label.widthAnchor.constraint(equalToConstant: 76).isActive = true; row.addArrangedSubview(label) }
        if let callAction { let button = phoneButton("Dial", image: "phone.fill", action: callAction); button.configuration?.title = nil; button.configuration?.background.backgroundColor = .secondarySystemBackground; button.widthAnchor.constraint(equalToConstant: 44).isActive = true; button.heightAnchor.constraint(equalToConstant: 44).isActive = true; row.addArrangedSubview(button) }
        row.translatesAutoresizingMaskIntoConstraints = false; addSubview(row)
        NSLayoutConstraint.activate([heightAnchor.constraint(greaterThanOrEqualToConstant: 74), row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor), row.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 6), row.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -6), row.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

#if DEBUG
#Preview("Component · Phone List Row") {
    AirSIMPreviewFixtures.canvas(PhoneListContentView(name: "Mina Kim", subtitle: "↙ AirSIM Audio", photo: nil, avatarName: "Mina Kim", time: "10:42", callAction: {}), height: 74)
}
#endif
