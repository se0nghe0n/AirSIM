import SwiftUI
import UIKit

enum RecentCallTimeFormatter {
    static func string(
        for date: Date,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        let currentDay = calendar.dateComponents([.year, .month, .day], from: now)
        // localization.md: use FormatStyle for time and date display so output follows the user locale;
        // 12-hour regions (e.g., en_US) output "2:30 PM" without dropping AM/PM, while 24-hour regions remain "14:30".
        if day == currentDay {
            return date.formatted(
                Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar)
            )
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           day == calendar.dateComponents([.year, .month, .day], from: yesterday) {
            return "Yesterday"
        }
        if day.year == currentDay.year {
            return date.formatted(.dateTime.month(.twoDigits).day(.twoDigits))
        }
        // Cross-year dates follow locale field ordering (e.g., MM/dd/yyyy in English instead of yyyy/MM/dd).
        return date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits))
    }
}

/// A contact may store duplicate entries for the same phone number; since duplicate rows are interchangeable
/// during selection and dialing, deduplicate by number so `ForEach(phones, id: \.self)` has unique IDs (foreach.md).
enum ContactPhoneListPolicy {
    static func displayPhones(for phones: [String]) -> [String] {
        var seen = Set<String>()
        return phones.filter { seen.insert($0).inserted }
    }
}

enum RecentCallDialPolicy {
    static func numberToDial(_ number: String?) -> String? {
        guard let number, !number.isEmpty else { return nil }
        return number
    }
}

enum DialPadDeletePolicy {
    static func removingLast(from number: String) -> String {
        String(number.dropLast())
    }
}

struct DialPadTransportPresentation: Equatable {
    let title: String
    let detail: String
    let systemImage: String
    let transport: CallTransport

    static func make(
        mode: AirSIMConnectionMode = .automatic,
        vowlanOnline: Bool,
        moduleLocalReachable: Bool,
        cloudOnline: Bool
    ) -> DialPadTransportPresentation? {
        let selected = DialRouteSelector.preferred(
            mode: mode,
            vowlanReady: vowlanOnline,
            cloudReady: cloudOnline
        )
        if selected == .vowlan {
            return DialPadTransportPresentation(
                title: "VoWLAN",
                detail: "Calls and audio use the same Wi-Fi or Android hotspot",
                systemImage: "wifi",
                transport: .vowlan
            )
        }
        if selected == .cloud {
            return DialPadTransportPresentation(
                title: "Cloud",
                detail: "Calls and audio use the cloud Relay",
                systemImage: "cloud.fill",
                transport: .cloud
            )
        }
        return nil
    }
}

private enum PhoneListMetrics {
    static let rowHeight: CGFloat = 74
    static let avatarSize: CGFloat = 50
    static let horizontalInset: CGFloat = 16
    static let avatarSpacing: CGFloat = 11
    static let trailingSpacing: CGFloat = 8
    static let timeColumnWidth: CGFloat = 76
    static let actionSize: CGFloat = 44
    static let separatorLeading: CGFloat = horizontalInset + avatarSize + avatarSpacing
}

private struct DialPadLayoutMetrics {
    let keySize: CGFloat
    let keySpacing: CGFloat
    let rowSpacing: CGFloat
    let sectionSpacing: CGFloat
    let verticalPadding: CGFloat
    let numberFontSize: CGFloat
    let numberHeight: CGFloat
    let contactHeight: CGFloat

    var keypadWidth: CGFloat { keySize * 3 + keySpacing * 2 }
    var digitFontSize: CGFloat { min(31, max(23, keySize * 0.34)) }
    var letterFontSize: CGFloat { min(10, max(8, keySize * 0.115)) }
    var callIconSize: CGFloat { min(30, max(23, keySize * 0.33)) }
    var deleteIconSize: CGFloat { min(24, max(19, keySize * 0.27)) }

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
        rowSpacing = compactHeight ? 8 : (compactWidth ? 12 : 16)
        sectionSpacing = compactHeight ? 8 : (compactWidth ? 12 : 16)
        verticalPadding = compactHeight ? 6 : 10
        numberFontSize = compactHeight ? 32 : (compactWidth ? 36 : 42)
        numberHeight = compactHeight ? 40 : 46
        contactHeight = compactHeight ? 18 : 20
    }
}

// MARK: - Dial

struct DialPadView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var deleteRepeatTask: Task<Void, Never>?
    @State private var pairedAgentListPresentation: PairedAgentListPresentation?

    private let rows = [
        [("1", ""), ("2", "ABC"), ("3", "DEF")],
        [("4", "GHI"), ("5", "JKL"), ("6", "MNO")],
        [("7", "PQRS"), ("8", "TUV"), ("9", "WXYZ")],
        [("*", ""), ("0", "+"), ("#", "")],
    ]

    private var matchedName: String? {
        model.contacts.contact(for: model.numberInput)?.name
    }

    private var isCompact: Bool { horizontalSizeClass == .compact }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let metrics = DialPadLayoutMetrics(
                    availableHeight: proxy.size.height,
                    availableWidth: proxy.size.width,
                    compactWidth: isCompact
                )

                VStack(spacing: metrics.sectionSpacing) {
                    VStack(spacing: 2) {
                        Text(model.numberInput.isEmpty ? L10n.t("Enter number") : model.numberInput)
                            .font(.system(
                                size: metrics.numberFontSize,
                                weight: .light,
                                design: .rounded
                            ))
                            .monospacedDigit()
                            .foregroundStyle(model.numberInput.isEmpty ? .secondary : .primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.45)
                            .frame(height: metrics.numberHeight)

                        Text(matchedName ?? " ")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.green)
                            .frame(height: metrics.contactHeight)
                    }
                    .padding(.horizontal, 12)

                    if let currentAgent = model.currentAndroidAgent {
                        DialPadCurrentAgentCard(
                            agent: currentAgent,
                            agentCount: model.pairedAndroidAgents.count,
                            cloudModeEnabled: CloudModePreference.isEnabled()
                        ) {
                            pairedAgentListPresentation = PairedAgentListPresentation()
                        }
                    } else if !model.pairedAndroidAgents.isEmpty {
                        Button {
                            pairedAgentListPresentation = PairedAgentListPresentation()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "smartphone.slash")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Paired Android Agents · \(model.pairedAndroidAgents.count)")
                                        .font(.subheadline.weight(.semibold))
                                    Text("No call route is currently available")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }

                    DialPadKeyGrid(rows: rows, metrics: metrics)
                    dialActions(metrics: metrics)
                }
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding(.horizontal, 16)
                .padding(.vertical, metrics.verticalPadding)
            }
            .phoneReportsTabBarCompactState()
            .background(PhoneBackdrop())
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $pairedAgentListPresentation) { _ in
                PairedAndroidAgentsView(
                    agents: model.pairedAndroidAgents,
                    cloudModeEnabled: CloudModePreference.isEnabled(),
                    selectAgent: { agentID in
                        model.bindAndroidAgent(agentID)
                    }
                )
            }
            .onDisappear(perform: stopRepeatingDelete)
        }
    }

    private func dialActions(metrics: DialPadLayoutMetrics) -> some View {
        HStack(spacing: metrics.keySpacing) {
            Color.clear.frame(width: metrics.keySize, height: metrics.keySize)
            Button {
                Task { await model.dial() }
            } label: {
                Circle()
                    .fill(.green)
                    .frame(width: metrics.keySize, height: metrics.keySize)
                    .overlay {
                        Image(systemName: "phone.fill")
                            .font(.system(size: metrics.callIconSize, weight: .semibold))
                            .foregroundStyle(.white)
                    }
            }
            .buttonStyle(.plain)
            .disabled(
                model.numberInput.isEmpty
                    || model.isBusy
                    || !model.canStartOutgoingCommand
            )
            .opacity(model.numberInput.isEmpty || !model.canStartOutgoingCommand ? 0.4 : 1)

            Image(systemName: "delete.left")
                .font(.system(size: metrics.deleteIconSize))
                .foregroundStyle(.secondary)
                .frame(width: metrics.keySize, height: metrics.keySize)
                .contentShape(Rectangle())
                .gesture(deleteGesture)
                .allowsHitTesting(!model.numberInput.isEmpty)
                .opacity(model.numberInput.isEmpty ? 0.4 : 1)
                .accessibilityLabel(L10n.t("Delete"))
                .accessibilityHint(L10n.t("Tap to delete one digit; hold to keep deleting"))
                .accessibilityAddTraits(.isButton)
        }
        .frame(width: metrics.keypadWidth)
    }

    private func deleteLastDigit() {
        guard !model.numberInput.isEmpty else { return }
        model.numberInput = DialPadDeletePolicy.removingLast(from: model.numberInput)
    }

    private func beginDeleting() {
        guard deleteRepeatTask == nil, !model.numberInput.isEmpty else { return }
        deleteLastDigit()
        deleteRepeatTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
            while !Task.isCancelled, !model.numberInput.isEmpty {
                deleteLastDigit()
                try? await Task.sleep(for: .milliseconds(90))
            }
            deleteRepeatTask = nil
        }
    }

    private func stopRepeatingDelete() {
        deleteRepeatTask?.cancel()
        deleteRepeatTask = nil
    }

    private var deleteGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in beginDeleting() }
            .onEnded { _ in stopRepeatingDelete() }
    }
}

/// Isolated subview for the dial keypad: typing digits invalidates only the number text and call button
/// without rebuilding the 12-key Liquid Glass subtree (structure.md invalidation boundary).
private struct DialPadKeyGrid: View {
    @Environment(AppModel.self) private var model
    @State private var zeroWasLongPressed = false
    @State private var dialKeyFeedback = DialKeyFeedback()
    let rows: [[(String, String)]]
    let metrics: DialPadLayoutMetrics

    var body: some View {
        dialKeyGrid
    }

    @ViewBuilder
    private var dialKeyGrid: some View {
        if #available(iOS 26.0, *) {
            // The glass merge distance must be noticeably smaller than the actual key spacing so Liquid Glass does not fuse adjacent circular keys.
            GlassEffectContainer(spacing: 6) {
                dialKeyRows
            }
        } else {
            dialKeyRows
        }
    }

    private var dialKeyRows: some View {
        VStack(spacing: metrics.rowSpacing) {
            // rows is a constant layout table where each row starts with a distinct digit; use it as content identity
            // instead of positional offset/id identity discouraged by foreach.md.
            ForEach(rows, id: \.first?.0) { row in
                HStack(spacing: metrics.keySpacing) {
                    ForEach(row, id: \.0) { digit, letters in
                        dialKey(digit: digit, letters: letters)
                    }
                }
            }
        }
        .frame(width: metrics.keypadWidth)
    }

    private func playDialKeySound() {
        guard !model.isMuted else { return }
        dialKeyFeedback.play()
    }

    private func dialKey(
        digit: String,
        letters: String
    ) -> some View {
        Button {
            guard !(digit == "0" && zeroWasLongPressed) else {
                zeroWasLongPressed = false
                return
            }
            model.numberInput.append(digit)
            playDialKeySound()
        } label: {
            VStack(spacing: 0) {
                Text(digit)
                    .font(.system(size: metrics.digitFontSize, weight: .regular, design: .rounded))
                Text(letters)
                    .font(.system(size: metrics.letterFontSize, weight: .semibold))
                    .tracking(1.4)
            }
            .foregroundStyle(.primary)
            .frame(width: metrics.keySize, height: metrics.keySize)
            .dialKeySurface()
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                if digit == "0" {
                    zeroWasLongPressed = true
                    model.numberInput.append("+")
                    playDialKeySound()
                }
            }
        )
        .accessibilityLabel(letters.isEmpty ? digit : "\(digit) \(letters)")
    }
}

private struct PairedAgentListPresentation: Identifiable {
    let id = "paired-android-agents"
}

private struct DialPadCurrentAgentCard: View {
    let agent: AndroidAgentPresentation
    let agentCount: Int
    let cloudModeEnabled: Bool
    let showAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "smartphone")
                    .font(.headline)
                    .foregroundStyle(.green)
                    .frame(width: 34, height: 34)
                    .background(Color.green.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(agent.deviceName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text("Current")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.12), in: Capsule())
                    }
                    Text(agent.phoneNumber ?? "Number unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if agentCount > 1 {
                    Button("All \(agentCount)", action: showAll)
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(.blue)
                }
            }

            HStack(spacing: 8) {
                AgentTransportPill(title: "VoWLAN", online: agent.vowlanOnline, enabled: true)
                AgentTransportPill(title: "Cloud", online: agent.cloudOnline, enabled: cloudModeEnabled)
                Spacer(minLength: 0)
                Text(agent.agentKindTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 0.5)
        }
    }
}

private struct AgentTransportPill: View {
    let title: String
    let online: Bool
    let enabled: Bool

    private var color: Color { !enabled ? .secondary : (online ? .green : .secondary) }

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(title) \(!enabled ? "Off" : (online ? "Online" : "Offline"))")
                .font(.caption2.weight(.medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(color.opacity(0.1), in: Capsule())
    }
}

private struct PairedAndroidAgentsView: View {
    @Environment(\.dismiss) private var dismiss
    let agents: [AndroidAgentPresentation]
    let cloudModeEnabled: Bool
    let selectAgent: (String) -> Void

    var body: some View {
        NavigationStack {
            List(agents) { agent in
                Button {
                    selectAgent(agent.id)
                } label: {
                    VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(agent.deviceName)
                                .font(.headline)
                            Text(agent.phoneNumber ?? "Number unavailable")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                            Image(systemName: agent.isCurrent ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(agent.isCurrent ? .green : .secondary)
                    }
                    HStack(spacing: 8) {
                        AgentTransportPill(title: "VoWLAN", online: agent.vowlanOnline, enabled: true)
                        AgentTransportPill(title: "Cloud", online: agent.cloudOnline, enabled: cloudModeEnabled)
                        Spacer()
                        Text(agent.agentKindTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    }
                    .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
            }
            .overlay {
                if agents.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "smartphone.slash")
                            .font(.system(size: 34))
                            .foregroundStyle(.secondary)
                        Text("No paired Android Agents")
                            .font(.headline)
                    }
                }
            }
            .navigationTitle("Paired Android Agents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("Done")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Uses the system input click sound without starting a new audio session so CallKit routing is not disturbed.
private final class DialKeyFeedback {
    func play() {
        UIDevice.current.playInputClick()
    }
}

// MARK: - Recents

struct RecentsView: View {
    @Environment(AppModel.self) private var model
    @Environment(ContactStore.self) private var contacts
    let onCall: (String) -> Void
    let onMessage: (String) -> Void
    @State private var selectedCall: CallRecord?
    @State private var suppressNextCallTap = false

    var body: some View {
        ZStack {
            NavigationStack {
                Group {
                    if model.callHistory.isEmpty {
                        ScrollView {
                            EmptyStateView(
                                title: L10n.t("No Recents"),
                                systemImage: "phone.arrow.up.right"
                            )
                            .frame(maxWidth: .infinity, minHeight: 300)
                        }
                    } else {
                        List(model.callHistory) { call in
                            let contact = call.number.flatMap { contacts.contact(for: $0) }
                            Button {
                                if suppressNextCallTap {
                                    suppressNextCallTap = false
                                    return
                                }
                                if let number = RecentCallDialPolicy.numberToDial(call.number) {
                                    onCall(number)
                                }
                            } label: {
                                CallHistoryRow(
                                    call: call,
                                    contact: contact,
                                    displayName: contact?.name ?? contacts.displayName(for: call.number)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(RecentCallDialPolicy.numberToDial(call.number) == nil)
                            .simultaneousGesture(
                                LongPressGesture(minimumDuration: 0.38).onEnded { _ in
                                    guard call.number?.isEmpty == false else { return }
                                    suppressNextCallTap = true
                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.84)) {
                                        selectedCall = call
                                    }
                                }
                            )
                            .accessibilityHint("Tap to call back; touch and hold for details")
                            .listRowBackground(Color.clear)
                            .listRowInsets(.init(
                                top: 0,
                                leading: PhoneListMetrics.horizontalInset,
                                bottom: 0,
                                trailing: PhoneListMetrics.horizontalInset
                            ))
                            .alignmentGuide(.listRowSeparatorLeading) { _ in
                                PhoneListMetrics.separatorLeading
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    model.deleteCallHistory(ids: [call.id])
                                } label: {
                                    Label(L10n.t("Delete"), systemImage: "trash")
                                }
                                if let number = call.number {
                                    Button { onMessage(number) } label: {
                                        Label(L10n.t("Messages"), systemImage: "message.fill")
                                    }
                                    .tint(.blue)
                                    Button { onCall(number) } label: {
                                        Label(L10n.t("Dial"), systemImage: "phone.fill")
                                    }
                                    .tint(.green)
                                }
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .environment(\.defaultMinListRowHeight, PhoneListMetrics.rowHeight)
                        .phoneReportsTabBarCompactState()
                    }
                }
                .background(PhoneBackdrop())
                .navigationTitle(L10n.t("Recents"))
                .refreshable { await model.refreshCallHistory() }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        NavigationLink {
                            CallRecordingsView(store: model.recordings)
                        } label: {
                            Label("Recordings", systemImage: "waveform")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        if model.isRefreshingCallHistory {
                            ProgressView().accessibilityLabel("Refreshing call history")
                        } else {
                            Button {
                                Task { await model.refreshCallHistory() }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .accessibilityLabel("Refresh call history")
                        }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    if let message = model.callHistoryMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(.regularMaterial)
                    }
                }
            }
            .allowsHitTesting(selectedCall == nil)

            if let call = selectedCall,
               let number = RecentCallDialPolicy.numberToDial(call.number) {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .onTapGesture(perform: dismissCallDetails)
                    .transition(.opacity)

                RecentCallDetailsCard(
                    call: call,
                    number: number,
                    onCall: onCall,
                    onMessage: onMessage,
                    onDelete: { model.deleteCallHistory(ids: [call.id]) },
                    onDismiss: dismissCallDetails
                )
                .padding(.horizontal, 28)
                .transition(.scale(scale: 0.88).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: selectedCall?.id)
        .task { await model.refreshCallHistory() }
    }

    private func dismissCallDetails() {
        withAnimation(.easeInOut(duration: 0.18)) {
            selectedCall = nil
        }
    }

    /// Isolated subview for the call detail sheet: call history refreshes and other invalidations do not rebuild sheet content
    /// (structure.md invalidation boundary).
    private struct RecentCallDetailsCard: View {
        @Environment(ContactStore.self) private var contacts
        let call: CallRecord
        let number: String
        let onCall: (String) -> Void
        let onMessage: (String) -> Void
        let onDelete: () -> Void
        let onDismiss: () -> Void

        var body: some View {
            let contact = contacts.contact(for: number)
            let displayName = contact?.name ?? contacts.displayName(for: number)

            return VStack(spacing: 16) {
                InitialAvatar(
                    name: displayName,
                    photoData: contact?.photoData,
                    fallbackContent: RecentAvatarPolicy.content(contactName: contact?.name),
                    size: 58
                )

                VStack(spacing: 4) {
                    Text(displayName)
                        .font(.title3.weight(.semibold))
                    Text(number)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(RecentCallTimeFormatter.string(for: call.startedAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button {
                    onDismiss()
                    onCall(number)
                } label: {
                    Label(L10n.t("Call Back"), systemImage: "phone.fill")
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.large)

                Button {
                    onDismiss()
                    onMessage(number)
                } label: {
                    Label(L10n.t("Send Message"), systemImage: "message.fill")
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button(role: .destructive) {
                    onDismiss()
                    onDelete()
                } label: {
                    Label(L10n.t("Delete Call Record"), systemImage: "trash")
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button(L10n.t("Cancel"), action: onDismiss)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 34)
            }
            .padding(22)
            .frame(maxWidth: 340)
            .phoneGlassSurface(cornerRadius: 28)
            .shadow(color: .black.opacity(0.14), radius: 20, y: 8)
        }
    }

    private struct CallHistoryRow: View {
        let call: CallRecord
        let contact: ContactStore.Contact?
        let displayName: String

        var body: some View {
            HStack(spacing: PhoneListMetrics.avatarSpacing) {
                InitialAvatar(
                    name: displayName,
                    photoData: contact?.photoData,
                    fallbackContent: RecentAvatarPolicy.content(contactName: contact?.name),
                    size: PhoneListMetrics.avatarSize
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(displayName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(call.missed ? .red : .primary)
                    HStack(spacing: 4) {
                        Image(systemName: call.direction == "incoming" ? "arrow.down.left" : "arrow.up.right")
                            .font(.caption2.weight(.semibold))
                        Text(call.missed ? L10n.t("Missed") : "AirSIM Audio")
                    }
                    .font(.subheadline)
                    .foregroundStyle(call.missed ? .red : .secondary)
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(RecentCallTimeFormatter.string(for: call.startedAt))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .frame(width: PhoneListMetrics.timeColumnWidth, alignment: .trailing)

                Image(systemName: "phone.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.blue)
                    .frame(width: PhoneListMetrics.actionSize, height: PhoneListMetrics.actionSize)
                    .background(Color(uiColor: .secondarySystemBackground), in: Circle())
            }
            .frame(minHeight: PhoneListMetrics.rowHeight)
        }
    }
}

// MARK: - Messages

struct MessagesView: View {
    @Environment(AppModel.self) private var model
    @Binding var pendingRecipient: String?
    @Binding var pendingConversation: String?
    @State private var conversationPath: [String] = []
    @State private var showingComposer = false
    @State private var showingClearConfirmation = false

    var body: some View {
        NavigationStack(path: $conversationPath) {
            List {
                if model.conversations.isEmpty {
                    EmptyStateView(title: L10n.t("No Messages"), systemImage: "message")
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(model.conversations, id: \.sender) { conversation in
                        NavigationLink(value: conversation.sender) {
                            MessageConversationRow(sender: conversation.sender, messages: conversation.messages)
                                .contentShape(Rectangle())
                        }
                        .listRowBackground(Color.clear)
                        .listRowInsets(.init(
                            top: 0,
                            leading: PhoneListMetrics.horizontalInset,
                            bottom: 0,
                            trailing: PhoneListMetrics.horizontalInset
                        ))
                        .alignmentGuide(.listRowSeparatorLeading) { _ in
                            PhoneListMetrics.separatorLeading
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, PhoneListMetrics.rowHeight)
            .phoneReportsTabBarCompactState()
            .background(PhoneBackdrop())
            .navigationTitle(L10n.t("Messages"))
            .navigationDestination(for: String.self) { sender in
                MessageThreadView(sender: sender)
            }
            .toolbar {
                phoneMorphingToolbarItem(placement: .topBarLeading, id: "top-action-leading-more") {
                    Menu {
                        Button { Task { await model.refreshMessages() } } label: {
                            Label(L10n.t("Refresh"), systemImage: "arrow.clockwise")
                        }
                        Button(role: .destructive) { showingClearConfirmation = true } label: {
                            Label(L10n.t("Clear all SMS"), systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.body.weight(.semibold))
                    }
                    .accessibilityLabel("Message Actions")
                }
                phoneMorphingToolbarItem(placement: .topBarTrailing, id: "top-action-trailing-primary") {
                    Button { showingComposer = true } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel(L10n.t("New Message"))
                }
            }
            .task {
                await model.loadMessagesFromAgent(silently: true)
            }
            .onAppear { showPendingConversation() }
            .onChange(of: pendingRecipient) { _, recipient in
                if recipient != nil { showingComposer = true }
            }
            .onChange(of: pendingConversation) { showPendingConversation() }
            .sheet(isPresented: $showingComposer, onDismiss: { pendingRecipient = nil }) {
                MessageComposer(initialRecipient: pendingRecipient ?? "")
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .confirmationDialog(L10n.t("Clear all SMS"), isPresented: $showingClearConfirmation, titleVisibility: .visible) {
                Button(L10n.t("Delete"), role: .destructive) {
                    Task {
                        try? await model.api.clearModuleSMS()
                        model.clearLocalMessages()
                    }
                }
                Button(L10n.t("Cancel"), role: .cancel) {}
            } message: {
                Text("This permanently deletes local messages and undelivered module messages.")
            }
        }
    }

    private func showPendingConversation() {
        guard let sender = pendingConversation else { return }
        conversationPath = [sender]
        pendingConversation = nil
    }

    private struct MessageConversationRow: View {
        @Environment(AppModel.self) private var model
        let sender: String
        let messages: [SMSMessage]

        private var contact: ContactStore.Contact? {
            model.contacts.contact(for: sender)
        }

        private var displayName: String {
            contact?.name ?? model.contacts.displayName(for: sender)
        }

        var body: some View {
            HStack(spacing: PhoneListMetrics.avatarSpacing) {
                InitialAvatar(
                    name: displayName,
                    photoData: contact?.photoData,
                    fallbackContent: contact == nil
                        ? .person
                        : RecentAvatarPolicy.content(contactName: contact?.name),
                    size: PhoneListMetrics.avatarSize
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(displayName)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Text(messages.last?.content ?? "")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(messages.last?.timestamp ?? .now, style: .time)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: PhoneListMetrics.timeColumnWidth, alignment: .trailing)
            }
            .frame(minHeight: PhoneListMetrics.rowHeight)
        }
    }
}

private struct MessageThreadView: View {
    @Environment(AppModel.self) private var model
    let sender: String
    @State private var reply = ""
    // foreach.md: in-thread filtering and sorting are recomputed only when the message collection changes.
    @State private var messages: [SMSMessage] = []

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 9) {
                        ForEach(messages) { message in
                            HStack {
                                if message.isOutgoing { Spacer(minLength: 48) }
                                VStack(
                                    alignment: message.isOutgoing ? .trailing : .leading,
                                    spacing: 3
                                ) {
                                    Text(message.content)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 9)
                                        .background(
                                            message.isOutgoing
                                                ? Color.blue
                                                : Color(uiColor: .secondarySystemBackground),
                                            in: RoundedRectangle(cornerRadius: 18)
                                        )
                                        .foregroundStyle(message.isOutgoing ? .white : .primary)
                                    if message.isOutgoing {
                                        Text(L10n.t("Sent"))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                if !message.isOutgoing { Spacer(minLength: 48) }
                            }
                            .id(message.id)
                        }
                    }
                    .padding()
                }
                // review round 2 #3: when messages is still empty on the first frame, scrollTo in onAppear has no row to target;
                // iOS 17 defaultScrollAnchor(.bottom) anchors the conversation to the latest message immediately on open.
                .defaultScrollAnchor(.bottom)
                .onAppear { if let id = messages.last?.id { proxy.scrollTo(id) } }
            }
            .onChange(of: model.messages, initial: true) { _, allMessages in
                messages = allMessages
                    .filter { $0.sender == sender }
                    .sorted { $0.timestamp < $1.timestamp }
            }
            Divider()
            HStack(spacing: 10) {
                TextField(L10n.t("Message"), text: $reply, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                Button {
                    let body = reply
                    reply = ""
                    Task { _ = await model.sendSMS(to: sender, content: body) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .navigationTitle(model.contacts.displayName(for: sender))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct MessageComposer: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var recipient: String
    @State private var content = ""
    @State private var sending = false
    @State private var showingContacts = false

    init(initialRecipient: String) { _recipient = State(initialValue: initialRecipient) }

    private var matchedContact: ContactStore.Contact? {
        model.contacts.contact(for: recipient)
    }

    private var suggestions: [ContactStore.Contact] {
        let query = recipient.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, matchedContact == nil else { return [] }
        return Array(model.contacts.contacts.filter { contact in
            contact.name.localizedCaseInsensitiveContains(query)
                || contact.phones.contains {
                    $0.localizedCaseInsensitiveContains(query) || $0.hasSuffix(query)
                }
        }.prefix(5))
    }

    private var canSend: Bool {
        !recipient.trimmingCharacters(in: .whitespaces).isEmpty
            && !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !sending
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                recipientBar

                if !suggestions.isEmpty {
                    Divider()
                    contactSuggestions
                }

                Divider()
                Spacer(minLength: 0)
                Divider()
                messageInputBar
            }
            .background(PhoneBackdrop())
            .navigationTitle(L10n.t("New Message"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("Send"), action: sendNow)
                        .disabled(!canSend)
                }
            }
            .task { await model.contacts.loadIfAuthorized() }
            .sheet(isPresented: $showingContacts) {
                MessageContactPicker { phone in
                    recipient = phone
                    showingContacts = false
                }
                .environment(model)
            }
        }
    }

    private var recipientBar: some View {
        HStack(spacing: 9) {
            Button {
                showingContacts = true
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.t("Choose from Contacts"))

            Text(L10n.t("To:"))
                .foregroundStyle(.secondary)

            TextField(L10n.t("Enter number or name"), text: $recipient)
                .textFieldStyle(.plain)
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)

            if let contact = matchedContact {
                HStack(spacing: 6) {
                    InitialAvatar(name: contact.name, photoData: contact.photoData, size: 28)
                    Text(contact.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: 130, alignment: .trailing)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Recognized contact: \(contact.name)")
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
    }

    private var contactSuggestions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(suggestions) { contact in
                    Button {
                        recipient = contact.phones.first ?? recipient
                    } label: {
                        HStack(spacing: 7) {
                            InitialAvatar(name: contact.name, photoData: contact.photoData, size: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(contact.name)
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(contact.phones.first ?? "")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Color(uiColor: .secondarySystemGroupedBackground),
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private var messageInputBar: some View {
        VStack(spacing: 5) {
            HStack(alignment: .bottom, spacing: 9) {
                TextField(L10n.t("Message"), text: $content, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(
                        Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )

                Button(action: sendNow) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(
                            canSend ? Color.blue : Color.secondary.opacity(0.4),
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel(L10n.t("Send"))
            }

            Text(L10n.t("Messages are sent through the 4G module"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(uiColor: .systemBackground))
    }

    private func sendNow() {
        guard canSend else { return }
        sending = true
        Task {
            if await model.sendSMS(to: recipient, content: content) { dismiss() }
            sending = false
        }
    }
}

private struct MessageContactPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var search = ""
    let onSelect: (String) -> Void

    private var filteredContacts: [ContactStore.Contact] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return model.contacts.contacts }
        return model.contacts.contacts.filter { contact in
            contact.name.localizedCaseInsensitiveContains(query)
                || contact.phones.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if !model.contacts.isAuthorized {
                    EmptyStateView(
                        title: L10n.t("Allow Contacts Access"),
                        systemImage: "person.crop.circle.badge.questionmark",
                        actionTitle: L10n.t("Allow Contacts Access")
                    ) {
                        Task { await model.contacts.requestAccessAndLoad() }
                    }
                } else if filteredContacts.isEmpty {
                    EmptyStateView(title: L10n.t("No contacts"), systemImage: "person.2")
                } else {
                    List(filteredContacts) { contact in
                        ForEach(ContactPhoneListPolicy.displayPhones(for: contact.phones), id: \.self) { phone in
                            Button {
                                onSelect(phone)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    InitialAvatar(name: contact.name, photoData: contact.photoData)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(contact.name)
                                            .font(.body.weight(.semibold))
                                            .foregroundStyle(.primary)
                                        Text(phone)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(L10n.t("Choose Contact"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: L10n.t("Search name or number"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Cancel")) { dismiss() }
                }
            }
            .task { await model.contacts.loadIfAuthorized() }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Contacts

struct ContactsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let onCall: (String) -> Void
    let onMessage: (String) -> Void
    @State private var search = ""

    private var filtered: [ContactStore.Contact] {
        guard !search.isEmpty else { return model.contacts.contacts }
        return model.contacts.contacts.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.phones.contains { $0.contains(search) }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if !model.contacts.isAuthorized {
                    EmptyStateView(
                        title: model.contacts.authorizationState == .denied
                            ? "Contacts access is disabled"
                            : L10n.t("Allow Contacts Access"),
                        systemImage: "person.crop.circle.badge.questionmark",
                        actionTitle: model.contacts.authorizationState == .denied
                            ? "Open Settings"
                            : L10n.t("Allow Contacts Access")
                    ) {
                        if model.contacts.authorizationState == .denied {
                            openURL(URL(string: UIApplication.openSettingsURLString)!)
                        } else {
                            Task { await model.contacts.requestAccessAndLoad() }
                        }
                    }
                } else if filtered.isEmpty {
                    EmptyStateView(title: L10n.t("No contacts"), systemImage: "person.2")
                } else {
                    List(filtered) { contact in
                        NavigationLink {
                            ContactDetailView(contact: contact, onCall: onCall, onMessage: onMessage)
                        } label: {
                            HStack(spacing: PhoneListMetrics.avatarSpacing) {
                                InitialAvatar(
                                    name: contact.name,
                                    photoData: contact.photoData,
                                    fallbackContent: RecentAvatarPolicy.content(contactName: contact.name),
                                    size: PhoneListMetrics.avatarSize
                                )
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(contact.name)
                                        .font(.body.weight(.semibold))
                                        .lineLimit(1)
                                    Text(contact.phones.first ?? "")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(minHeight: PhoneListMetrics.rowHeight)
                        }
                        .listRowBackground(Color.clear)
                        .listRowInsets(.init(
                            top: 0,
                            leading: PhoneListMetrics.horizontalInset,
                            bottom: 0,
                            trailing: PhoneListMetrics.horizontalInset
                        ))
                        .alignmentGuide(.listRowSeparatorLeading) { _ in
                            PhoneListMetrics.separatorLeading
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .environment(\.defaultMinListRowHeight, PhoneListMetrics.rowHeight)
                    .phoneReportsTabBarCompactState()
                }
            }
            .background(PhoneBackdrop())
            .navigationTitle("\(L10n.t("Contacts")) · \(model.contacts.contacts.count)")
            .searchable(
                text: $search,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: L10n.t("Search name or number")
            )
            .refreshable { await model.contacts.requestAccessAndLoad() }
            .task { await model.contacts.loadIfAuthorized() }
        }
    }
}

private extension View {
    @ViewBuilder
    func dialKeySurface() -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular.interactive(), in: Circle())
        } else {
            background(Color(uiColor: .tertiarySystemFill), in: Circle())
        }
    }
}

private struct ContactDetailView: View {
    let contact: ContactStore.Contact
    let onCall: (String) -> Void
    let onMessage: (String) -> Void

    var body: some View {
        List {
            Section {
                HStack {
                    Spacer()
                    VStack(spacing: 10) {
                        InitialAvatar(name: contact.name, photoData: contact.photoData, size: 82)
                        Text(contact.name).font(.title2.weight(.semibold))
                    }
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }
            Section {
                ForEach(ContactPhoneListPolicy.displayPhones(for: contact.phones), id: \.self) { phone in
                    HStack {
                        Text(phone)
                            .font(.body.monospacedDigit())
                        Spacer()
                        HStack(spacing: 12) {
                            Button { onMessage(phone) } label: {
                                Image(systemName: "message.fill")
                                    .foregroundStyle(.blue)
                                    .frame(width: 42, height: 42)
                                    .background(Color.blue.opacity(0.12), in: Circle())
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(L10n.t("Send Message"))

                            Button { onCall(phone) } label: {
                                Image(systemName: "phone.fill")
                                    .foregroundStyle(.green)
                                    .frame(width: 42, height: 42)
                                    .background(Color.green.opacity(0.12), in: Circle())
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(L10n.t("Dial"))
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(contact.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

enum AvatarFallbackContent: Equatable {
    case person
    case initial(String)
}

enum RecentAvatarPolicy {
    static func content(contactName: String?) -> AvatarFallbackContent {
        let trimmed = contactName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let first = trimmed.first else { return .person }
        return .initial(String(first))
    }
}

struct InitialAvatar: View {
    let name: String
    var photoData: Data? = nil
    var fallbackContent: AvatarFallbackContent? = nil
    var size: CGFloat = 44

    private var resolvedFallback: AvatarFallbackContent {
        fallbackContent
            ?? .initial(String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)))
    }

    var body: some View {
        Group {
            if let photoData, let image = UIImage(data: photoData) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                avatarFallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var avatarFallback: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: fallbackColors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                switch resolvedFallback {
                case .person:
                    Image(systemName: "person.fill")
                        .font(.system(size: size * 0.52, weight: .semibold))
                        .foregroundStyle(.white)
                        .offset(y: size * 0.08)
                case let .initial(initial):
                    Text(initial)
                        .font(.system(size: size * 0.46, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(color: Color.indigo.opacity(0.55), radius: 1.4, x: 0, y: 1.2)
                        .overlay {
                            Text(initial)
                                .font(.system(size: size * 0.46, weight: .bold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.28))
                                .offset(y: -0.8)
                        }
                }
            }
            .overlay {
                Circle().stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.5), .white.opacity(0.06)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            }
            .shadow(color: fallbackColors.last?.opacity(0.22) ?? .clear, radius: 3, y: 2)
    }

    private var fallbackColors: [Color] {
        switch resolvedFallback {
        case .person:
            return [
                Color(red: 0.64, green: 0.76, blue: 0.91),
                Color(red: 0.43, green: 0.48, blue: 0.78),
            ]
        case .initial:
            return [
                Color(red: 0.66, green: 0.78, blue: 0.92),
                Color(red: 0.43, green: 0.49, blue: 0.79),
            ]
        }
    }
}

/// Uses native system ContentUnavailableView to present empty states.
private struct EmptyStateView: View {
    let title: String
    let systemImage: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(emptyStateDescription)
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var emptyStateDescription: String {
        switch systemImage {
        case "message": return "Received messages appear here."
        case "phone.arrow.up.right": return "Your call history appears here after a call."
        case "person.2": return "Contacts sync from your device address book."
        default: return "Connect or grant access to get started."
        }
    }
}

// MARK: - Call Overlay

enum CallSurfacePhase: Equatable {
    case incoming
    case connected
}

enum CallSurfaceAction: Equatable {
    case decline
    case answer
    case mute
    case end
    case keypad
    case speaker
}

struct CallSurfaceContent: Equatable {
    let phase: CallSurfacePhase
    let primaryActions: [CallSurfaceAction]
    let secondaryActions: [CallSurfaceAction]
    let showsDuration: Bool

    init(state: String) {
        if ["incoming", "waiting"].contains(state) {
            phase = .incoming
            primaryActions = [.decline, .answer]
            secondaryActions = []
            showsDuration = false
        } else {
            phase = .connected
            primaryActions = [.end]
            secondaryActions = [.mute, .keypad, .speaker]
            showsDuration = true
        }
    }
}

enum CallProximityPolicy {
    static func shouldMonitor(state: String, speakerEnabled: Bool) -> Bool {
        guard !speakerEnabled else { return false }
        return ["dialing", "alerting", "connecting", "active", "held", "ending"].contains(state)
    }
}

struct ActiveCallView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let call: CallRecord
    @State private var showingKeypad = false

    private var content: CallSurfaceContent { CallSurfaceContent(state: call.state) }
    private func avatarSize(isCompact: Bool) -> CGFloat {
        content.phase == .incoming ? (isCompact ? 116 : 132) : (isCompact ? 92 : 112)
    }
    private var displayName: String { model.contacts.displayName(for: call.number) }
    private var contactPhotoData: Data? {
        guard let number = call.number else { return nil }
        return model.contacts.contact(for: number)?.photoData
    }

    var body: some View {
        ZStack {
            CallBackdrop()
            GeometryReader { proxy in
                let isCompact = horizontalSizeClass == .compact || proxy.size.height < 700
                Group {
                    if content.phase == .incoming {
                        incomingSurface(isCompact: isCompact)
                    } else {
                        connectedSurface(isCompact: isCompact)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, isCompact ? 20 : 32)
                .padding(.vertical, isCompact ? 18 : 26)
            }
        }
        // Incoming call alerts and active calls are focused full-screen tasks. Keep a fixed canvas to avoid
        // ScrollView drag/bounce and prevent accidental gestures from interfering with answer or hangup.
        .contentShape(Rectangle())
        .sheet(isPresented: $showingKeypad) { DTMFKeypadView() }
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .onAppear { updateProximityMonitoring() }
        .onChange(of: call.state) { updateProximityMonitoring() }
        .onChange(of: model.audio.speakerEnabled) { updateProximityMonitoring() }
        .onDisappear { UIDevice.current.isProximityMonitoringEnabled = false }
    }

    private func incomingSurface(isCompact: Bool) -> some View {
        VStack(spacing: 0) {
            callHeader(title: "AirSIM Incoming Call", showsRecording: false)

            Spacer(minLength: 0)

            InitialAvatar(
                name: displayName,
                photoData: contactPhotoData,
                size: avatarSize(isCompact: isCompact)
            )
            .overlay { Circle().strokeBorder(.white.opacity(0.20), lineWidth: 1) }
            .shadow(color: .black.opacity(0.34), radius: 28, y: 16)
            .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text(displayName)
                    .font(isCompact ? .system(size: 38, weight: .semibold) : .system(size: 44, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.68)
                    .multilineTextAlignment(.center)

                if let number = call.number, number != displayName {
                    Text(number)
                        .font(.title3.weight(.regular).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.68))
                        .textSelection(.enabled)
                }

                Text(L10n.t("Waiting"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.62))
            }
            .padding(.top, 24)

            connectivityBadge
                .padding(.top, 22)

            Spacer(minLength: 0)

            HStack {
                CallDecisionButton(
                    title: L10n.t("Decline"),
                    icon: "phone.down.fill",
                    color: .red
                ) {
                    Task { await model.reject() }
                }

                Spacer(minLength: 56)

                CallDecisionButton(
                    title: L10n.t("Accept"),
                    icon: "phone.fill",
                    color: .green
                ) {
                    Task { await model.answer() }
                }
            }
            .frame(maxWidth: 430)
            .padding(.horizontal, isCompact ? 12 : 28)
            .padding(.bottom, isCompact ? 16 : 28)
        }
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.985)))
    }

    private func connectedSurface(isCompact: Bool) -> some View {
        let controlSize: CGFloat = isCompact ? 62 : 68
        return VStack(spacing: 0) {
            callHeader(title: "AirSIM Call", showsRecording: true)

            Spacer(minLength: 0)

            InitialAvatar(name: displayName, photoData: contactPhotoData, size: avatarSize(isCompact: isCompact))
                .overlay { Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1) }
                .shadow(color: .black.opacity(0.28), radius: 22, y: 12)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text(displayName)
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .multilineTextAlignment(.center)
                if let number = call.number, number != displayName {
                    Text(number)
                        .font(.title3.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.66))
                        .textSelection(.enabled)
                }
                if content.showsDuration {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(durationText(at: context.date))
                            .font(.title2.weight(.medium).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.82))
                            .contentTransition(.numericText())
                    }
                }
            }
            .padding(.top, 22)

            audioStatusBadge
                .padding(.top, 20)

            if let audioError = model.audio.errorMessage, !audioError.isEmpty {
                Text(audioError)
                    .font(.caption)
                    .foregroundStyle(Color.red.opacity(0.92))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.top, 10)
            }

            Spacer(minLength: 0)

            HStack(spacing: isCompact ? 20 : 34) {
                CallCircleButton(
                    title: model.isMuted ? L10n.t("Unmute") : L10n.t("Mute"),
                    icon: model.isMuted ? "mic.slash.fill" : "mic.fill",
                    color: model.isMuted ? .orange : nil,
                    foregroundColor: .white,
                    size: controlSize
                ) {
                    Task { await model.toggleMute() }
                }
                CallCircleButton(
                    title: "Keypad",
                    icon: "circle.grid.3x3.fill",
                    color: nil,
                    foregroundColor: .white,
                    size: controlSize
                ) {
                    showingKeypad = true
                }
                SpeakerRouteButton(
                    audio: model.audio,
                    size: controlSize,
                    action: model.toggleSpeaker
                )
            }
            .frame(maxWidth: 430)

            CallDecisionButton(
                title: L10n.t("End"),
                icon: "phone.down.fill",
                color: .red
            ) {
                Task { await model.hangup() }
            }
            .padding(.top, isCompact ? 30 : 42)
            .padding(.bottom, isCompact ? 8 : 18)
        }
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.985)))
    }

    private func callHeader(title: String, showsRecording: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .symbolRenderingMode(.hierarchical)
            Text(title)
            Spacer()
            if showsRecording {
                Button {
                    Task { await model.toggleRecording() }
                } label: {
                    Group {
                        if model.isRecordingBusy {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: model.isRecording ? "record.circle.fill" : "record.circle")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(model.isRecording ? .red : .white)
                        }
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .callControlGlass(tint: model.isRecording ? .red.opacity(0.16) : nil)
                .disabled(!model.canToggleRecording)
                .opacity(model.canToggleRecording ? 1 : 0.45)
                .accessibilityLabel(model.isRecording ? L10n.t("Stop Recording") : L10n.t("Record"))
            }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white.opacity(0.72))
        .frame(maxWidth: 520)
    }

    private var connectivityBadge: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(moduleIsReachable ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(connectivityText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.88))
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 38)
        .callControlGlass(tint: (moduleIsReachable ? Color.green : Color.orange).opacity(0.10))
        .accessibilityElement(children: .combine)
    }

    private var audioStatusBadge: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(model.callAudioIsActive ? Color.green : audioStatusColor)
                .frame(width: 8, height: 8)
            Text(model.callAudioStatusText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.88))
            if model.audio.active, !model.audio.routeDescription.isEmpty {
                Text("· \(model.audio.routeDescription)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 13)
        .frame(minHeight: 38)
        .callControlGlass(tint: audioStatusColor.opacity(0.10))
    }

    private var moduleIsReachable: Bool {
        model.isOnline || model.cloudAgentStatus?.cloudOnline == true
    }

    private var connectivityText: String {
        let status = moduleIsReachable ? "Module Online" : "Connecting to Module"
        let signal = model.modemStatus?.signalDBM ?? model.cloudAgentStatus?.signalDBM
        guard let signal else { return status }
        return "\(status) · Signal \(signal) dBm"
    }

    private var audioStatusColor: Color {
        switch model.cloudCallAudioState {
        case .failed: return .red
        case .connected: return .green
        case .connecting: return .orange
        case .idle: return model.audio.active ? .green : .orange
        }
    }

    private func durationText(at date: Date) -> String {
        let total = max(0, Int(date.timeIntervalSince(call.startedAt)))
        // localization.md: use FormatStyle instead of String(format:); zero-padding matches existing English output
        // and preserves the mm:ss format even when minutes exceed 59 rather than switching to hours.
        return Duration.seconds(total)
            .formatted(.time(pattern: .minuteSecond(padMinuteToLength: 2)))
    }

    private func updateProximityMonitoring() {
        UIDevice.current.isProximityMonitoringEnabled = CallProximityPolicy.shouldMonitor(
            state: call.state,
            speakerEnabled: model.audio.speakerEnabled
        )
    }
}

private struct SpeakerRouteButton: View {
    var audio: AudioSessionController
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        CallCircleButton(
            title: L10n.t("Speaker"),
            icon: audio.speakerEnabled ? "speaker.wave.2.fill" : "speaker.fill",
            color: audio.speakerEnabled ? .blue : nil,
            foregroundColor: .white,
            size: size,
            action: action
        )
    }
}

private struct CallDecisionButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Circle()
                    .fill(color.gradient)
                    .frame(width: 76, height: 76)
                    .overlay {
                        Image(systemName: icon)
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .shadow(color: color.opacity(0.28), radius: 16, y: 8)
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.92))
            }
            .frame(minWidth: 96, minHeight: 108)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

private struct CallCircleButton: View {
    let title: String
    let icon: String
    let color: Color?
    var foregroundColor: Color = .white
    var size: CGFloat = 68
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Circle().fill(.clear).frame(width: size, height: size).overlay {
                    Image(systemName: icon).font(.title2.weight(.semibold)).foregroundStyle(foregroundColor)
                }
                .callControlGlass(tint: color?.opacity(0.24), shape: .circle)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(minWidth: size)
        }
        .buttonStyle(.plain)
    }
}

private struct CallBackdrop: View {
    var body: some View {
        ZStack {
            Color(red: 0.008, green: 0.012, blue: 0.025)
            RadialGradient(
                colors: [Color.blue.opacity(0.24), .clear],
                center: .topTrailing,
                startRadius: 10,
                endRadius: 420
            )
            RadialGradient(
                colors: [Color.cyan.opacity(0.12), .clear],
                center: .bottomLeading,
                startRadius: 20,
                endRadius: 360
            )
        }
        .ignoresSafeArea()
    }
}

private enum CallControlShape { case capsule, circle }

private struct CallControlGlass: ViewModifier {
    let tint: Color?
    let shape: CallControlShape

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            switch shape {
            case .capsule:
                content.glassEffect(.regular.tint(tint).interactive(), in: Capsule())
            case .circle:
                content.glassEffect(.regular.tint(tint).interactive(), in: Circle())
            }
        } else {
            switch shape {
            case .capsule:
                content.background(.ultraThinMaterial, in: Capsule())
            case .circle:
                content.background(.ultraThinMaterial, in: Circle())
            }
        }
    }
}

private extension View {
    func callControlGlass(
        tint: Color? = nil,
        shape: CallControlShape = .capsule
    ) -> some View {
        modifier(CallControlGlass(tint: tint, shape: shape))
    }
}

private struct DTMFKeypadView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(AppModel.self) private var model
    @State private var enteredDigits = ""
    private let rows = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["*", "0", "#"]]

    private var keySize: CGFloat { horizontalSizeClass == .compact ? 62 : 70 }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text(enteredDigits.isEmpty ? "Tap keys to send DTMF tones" : enteredDigits)
                    .font(.system(.title3, design: .rounded).monospacedDigit())
                    .foregroundStyle(enteredDigits.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .contentTransition(.numericText())
                    .accessibilityLabel(enteredDigits.isEmpty ? "No digits entered" : enteredDigits)
                if #available(iOS 26.0, *) {
                    GlassEffectContainer(spacing: 16) { keypad }
                } else {
                    keypad
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
            .navigationTitle("Call Keypad")
            .toolbar { Button(L10n.t("Cancel")) { dismiss() } }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
    }

    private var keypad: some View {
        VStack(spacing: 16) {
            // rows is a constant layout table with distinct row contents; [String] is Hashable so \.self is used directly.
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 24) {
                    // Each digit in a row is unique and constant, providing stable content identity (foreach.md).
                    ForEach(row, id: \.self) { digit in
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            enteredDigits = String((enteredDigits + digit).suffix(18))
                            Task { await model.sendDTMF(digit) }
                        } label: {
                            Text(digit)
                                .font(.system(size: 29, weight: .medium, design: .rounded))
                                .frame(width: keySize, height: keySize)
                                .contentShape(Circle())
                        }
                        .buttonStyle(DTMFGlassButtonStyle())
                        .accessibilityLabel("Send DTMF \(digit)")
                    }
                }
            }
        }
    }
}

private struct DTMFGlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Group {
            if #available(iOS 26.0, *) {
                configuration.label
                    .glassEffect(.regular.tint(configuration.isPressed ? .cyan : .clear).interactive(), in: Circle())
            } else {
                configuration.label
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().fill(Color.cyan.opacity(configuration.isPressed ? 0.28 : 0)))
            }
        }
        .foregroundStyle(configuration.isPressed ? Color.cyan : Color.primary)
        .scaleEffect(configuration.isPressed ? 0.91 : 1)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

#Preview("Dial Pad") {
    let model = AppModel()
    model.numberInput = "+1 202 555 0100"
    return DialPadView()
        .environment(model)
        .environment(model.contacts)
        .environment(model.audio)
}

#Preview("Recents") {
    let model = AppModel()
    model.callHistory = [
        CallRecord(
            id: "preview-call-1",
            index: 1,
            direction: "incoming",
            state: "ended",
            number: "+1 202 555 0100",
            startedAt: Date().addingTimeInterval(-900),
            updatedAt: Date().addingTimeInterval(-840),
            endedAt: Date().addingTimeInterval(-840),
            missed: false
        ),
        CallRecord(
            id: "preview-call-2",
            index: 2,
            direction: "incoming",
            state: "ended",
            number: "+1 202 555 0199",
            startedAt: Date().addingTimeInterval(-7200),
            updatedAt: Date().addingTimeInterval(-7200),
            endedAt: Date().addingTimeInterval(-7200),
            missed: true
        ),
    ]
    return RecentsView(onCall: { _ in }, onMessage: { _ in })
        .environment(model)
        .environment(model.contacts)
}

#Preview("Messages") {
    @Previewable @State var pendingRecipient: String? = nil
    @Previewable @State var pendingConversation: String? = nil
    let model = AppModel()
    model.messages = [
        SMSMessage(
            sender: "+1 202 555 0100",
            content: "Your verification code is 482910.",
            code: "482910",
            timestamp: Date().addingTimeInterval(-300),
            deliveryID: "preview-sms-1",
            direction: .incoming
        ),
        SMSMessage(
            sender: "+1 202 555 0100",
            content: "Got it, thanks!",
            code: nil,
            timestamp: Date().addingTimeInterval(-120),
            deliveryID: "preview-sms-2",
            direction: .outgoing
        ),
    ]
    return MessagesView(
        pendingRecipient: $pendingRecipient,
        pendingConversation: $pendingConversation
    )
    .environment(model)
    .environment(model.contacts)
}

#Preview("Contacts") {
    let model = AppModel()
    return ContactsView(onCall: { _ in }, onMessage: { _ in })
        .environment(model)
        .environment(model.contacts)
}

#Preview("Active Call · Incoming") {
    let model = AppModel()
    let call = CallRecord(
        id: "preview-incoming",
        index: 1,
        direction: "incoming",
        state: "incoming",
        number: "+1 202 555 0100",
        startedAt: Date(),
        updatedAt: Date(),
        endedAt: nil,
        missed: false
    )
    return ActiveCallView(call: call)
        .environment(model)
        .environment(model.contacts)
        .environment(model.audio)
}

#Preview("Active Call · Connected") {
    let model = AppModel()
    let call = CallRecord(
        id: "preview-active",
        index: 1,
        direction: "outgoing",
        state: "active",
        number: "+1 202 555 0100",
        startedAt: Date().addingTimeInterval(-85),
        updatedAt: Date(),
        endedAt: nil,
        missed: false
    )
    return ActiveCallView(call: call)
        .environment(model)
        .environment(model.contacts)
        .environment(model.audio)
}

#Preview("DTMF Keypad") {
    DTMFKeypadView()
        .environment(AppModel())
}

