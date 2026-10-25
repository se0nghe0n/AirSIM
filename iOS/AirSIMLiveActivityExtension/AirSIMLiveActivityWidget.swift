import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct AirSIMLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        AirSIMLiveActivityWidget()
    }
}

/// Keeps the compact standby state minimal while showing network details and call actions in expanded and lock-screen presentations.
struct AirSIMLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AirSIMCallActivityAttributes.self) { context in
            let state = context.state.liveActivityDisplayState(isStale: context.isStale)
            lockScreenView(state)
                .foregroundStyle(.white)
                .activityBackgroundTint(activityBackgroundTint(for: state))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state.liveActivityDisplayState(isStale: context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    islandIdentity(for: state)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(idleTitle(state))
                            .font(.headline)
                            .lineLimit(1)
                        Text(activityStatusLine(state))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(tint(for: state.phase))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    expandedTrailingView(state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    expandedBottomView(state)
                }
            } compactLeading: {
                compactLeadingView(state)
            } compactTrailing: {
                compactTrailingView(state)
            } minimal: {
                Image(systemName: compactSymbolName(for: state))
                    .foregroundStyle(tint(for: state.phase))
            }
            .keylineTint(tint(for: state.phase))
        }
    }

    @ViewBuilder
    private func islandIdentity(
        for state: AirSIMCallActivityAttributes.ContentState
    ) -> some View {
        if state.phase == .standby || state.phase == .cloudStandby {
            statusMark(for: state.phase, size: 32)
        } else if state.phase == .incoming || state.phase == .active || state.phase == .held {
            callerMark(size: 32)
        } else {
            statusMark(for: state.phase, size: 32)
        }
    }

    @ViewBuilder
    private func compactLeadingView(
        _ state: AirSIMCallActivityAttributes.ContentState
    ) -> some View {
        if state.phase == .standby || state.phase == .cloudStandby {
            Image(systemName: compactSymbolName(for: state))
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint(for: state.phase))
        } else {
            Image(systemName: symbolName(for: state.phase))
                .foregroundStyle(tint(for: state.phase))
        }
    }

    @ViewBuilder
    private func expandedTrailingView(
        _ state: AirSIMCallActivityAttributes.ContentState
    ) -> some View {
        switch state.phase {
        case .standby:
            pairedAgentCountView(state)
        case .cloudStandby:
            pairedAgentCountView(state)
        case .active:
            Text(state.startedAt, style: .timer)
                .font(.caption.weight(.semibold).monospacedDigit())
        case .incoming:
            Image(systemName: "phone.badge.waveform.fill")
                .foregroundStyle(.green)
        case .held:
            Text("On Hold")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
        case .offline:
            Text("Offline")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func lockScreenView(
        _ state: AirSIMCallActivityAttributes.ContentState
    ) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                if state.phase == .standby || state.phase == .cloudStandby {
                    statusMark(for: state.phase, size: 44)
                } else if state.phase == .incoming || state.phase == .active || state.phase == .held {
                    callerMark(size: 44)
                } else {
                    statusMark(for: state.phase, size: 44)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(idleTitle(state))
                        .font(.headline)
                        .lineLimit(1)
                    if state.phase == .standby {
                        HStack(spacing: 5) {
                            Circle().fill(Color.green).frame(width: 7, height: 7)
                            Text(connectionStatusLine(state) ?? "Module Online")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.green)
                        }
                        Text(standbyNetworkLine(state))
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.62))
                            .lineLimit(1)
                    } else if state.phase == .cloudStandby {
                        HStack(spacing: 5) {
                            Circle().fill(Color.cyan).frame(width: 7, height: 7)
                            Text("Cloud Online")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.cyan)
                        }
                        Text("Internet Relay Connected · Ready for Calls and Messages")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.62))
                            .lineLimit(1)
                    } else {
                        Text(activityStatusLine(state))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(tint(for: state.phase))
                    }
                }
                Spacer(minLength: 8)
                lockScreenMetric(state)
            }

            if hasAgentMetadata(state) {
                agentSummaryRow(state)
            }

            if state.phase != .standby && state.phase != .cloudStandby && state.phase != .offline {
                actionButtons(state)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        // ActivityKit already provides a system Live Activity container on the lock screen. Adding glassEffect
        // to the root content on iOS 26 creates a second sampling layer that can render as an empty glass shell on device.
        // A clear activityBackgroundTint enables host Liquid Glass while the body keeps standard layout.
    }

    @ViewBuilder
    private func lockScreenMetric(
        _ state: AirSIMCallActivityAttributes.ContentState
    ) -> some View {
        if state.phase == .active {
            Text(state.startedAt, style: .timer)
                .font(.title3.weight(.semibold).monospacedDigit())
        } else if state.phase == .standby {
            VStack(alignment: .trailing, spacing: 2) {
                signalBars(dbm: state.signalDBM)
                if let signal = state.signalDBM {
                    Text("\(signal) dBm")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.62))
                }
            }
        } else if state.phase == .cloudStandby {
            Image(systemName: "checkmark.icloud.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.cyan)
        } else if state.phase == .incoming {
            Image(systemName: "waveform")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.green)
        } else if state.phase == .offline {
            Text("Offline")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    @ViewBuilder
    private func expandedBottomView(
        _ state: AirSIMCallActivityAttributes.ContentState
    ) -> some View {
        switch state.phase {
        case .standby:
            expandedAgentDetail(state)
        case .cloudStandby:
            expandedAgentDetail(state)
        case .offline:
            expandedAgentDetail(state)
        case .incoming, .active, .held:
            actionButtons(state)
        }
    }

    /// Device name and connection status are already shown at the top of the expanded presentation; keep only a single
    /// supplementary line at the bottom to avoid duplicating cards and clipping the last line within Dynamic Island height limits.
    private func expandedAgentDetail(
        _ state: AirSIMCallActivityAttributes.ContentState
    ) -> some View {
        HStack(spacing: 6) {
            if let number = nonEmpty(state.agentPhoneNumber) {
                Text("SIM \(number)")
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            } else if state.phase == .offline {
                Label("Waiting for Android Agent to Reconnect", systemImage: "wifi.exclamationmark")
                    .lineLimit(1)
            } else {
                Text(standbyNetworkLine(state))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Text(agentKindTitle(state.agentKind))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.white.opacity(0.82))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .modifier(ProgressiveIslandGlassSurface())
    }

    private func pairedAgentCountView(
        _ state: AirSIMCallActivityAttributes.ContentState
    ) -> some View {
        Group {
            if let count = state.pairedAgentCount, count > 1 {
                Text("\(count) devices")
            } else {
                Image(systemName: state.phase == .cloudStandby ? "icloud.fill" : "smartphone")
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint(for: state.phase))
    }

    private func agentSummaryRow(
        _ state: AirSIMCallActivityAttributes.ContentState
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "smartphone")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
                .frame(width: 24, height: 24)
                .background(Color.green.opacity(0.16), in: Circle())

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(nonEmpty(state.agentDeviceName) ?? "Android Agent")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    if let count = state.pairedAgentCount, count > 1 {
                        Text("Total: \(count) devices")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.white.opacity(0.52))
                    }
                }
                Text(agentDetailLine(state))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Spacer(minLength: 4)
            connectionBadges(state)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
        }
    }

    private func connectionBadges(
        _ state: AirSIMCallActivityAttributes.ContentState
    ) -> some View {
        HStack(spacing: 5) {
            if vowlanIsOnline(state) {
                connectionBadge("VoWLAN", systemImage: "wifi", color: .green)
            }
            if cloudIsOnline(state) {
                connectionBadge("Cloud", systemImage: "icloud.fill", color: .cyan)
            }
        }
    }

    private func connectionBadge(
        _ title: String,
        systemImage: String,
        color: Color
    ) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(color.opacity(0.15), in: Capsule())
            .labelStyle(.titleAndIcon)
    }

    @ViewBuilder
    private func actionButtons(_ state: AirSIMCallActivityAttributes.ContentState) -> some View {
        switch state.phase {
        case .incoming:
            HStack(spacing: 8) {
                Text("Incoming Call")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                HStack(spacing: IslandActionLayout.buttonSpacing) {
                    callActionButton(RejectAirSIMCallIntent(callID: state.callID), icon: "phone.down.fill",
                                   title: "Decline Call", prominent: false, tint: Color.white.opacity(0.17))
                    callActionButton(AnswerAirSIMCallIntent(callID: state.callID), icon: "phone.fill",
                                   title: "Answer Call", prominent: true, tint: .green)
                }
                .frame(width: IslandActionLayout.reservedWidth(for: state.phase), alignment: .trailing)
            }
        case .active, .held:
            HStack(spacing: 8) {
                Image(systemName: state.phase == .held ? "pause.fill" : "waveform")
                    .foregroundStyle(tint(for: state.phase))
                Text(state.phase == .held ? "Call on Hold" : "On Call")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                callActionButton(HangUpAirSIMCallIntent(callID: state.callID), icon: "phone.down.fill",
                               title: "End Call", prominent: true, tint: .red)
                    .frame(width: IslandActionLayout.reservedWidth(for: state.phase), alignment: .trailing)
            }
        case .standby, .cloudStandby, .offline:
            EmptyView()
        }
    }

    private func callActionButton<Intent: AppIntent>(_ intent: Intent,
                                icon: String, title: String, prominent: Bool, tint: Color) -> some View {
        Button(intent: intent) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .frame(width: IslandActionLayout.buttonSide, height: IslandActionLayout.buttonSide)
        }
        .accessibilityLabel(title)
        .modifier(LiveActivityGlassButtonStyle(prominent: prominent, tint: tint))
    }

    @ViewBuilder
    private func compactTrailingView(
        _ state: AirSIMCallActivityAttributes.ContentState
    ) -> some View {
        switch state.phase {
        case .active:
            Text(state.startedAt, style: .timer)
                .font(.caption2.monospacedDigit())
                .frame(width: 42)
        case .incoming:
            Text("Incoming Call")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.green)
        case .standby:
            Image(systemName: "cellularbars")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
        case .cloudStandby:
            Image(systemName: "checkmark.icloud.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.cyan)
        case .held:
            Image(systemName: "pause.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        case .offline:
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func signalBars(dbm: Int?) -> some View {
        let strength: Int
        let measured = dbm ?? -120
        if measured >= -79 {
            strength = 4
        } else if measured >= -89 {
            strength = 3
        } else if measured >= -99 {
            strength = 2
        } else if measured >= -109 {
            strength = 1
        } else {
            strength = 0
        }
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4, id: \.self) { index in
                Capsule()
                    .fill(index < strength ? Color.green : Color.white.opacity(0.2))
                    .frame(width: 3, height: CGFloat(4 + index * 3))
            }
        }
        .frame(height: 14)
        .accessibilityLabel(dbm.map { "Signal \($0) dBm" } ?? "Signal Unknown")
    }

    private func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func hasAgentMetadata(
        _ state: AirSIMCallActivityAttributes.ContentState
    ) -> Bool {
        nonEmpty(state.agentDeviceName) != nil
            || nonEmpty(state.agentPhoneNumber) != nil
            || (state.pairedAgentCount ?? 0) > 0
    }

    private func agentDetailLine(
        _ state: AirSIMCallActivityAttributes.ContentState
    ) -> String {
        var parts: [String] = []
        if let number = nonEmpty(state.agentPhoneNumber) {
            parts.append("SIM \(number)")
        }
        parts.append(agentKindTitle(state.agentKind))
        return parts.joined(separator: " · ")
    }

    private func agentKindTitle(_ kind: String?) -> String {
        switch kind {
        case "standalone": return "Standalone"
        case "avf": return "Retired Android Agent"
        default: return "Android Agent"
        }
    }

    private func vowlanIsOnline(
        _ state: AirSIMCallActivityAttributes.ContentState
    ) -> Bool {
        state.vowlanOnline == true || state.transport == .vowlan
    }

    private func cloudIsOnline(
        _ state: AirSIMCallActivityAttributes.ContentState
    ) -> Bool {
        state.cloudOnline == true || state.transport == .cloud
    }

    private func connectionStatusLine(
        _ state: AirSIMCallActivityAttributes.ContentState
    ) -> String? {
        var values: [String] = []
        if vowlanIsOnline(state) { values.append("VoWLAN Online") }
        if cloudIsOnline(state) { values.append("Cloud Online") }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    private func standbyNetworkLine(
        _ state: AirSIMCallActivityAttributes.ContentState
    ) -> String {
        var parts: [String] = []
        if let mode = state.networkMode, !mode.isEmpty { parts.append(mode) }
        if let band = state.radioBand, !band.isEmpty { parts.append(band) }
        return parts.isEmpty ? "Reading Cellular Status" : parts.joined(separator: " · ")
    }

    private func standbyCarrierName(
        _ state: AirSIMCallActivityAttributes.ContentState
    ) -> String {
        nonEmpty(state.operatorName) ?? "Cellular Network"
    }

    private func idleTitle(
        _ state: AirSIMCallActivityAttributes.ContentState
    ) -> String {
        switch state.phase {
        case .standby:
            return nonEmpty(state.agentDeviceName) ?? standbyCarrierName(state)
        case .cloudStandby:
            return nonEmpty(state.agentDeviceName) ?? "Cloud Online"
        case .incoming, .active, .held, .offline:
            return state.displayName
        }
    }

    private func activityBackgroundTint(
        for state: AirSIMCallActivityAttributes.ContentState
    ) -> Color {
        if #available(iOSApplicationExtension 26.0, *) {
            // Let the lock-screen wallpaper serve as the sampling backdrop for system Liquid Glass across all phases.
            return .clear
        }
        return Color(red: 0.012, green: 0.028, blue: 0.065)
    }

    private func statusMark(
        for phase: AirSIMCallActivityAttributes.ContentState.Phase,
        size: CGFloat
    ) -> some View {
        Image(systemName: symbolName(for: phase))
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(tint(for: phase))
            .frame(width: size, height: size)
            .background(tint(for: phase).opacity(0.2), in: Circle())
    }

    private func callerMark(size: CGFloat) -> some View {
        Image(systemName: "person.fill")
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white.opacity(0.9))
            .frame(width: size, height: size)
            .background(Color.white.opacity(0.18), in: Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
            .accessibilityHidden(true)
    }

    private func symbolName(
        for phase: AirSIMCallActivityAttributes.ContentState.Phase
    ) -> String {
        switch phase {
        case .standby: return "antenna.radiowaves.left.and.right"
        case .cloudStandby: return "icloud.fill"
        case .incoming: return "phone.arrow.down.left.fill"
        case .active: return "waveform"
        case .held: return "pause.fill"
        case .offline: return "antenna.radiowaves.left.and.right.slash"
        }
    }

    private func compactSymbolName(
        for state: AirSIMCallActivityAttributes.ContentState
    ) -> String {
        if state.transport == .vowlan,
           state.phase != .offline,
           state.phase != .cloudStandby {
            return state.transport?.systemImage ?? "wifi"
        }
        return symbolName(for: state.phase)
    }

    private func activityStatusLine(
        _ state: AirSIMCallActivityAttributes.ContentState
    ) -> String {
        switch state.phase {
        case .incoming, .active, .held:
            guard let transport = state.transport else { return state.phase.title }
            return "\(state.phase.title) · \(transport.title)"
        case .standby:
            if let status = connectionStatusLine(state) { return status }
            if let transport = state.transport { return "\(transport.title) Online" }
            return state.phase.title
        case .cloudStandby:
            return connectionStatusLine(state) ?? state.phase.title
        case .offline:
            return state.phase.title
        }
    }

    private func tint(
        for phase: AirSIMCallActivityAttributes.ContentState.Phase
    ) -> Color {
        switch phase {
        case .incoming, .active, .standby: return .green
        case .cloudStandby: return .cyan
        case .held: return .orange
        case .offline: return .secondary
        }
    }

}

private struct LiveActivityGlassButtonStyle: ViewModifier {
    let prominent: Bool
    let tint: Color

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOSApplicationExtension 26.0, *) {
            if prominent {
                content.buttonStyle(.glassProminent).tint(tint).buttonBorderShape(.circle)
            } else {
                content.buttonStyle(.glass).tint(tint).buttonBorderShape(.circle)
            }
        } else {
            content.buttonStyle(.borderedProminent).tint(tint)
        }
    }
}

/// The Dynamic Island shell is drawn opaquely by the system; gradients apply only to the native glass info bar inside the island.
private struct ProgressiveIslandGlassSurface: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOSApplicationExtension 26.0, *) {
            content.background {
                Color.clear
                    .glassEffect(.regular.tint(.white.opacity(0.12)),
                                 in: .rect(cornerRadius: 14))
                    .mask {
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .white.opacity(0.45), location: 0.42),
                                .init(color: .white, location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.clear, .white.opacity(0.16)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.5
                    )
            }
        } else {
            content
                .background(.ultraThinMaterial,
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}
