import UIKit

enum DialPadDeletePolicy {
    static func removingLast(from number: String) -> String {
        String(number.dropLast())
    }
}

private struct DialPadLayoutMetrics {
    let keySize: CGFloat
    let keySpacing: CGFloat
    let sectionSpacing: CGFloat
    let numberFontSize: CGFloat
    let numberHeight: CGFloat
    let contactHeight: CGFloat

    var keypadWidth: CGFloat { keySize * 3 + keySpacing * 2 }
    var digitFontSize: CGFloat { min(31, max(23, keySize * 0.34)) }
    var letterFontSize: CGFloat { min(10, max(8, keySize * 0.115)) }
    var callIconSize: CGFloat { min(30, max(23, keySize * 0.33)) }

    init(availableHeight: CGFloat, availableWidth: CGFloat, compactWidth: Bool) {
        let compactHeight = availableHeight < 700
        let desiredKeySize: CGFloat = compactWidth ? 84 : 90
        let desiredKeySpacing: CGFloat = compactWidth ? 28 : 34
        let reservedHeight: CGFloat = compactHeight ? 205 : 220
        let verticalKeySize = (availableHeight - reservedHeight) / 5
        let contentWidth = min(520, max(0, availableWidth - 32))
        let horizontalKeySize = (contentWidth - desiredKeySpacing * 2) / 3

        keySize = min(desiredKeySize, max(56, min(verticalKeySize, horizontalKeySize)))
        keySpacing = min(
            desiredKeySpacing,
            max(14, (contentWidth - keySize * 3) / 2)
        )
        sectionSpacing = compactHeight ? 8 : (compactWidth ? 12 : 16)
        numberFontSize = compactHeight ? 32 : (compactWidth ? 36 : 42)
        numberHeight = compactHeight ? 40 : 46
        contactHeight = compactHeight ? 18 : 20
    }
}

@MainActor
final class DialPadViewController: ObservingViewController {
    let model: AirSIMPresentation
    private let number = phoneLabel(size: 36)
    private let contact = phoneLabel(size: 16, color: .systemGreen)
    private let agentButton = phoneButton("Paired Android Agents") {}
    private var agentContents: UIView?
    private var agentHeight: NSLayoutConstraint!
    private var callButton: UIButton!
    private var deleteButton: UIButton!
    private var deleteTask: Task<Void, Never>?
    private var keys: [UIButton] = []
    private let stack = UIStackView()
    private var keyRows: [UIStackView] = []
    private var rowWidths: [NSLayoutConstraint] = []
    private var keyHeight: NSLayoutConstraint!
    private var numberHeight: NSLayoutConstraint!
    private var contactHeight: NSLayoutConstraint!
    private var contentWidth: NSLayoutConstraint!
    private var lastLayoutSize = CGSize.zero
    init(model: AirSIMPresentation) { self.model = model; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        let backdrop = PhoneBackdropView()
        backdrop.isUserInteractionEnabled = false
        backdrop.accessibilityElementsHidden = true
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(backdrop, at: 0)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: view.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        navigationItem.title = "Dial"; navigationItem.largeTitleDisplayMode = .never
        stack.axis = .vertical; stack.spacing = 12; stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
        contentWidth = stack.widthAnchor.constraint(equalToConstant: 360)
        contentWidth.isActive = true
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: view.centerXAnchor), stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor), stack.widthAnchor.constraint(lessThanOrEqualToConstant: 520), stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16), stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16), stack.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: 4), stack.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -4)])
        number.font = UIFont.systemFont(ofSize: 36, weight: .light).rounded()
        number.adjustsFontSizeToFitWidth = true; number.minimumScaleFactor = 0.45; number.numberOfLines = 1; number.textAlignment = .center
        stack.addArrangedSubview(number); stack.setCustomSpacing(2, after: number); stack.addArrangedSubview(contact)
        numberHeight = number.heightAnchor.constraint(equalToConstant: 46); numberHeight.isActive = true
        contactHeight = contact.heightAnchor.constraint(equalToConstant: 20); contactHeight.isActive = true
        agentButton.titleLabel?.numberOfLines = 3
        agentButton.addAction(UIAction { [weak self] _ in guard let self else { return }; self.showPhoneSheet(PairedAndroidAgentsViewController(model: self.model)) }, for: .touchUpInside)
        stack.addArrangedSubview(agentButton)
        agentButton.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        agentHeight = agentButton.heightAnchor.constraint(equalToConstant: 94); agentHeight.isActive = true
        let letters: [String] = ["", "ABC", "DEF", "GHI", "JKL", "MNO", "PQRS", "TUV", "WXYZ", "", "+", ""]
        let digitRows: [[String]] = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["*", "0", "#"]]
        for (rowIndex, digits) in digitRows.enumerated() {
            let row = UIStackView(); row.axis = .horizontal; row.spacing = 28; row.distribution = .fillEqually
            for (column, digit) in digits.enumerated() {
                let subtitle = letters[rowIndex * 3 + column]
                let button = phoneButton(digit, color: .label) { [weak self] in self?.enter(digit) }
                var configuration: UIButton.Configuration
                if #available(iOS 26.0, *) { configuration = .glass() } else { configuration = .gray() }
                configuration.baseForegroundColor = .label; configuration.cornerStyle = .capsule
                var digitAttributes = AttributeContainer()
                digitAttributes.font = UIFontMetrics(forTextStyle: .title1).scaledFont(for: .systemFont(ofSize: 31, weight: .regular))
                var letterAttributes = AttributeContainer()
                letterAttributes.font = UIFontMetrics(forTextStyle: .caption2).scaledFont(for: .systemFont(ofSize: 10, weight: .semibold))
                configuration.attributedTitle = AttributedString(digit, attributes: digitAttributes)
                configuration.attributedSubtitle = AttributedString(subtitle, attributes: letterAttributes)
                configuration.titleAlignment = .center
                configuration.titlePadding = 0
                if #unavailable(iOS 26.0) {
                    configuration.background.backgroundColor = .tertiarySystemFill
                    configuration.background.strokeColor = UIColor.label.withAlphaComponent(0.12)
                    configuration.background.strokeWidth = 0.5
                }
                configuration.contentInsets = .zero
                button.configuration = configuration
                button.accessibilityLabel = subtitle.isEmpty ? digit : "\(digit) \(subtitle)"
                button.widthAnchor.constraint(equalTo: button.heightAnchor).isActive = true
                if digit == "0" { button.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(longZero(_:)))) }
                row.addArrangedSubview(button); keys.append(button)
            }
            stack.addArrangedSubview(row)
            let width = row.widthAnchor.constraint(equalToConstant: 308); width.isActive = true; rowWidths.append(width); keyRows.append(row)
        }
        let actions = UIStackView(); actions.axis = .horizontal; actions.spacing = 28; actions.distribution = .fillEqually
        let blank = UIView(); actions.addArrangedSubview(blank)
        callButton = phoneButton("Dial", image: "phone.fill", color: .white) { [weak self] in guard let self else { return }; Task { await self.model.dial() } }
        callButton.configuration?.title = nil
        callButton.configuration?.background.backgroundColor = .systemGreen
        callButton.configuration?.image = UIImage(systemName: "phone.fill")?.withTintColor(.white, renderingMode: .alwaysOriginal)
        callButton.configurationUpdateHandler = { button in
            button.configuration?.background.backgroundColor = .systemGreen
            button.configuration?.image = UIImage(systemName: "phone.fill")?.withTintColor(.white, renderingMode: .alwaysOriginal)
        }
        callButton.accessibilityIdentifier = "dialCall"
        deleteButton = phoneButton("Delete", image: "delete.left", color: .secondaryLabel) {}
        deleteButton.configuration?.title = nil
        deleteButton.configuration?.background.backgroundColor = .clear
        deleteButton.configuration?.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 18)
        deleteButton.accessibilityHint = "Tap to delete one digit; hold to keep deleting"
        (deleteButton as? PhoneActionButton)?.accessibilityAction = { [weak self] in
            guard let self else { return }
            self.model.numberInput = DialPadDeletePolicy.removingLast(from: self.model.numberInput)
        }
        deleteButton.addTarget(self, action: #selector(beginDelete), for: .touchDown)
        deleteButton.addTarget(self, action: #selector(stopDelete), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        actions.addArrangedSubview(callButton); actions.addArrangedSubview(deleteButton)
        stack.addArrangedSubview(actions); let width = actions.widthAnchor.constraint(equalToConstant: 308); width.isActive = true; rowWidths.append(width); keyRows.append(actions)
        actions.heightAnchor.constraint(equalTo: keys[0].heightAnchor).isActive = true
        keyHeight = keys[0].heightAnchor.constraint(equalToConstant: 84); keyHeight.isActive = true
    }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); navigationController?.setNavigationBarHidden(true, animated: false) }
    override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); stopDelete(); navigationController?.setNavigationBarHidden(false, animated: false) }
    override func render() {
        number.text = model.numberInput.isEmpty ? "Enter number" : model.numberInput
        number.textColor = model.numberInput.isEmpty ? .secondaryLabel : .label
        contact.text = model.contacts.contact(for: model.numberInput)?.name ?? " "
        callButton.isEnabled = !model.numberInput.isEmpty && !model.isBusy && model.canStartOutgoingCommand
        let callOpacity: CGFloat = model.numberInput.isEmpty || !model.canStartOutgoingCommand ? 0.4 : 1
        callButton.alpha = callButton.isEnabled ? callOpacity : callOpacity * 0.5
        deleteButton.isEnabled = !model.numberInput.isEmpty
        agentButton.isHidden = model.currentAndroidAgent == nil && model.pairedAndroidAgents.isEmpty
        agentButton.configuration = nil
        agentContents?.removeFromSuperview()
        let card = AndroidAgentCardView(agent: model.currentAndroidAgent, count: model.pairedAndroidAgents.count, cloudEnabled: CloudModePreference.isEnabled())
        card.isUserInteractionEnabled = false; card.translatesAutoresizingMaskIntoConstraints = false; agentButton.addSubview(card); agentContents = card
        agentHeight.constant = model.currentAndroidAgent == nil ? 74 : 94
        NSLayoutConstraint.activate([card.leadingAnchor.constraint(equalTo: agentButton.leadingAnchor), card.trailingAnchor.constraint(equalTo: agentButton.trailingAnchor), card.topAnchor.constraint(equalTo: agentButton.topAnchor), card.bottomAnchor.constraint(equalTo: agentButton.bottomAnchor)])

    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let area = view.safeAreaLayoutGuide.layoutFrame
        guard area.size != lastLayoutSize else { return }; lastLayoutSize = area.size
        let metrics = DialPadLayoutMetrics(availableHeight: area.height, availableWidth: area.width, compactWidth: traitCollection.horizontalSizeClass == .compact)
        keyHeight.constant = metrics.keySize; contentWidth.constant = min(520, max(0, area.width - 32))
        numberHeight.constant = metrics.numberHeight; contactHeight.constant = metrics.contactHeight
        number.font = UIFont.systemFont(ofSize: metrics.numberFontSize, weight: .light).rounded()
        stack.spacing = metrics.sectionSpacing; stack.setCustomSpacing(2, after: number)
        for row in keyRows { row.spacing = metrics.keySpacing }
        for width in rowWidths { width.constant = metrics.keypadWidth }
        let labels: [String] = ["", "ABC", "DEF", "GHI", "JKL", "MNO", "PQRS", "TUV", "WXYZ", "", "+", ""]
        let digits: [String] = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "*", "0", "#"]
        for (index, key) in keys.enumerated() {
            var digit = AttributeContainer(); digit.font = UIFont.systemFont(ofSize: metrics.digitFontSize).rounded()
            var letters = AttributeContainer(); letters.font = UIFont.systemFont(ofSize: metrics.letterFontSize, weight: .semibold); letters.kern = 1.4
            key.configuration?.attributedTitle = AttributedString(digits[index], attributes: digit)
            key.configuration?.attributedSubtitle = AttributedString(labels[index], attributes: letters)
            key.configuration?.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var attributes = incoming; attributes.font = .systemFont(ofSize: metrics.letterFontSize, weight: .semibold); attributes.kern = 1.4; return attributes
            }
        }
        callButton.configuration?.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: metrics.callIconSize, weight: .semibold)
    }
    private func enter(_ digit: String) { model.numberInput.append(digit); if !model.isMuted { UIDevice.current.playInputClick() } }
    @objc private func longZero(_ gesture: UILongPressGestureRecognizer) { if gesture.state == .began { enter("+") } }
    @objc private func beginDelete() {
        stopDelete(); model.numberInput = DialPadDeletePolicy.removingLast(from: model.numberInput)
        deleteTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            while !Task.isCancelled, let self, !self.model.numberInput.isEmpty {
                self.model.numberInput = DialPadDeletePolicy.removingLast(from: self.model.numberInput)
                try? await Task.sleep(for: .milliseconds(90))
            }
        }
    }
    @objc private func stopDelete() { deleteTask?.cancel(); deleteTask = nil }
}

#if DEBUG
#Preview("Dial · Connected Agent") {
    AirSIMPreviewFixtures.navigation(DialPadViewController(model: AirSIMPreviewFixtures.presentation()))
}
#endif
