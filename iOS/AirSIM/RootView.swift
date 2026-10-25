import SwiftUI

enum SystemCommunicationDestination: Equatable {
    case call(String)
    case message(String)
    case liveActivity(AirSIMLiveActivityAction, callID: String)
}

enum SystemCommunicationURL {
    static func destination(for url: URL) -> SystemCommunicationDestination? {
        if let action = AirSIMLiveActivityActionURL.parse(url) {
            return .liveActivity(action.action, callID: action.callID)
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "tel" || scheme == "im" else {
            return nil
        }
        let prefixLength = scheme.count + 1
        guard url.absoluteString.count > prefixLength else { return nil }
        var target = String(url.absoluteString.dropFirst(prefixLength))
        while target.hasPrefix("//") { target.removeFirst(2) }
        target = String(target.split(separator: "?", maxSplits: 1).first ?? "")
        target = target.removingPercentEncoding ?? target
        target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }
        return scheme == "tel" ? .call(target) : .message(target)
    }
}

enum PhoneTab: String, CaseIterable, Identifiable {
    case dial = "Dial"
    case recents = "Recents"
    case messages = "Messages"
    case contacts = "Contacts"
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .dial: return "circle.grid.3x3"
        case .recents: return "clock"
        case .messages: return "message"
        case .contacts: return "person.crop.circle"
        case .settings: return "gearshape"
        }
    }

    var tabTitle: String {
        switch self {
        case .recents: return "Recents"
        case .contacts: return "Contacts"
        default: return rawValue
        }
    }
}

/// Uses the system TabView for the five main destinations; the native iOS 26 tab bar handles
/// Liquid Glass, long-press zoom, and selection state, avoiding conflicts between paging gestures and custom buttons.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @AppStorage("airsim.selected-tab") private var selectedTabRawValue = PhoneTab.dial.rawValue
    @State private var pendingSMSRecipient: String?
    @State private var pendingSMSConversation: String?
    @AppStorage("airsim.first-connection-complete") private var firstConnectionComplete = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            TabView(selection: selectedTabBinding) {
                DialPadView()
                    .tag(PhoneTab.dial)
                    .tabItem { Label(L10n.t(PhoneTab.dial.tabTitle), systemImage: PhoneTab.dial.icon) }

                RecentsView(onCall: dial, onMessage: composeMessage)
                    .tag(PhoneTab.recents)
                    .tabItem { Label(L10n.t(PhoneTab.recents.tabTitle), systemImage: PhoneTab.recents.icon) }

                MessagesView(
                    pendingRecipient: $pendingSMSRecipient,
                    pendingConversation: $pendingSMSConversation
                )
                    .tag(PhoneTab.messages)
                    .tabItem { Label(L10n.t(PhoneTab.messages.tabTitle), systemImage: PhoneTab.messages.icon) }

                ContactsView(onCall: dial, onMessage: composeMessage)
                    .tag(PhoneTab.contacts)
                    .tabItem { Label(L10n.t(PhoneTab.contacts.tabTitle), systemImage: PhoneTab.contacts.icon) }

                AirSIMSettingsView()
                    .tag(PhoneTab.settings)
                    .tabItem { Label(L10n.t(PhoneTab.settings.tabTitle), systemImage: PhoneTab.settings.icon) }
            }
            .phoneTabBarMinimizeOnScroll()
            .phoneTabSelectionFeedback(selectedTabRawValue)
            .tint(.blue)

            if let call = model.inAppPresentedCall {
                ActiveCallView(call: call)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
#if DEBUG
            if let call = Self.layoutPreviewCall {
                // Presentation-only fixture: never changes AppModel or sends call commands.
                ActiveCallView(call: call)
            }
#endif
        }
#if DEBUG
        .allowsHitTesting(Self.layoutPreviewCall == nil)
#endif
        .background(PhoneBackdrop())
        .animation(.easeInOut(duration: 0.2), value: model.inAppPresentedCall?.id)
        .preferredColorScheme(settings.appearance.colorScheme)
        .fullScreenCover(isPresented: Binding(
            get: { !firstConnectionComplete },
            set: { if !$0 { firstConnectionComplete = true } }
        )) {
            AirSIMFirstConnectionView()
                .environment(model)
        }
        .onOpenURL(perform: handleSystemCommunicationURL)
        .onAppear {
            if let sender = IncomingSMSPresentationRequest.consume() {
                openSMSConversation(sender)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .airsimRemoteSMSReceived)) { _ in
            model.reloadMessagesFromLocalStore()
        }
        .onReceive(NotificationCenter.default.publisher(for: .airsimOpenSMSConversation)) { notification in
            let sender = IncomingSMSPresentationRequest.consume()
                ?? notification.userInfo?["sender"] as? String
            guard let sender else {
                selectedTab = .messages
                return
            }
            openSMSConversation(sender)
        }
        .onReceive(NotificationCenter.default.publisher(for: .airsimOpenIncomingCall)) { _ in
            model.presentCurrentCallInApp()
        }
        .alert(L10n.t("Error"), isPresented: errorBinding) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

#if DEBUG
    private static var layoutPreviewCall: CallRecord? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--airsim-layout-call"),
              arguments.indices.contains(index + 1),
              ["incoming", "active"].contains(arguments[index + 1]) else { return nil }
        return CallRecord(
            id: "layout-preview", index: 0, direction: "incoming",
            state: arguments[index + 1], number: "+1 202 555 0100",
            startedAt: Date().addingTimeInterval(-65), updatedAt: Date(),
            endedAt: nil, missed: false
        )
    }
#endif

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage?.isEmpty == false },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }

    private var selectedTabBinding: Binding<PhoneTab> {
        Binding(
            get: { PhoneTab(rawValue: selectedTabRawValue) ?? .dial },
            set: { newTab in
                guard newTab.rawValue != selectedTabRawValue else { return }
                selectedTabRawValue = newTab.rawValue
            }
        )
    }

    private var selectedTab: PhoneTab {
        get { PhoneTab(rawValue: selectedTabRawValue) ?? .dial }
        nonmutating set { selectedTabRawValue = newValue.rawValue }
    }

    private func dial(_ number: String) {
        model.numberInput = number
        selectedTab = .dial
        Task { await model.dial() }
    }

    private func composeMessage(_ number: String) {
        pendingSMSRecipient = number
        selectedTab = .messages
    }

    private func openSMSConversation(_ sender: String) {
        model.reloadMessagesFromLocalStore()
        pendingSMSConversation = sender
        selectedTab = .messages
    }

    private func handleSystemCommunicationURL(_ url: URL) {
        switch SystemCommunicationURL.destination(for: url) {
        case let .call(number):
            dial(number)
        case let .message(recipient):
            composeMessage(recipient)
        case let .liveActivity(action, callID):
            Task {
                guard LiveActivityActionGate.accepts(callID: callID,
                        currentCallID: model.callLifecycleSnapshot.callID,
                        callIsLive: model.callLifecycleSnapshot.state.representsCall
                            && model.callLifecycleSnapshot.state != .ending) else { return }
                switch action {
                case .answer: await model.answer()
                case .reject: await model.reject()
                case .hangup: await model.hangup()
                }
            }
        case nil:
            break
        }
    }
}

/// Uses a pure white background like the system Phone app in light mode; draws a dark blue-black ambient bottom glow only in dark mode.
struct PhoneBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if colorScheme == .dark {
                Color(red: 0.008, green: 0.016, blue: 0.035)
                LinearGradient(
                    colors: [
                        Color.clear,
                        Color(red: 0.018, green: 0.075, blue: 0.16).opacity(0.72),
                        Color(red: 0.025, green: 0.20, blue: 0.48).opacity(0.62),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            } else {
                Color.white
            }
        }
        .ignoresSafeArea()
    }
}

/// Uses native system Liquid Glass for key content surfaces, falling back to system materials on older OS versions.
struct PhoneCard: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(
                    .regular,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
        } else {
            content
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
        }
    }
}

struct PhoneGlassSurface: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color?
    let interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            let glass = interactive
                ? Glass.regular.tint(tint).interactive()
                : Glass.regular.tint(tint)
            content.glassEffect(
                glass,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            content
                .background(
                    .regularMaterial,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.primary.opacity(0.08))
                }
        }
    }
}

/// Custom toolbar material used only on ToolbarItems with hidden system shared backgrounds so there is always a single glass layer.
private struct PhoneToolbarGlassMorph: ViewModifier {
    let id: String
    @Namespace private var glassNamespace

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 14) {
                content
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                    .frame(minWidth: 40, minHeight: 40)
                    .contentShape(Capsule())
                    .glassEffect(.regular.interactive(), in: Capsule())
                    .glassEffectID(id, in: glassNamespace)
                    .glassEffectTransition(.materialize)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.82)))
        } else {
            content
        }
    }
}

/// Hides the navigation bar's auto-generated shared button background on iOS 26 and applies the single-layer morphing glass above;
/// older OS versions continue using the platform default style on ToolbarItem.
@ToolbarContentBuilder
func phoneMorphingToolbarItem<Content: View>(
    placement: ToolbarItemPlacement,
    id: String,
    @ViewBuilder content: () -> Content
) -> some ToolbarContent {
    if #available(iOS 26.0, *) {
        ToolbarItem(placement: placement) {
            content().phoneToolbarGlassMorph(id: id)
        }
        .sharedBackgroundVisibility(.hidden)
    } else {
        ToolbarItem(placement: placement, content: content)
    }
}

extension View {
    func phoneCard() -> some View { modifier(PhoneCard()) }

    func phoneGlassSurface(
        cornerRadius: CGFloat = 18,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        modifier(PhoneGlassSurface(
            cornerRadius: cornerRadius,
            tint: tint,
            interactive: interactive
        ))
    }

    @ViewBuilder
    func phoneTabBarMinimizeOnScroll() -> some View {
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }

    func phoneToolbarGlassMorph(id: String) -> some View {
        modifier(PhoneToolbarGlassMorph(id: id))
    }

    func phoneTabSelectionFeedback(_ trigger: String) -> some View {
        sensoryFeedback(.selection, trigger: trigger)
    }
}

private struct PhoneTabBarCompactStateActionKey: EnvironmentKey {
    static let defaultValue: (Bool) -> Void = { _ in }
}

extension EnvironmentValues {
    fileprivate var phoneTabBarCompactStateAction: (Bool) -> Void {
        get { self[PhoneTabBarCompactStateActionKey.self] }
        set { self[PhoneTabBarCompactStateActionKey.self] = newValue }
    }
}

private struct PhoneTabBarCompactScrollReporter: ViewModifier {
    @Environment(\.phoneTabBarCompactStateAction) private var reportCompactState

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                max(0, geometry.contentOffset.y + geometry.contentInsets.top)
            } action: { oldOffset, newOffset in
                let delta = newOffset - oldOffset
                if newOffset < 2 {
                    reportCompactState(false)
                } else if delta > 2 {
                    reportCompactState(true)
                } else if delta < -2 {
                    reportCompactState(false)
                }
            }
        } else {
            content
        }
    }
}

extension View {
    func phoneReportsTabBarCompactState() -> some View {
        modifier(PhoneTabBarCompactScrollReporter())
    }
}

#Preview("Root View") {
    let model = AppModel()
    UserDefaults.standard.set(true, forKey: "airsim.first-connection-complete")
    return RootView()
        .environment(model)
        .environment(model.contacts)
        .environment(model.audio)
        .environment(AppSettings())
}
