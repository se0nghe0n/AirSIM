import SwiftUI

/// AirSIM 只引导三星配对；不检查旧模块 USB ECM、AT 或 QDC507 固件。
struct AirSIMFirstConnectionView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("airsim.first-connection-complete") private var completed = false
    @AppStorage(ConnectionModePreference.key) private var connectionModeRaw = ConnectionModePreference.selected().rawValue
    @State private var showingPairing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Image(systemName: "iphone.radiowaves.left.and.right")
                        .font(.system(size: 42, weight: .medium))
                        .foregroundStyle(.blue)
                        .frame(width: 76, height: 76)
                        .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 22))

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Connect Android Phone")
                            .font(.largeTitle.bold())
                            .fixedSize(horizontal: false, vertical: true)
                        Text("AirSIM connects to your Android phone over VoWLAN or a cloud Relay.")
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 18) {
                        Label("Start AirSIM and the audio bridge on Android", systemImage: "1.circle.fill")
                        Label("Set up the same Wi-Fi or Android hotspot, or configure cloud Relay", systemImage: "2.circle.fill")
                        Label("Verify the security code and finish pairing", systemImage: "3.circle.fill")
                    }
                    .font(.body.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))

                    Picker("Connection Mode", selection: $connectionModeRaw) {
                        ForEach(AirSIMConnectionMode.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: connectionModeRaw) { _, rawValue in
                        guard let mode = AirSIMConnectionMode(rawValue: rawValue) else { return }
                        model.setConnectionMode(mode)
                    }
                    Text(selectedMode.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                }
                .frame(maxWidth: 600, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 16) {
                    Button("Start Pairing", systemImage: "lock.shield") {
                        showingPairing = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)

                    Button("Pair Later in Settings") { completed = true }
                        .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: 600)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
            .navigationTitle("AirSIM")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingPairing, onDismiss: {
                if model.vowlan.availability.isOnlineForDisplay { completed = true }
            }) {
                NavigationStack {
                    SamsungPairingView()
                        .environment(model)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showingPairing = false }
                            }
                        }
                }
            }
        }
    }

    private var selectedMode: AirSIMConnectionMode {
        AirSIMConnectionMode(rawValue: connectionModeRaw) ?? .automatic
    }
}

#Preview("Paired Devices · Empty") {
    Form { Section("Android Connection") { PairedAndroidDeviceRows(devices: [], onDelete: { _ in }) } }
}

#Preview("Paired Devices · Online and Offline") {
    Form {
        Section("Android Connection") {
            PairedAndroidDeviceRows(devices: [
                .init(id: "preview-flip", deviceName: "Samsung Flip7", phoneNumber: "+10000000001",
                      agentKind: "standalone", cloudOnline: false, vowlanOnline: false,
                      bluetoothOnline: true, isCurrent: true),
                .init(id: "preview-vivo", deviceName: "vivo X60", phoneNumber: nil,
                      agentKind: "standalone", cloudOnline: false, vowlanOnline: false, isCurrent: false)
            ], onDelete: { _ in })
        }
    }
}

private struct PairedAndroidDeviceRows: View {
    let devices: [AndroidAgentPresentation]
    let onDelete: (AndroidAgentPresentation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paired Devices").font(.subheadline.weight(.semibold))
            if devices.isEmpty {
                Text("No paired devices").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(devices) { device in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(device.deviceName).font(.subheadline.weight(.medium))
                        Text(device.phoneNumber ?? "Number unavailable").font(.caption).foregroundStyle(.secondary)
                        Text(connectionText(device)).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button(role: .destructive) { onDelete(device) } label: {
                        Image(systemName: "trash").padding(10)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Delete \(device.deviceName) pairing record")
                }
            }
            Text("Current information is refreshed on reconnection. Offline records do not store phone numbers.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func connectionText(_ device: AndroidAgentPresentation) -> String {
        let routes = [device.vowlanOnline ? "VoWLAN Online" : nil,
                      device.cloudOnline ? "Cloud Online" : nil].compactMap { $0 }
        return routes.isEmpty ? "Offline · Refreshes on reconnection" : routes.joined(separator: " · ")
    }
}

/// 自检进度阶段。原先嵌在 AirSIMSettingsView 内；抽成独立分区视图后移到文件级。
private enum SelfTestPhase {
    case idle
    case running
    case completed
}

struct AirSIMSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @AppStorage(ConnectionModePreference.key) private var connectionModeRaw = ConnectionModePreference.selected().rawValue
    @AppStorage(LiveActivityVisibilityPreference.key) private var liveActivityEnabled = true
    @State private var relayURL = RelayConfiguration.effectiveURL(
        stored: UserDefaults.standard.string(forKey: "airsim.push-relay-url"),
        buildSetting: Bundle.main.object(forInfoDictionaryKey: "AirSIMPushRelayURL") as? String,
        bundleID: Bundle.main.bundleIdentifier
    )
    @State private var message: String?
    @State private var selfTestPhase: SelfTestPhase = .idle
    @State private var selfTestReport: CloudSelfTestReport?
    @State private var selfTestTask: Task<Void, Never>?
    @State private var deletingDevice: AndroidAgentPresentation?
    @State private var deviceDeletionInProgress = false

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section {
                    Picker("Connection Mode", selection: $connectionModeRaw) {
                        ForEach(AirSIMConnectionMode.allCases) { mode in
                            Label(mode.title, systemImage: modeIcon(mode)).tag(mode.rawValue)
                        }
                    }
                    .onChange(of: connectionModeRaw) { _, rawValue in
                        guard let mode = AirSIMConnectionMode(rawValue: rawValue) else { return }
                        selfTestTask?.cancel()
                        selfTestPhase = .idle
                        selfTestReport = nil
                        model.setConnectionMode(mode)
                    }
                } header: {
                    Text("Connection Mode")
                } footer: {
                    Text(selectedMode.detail)
                }

                CurrentConnectionSection(cloudModeEnabled: runtimePolicy.startsCloud)

                Section("Android Connection") {
                    LabeledContent("VoWLAN", value: VoWLANStatusCopy.text(for: model.vowlan.availability))
                    NavigationLink {
                        SamsungPairingView()
                    } label: {
                        Label("Pair Android Phone", systemImage: "personalhotspot")
                    }
                    PairedAndroidDeviceRows(devices: model.pairedDeviceHistory, onDelete: { deletingDevice = $0 })
                        .disabled(deviceDeletionInProgress)
                    Button("Discover Again", systemImage: "arrow.clockwise") {
                        model.vowlan.restartBrowsing()
                        Task { await model.vowlan.probeNow() }
                    }
                }

                Section {
                    Toggle(isOn: $liveActivityEnabled) {
                        Label("Show Dynamic Island", systemImage: "platter.filled.top.iphone")
                    }
                    .onChange(of: liveActivityEnabled) { _, enabled in
                        model.setLiveActivityEnabled(enabled)
                    }
                } header: {
                    Text("Dynamic Island and Live Activities")
                } footer: {
                    Text("Turning this off ends AirSIM Dynamic Island and Lock Screen Live Activities. Calls and messages remain available.")
                }

                Section {
                    LabeledContent("Remote Calls and Messages", value: runtimePolicy.startsCloud ? "Enabled" : "Disabled")

                    TextField("https://relay.example.com", text: $relayURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(!runtimePolicy.startsCloud)
                    Button("Save Relay URL") {
                        VoIPPushController.shared.updateRelayURL(relayURL)
                        selfTestTask?.cancel()
                        selfTestPhase = .idle
                        selfTestReport = nil
                        Task {
                            if let (api, _) = await model.readyVoWLANRoute() {
                                await VoIPPushController.shared.syncRegistration(with: api)
                            }
                            await model.refreshCloudStatusForDiagnostics()
                        }
                        message = "URL saved. Registration will complete automatically after pairing."
                    }
                    .disabled(!runtimePolicy.startsCloud)
                    if let message { Text(message).foregroundStyle(.secondary) }
                } header: {
                    Text("Cloud Relay")
                } footer: {
                    Text("Local VoWLAN remains available when cloud mode is off. Remote calls and messages require a cloud Relay and valid device registration.")
                }

                CloudSelfTestSection(
                    isEnabled: runtimePolicy.startsCloud,
                    phase: selfTestPhase,
                    report: selfTestReport,
                    onStart: startCloudSelfTest
                )

                Section("About") {
                    LabeledContent("Project", value: "AirSIM · Samsung")
                    Picker("Appearance", selection: $settings.appearance) {
                        ForEach(AppAppearance.allCases) { appearance in
                            Text(appearance.title).tag(appearance)
                        }
                    }
                }
            }
            .task { await model.refreshPairedDeviceInformation() }
            .deletePairedDeviceConfirmation(item: $deletingDevice) { device in
                deviceDeletionInProgress = true
                Task {
                    defer { deviceDeletionInProgress = false }
                    do { try await model.forgetAndroidDevice(device.id) }
                    catch { message = error.localizedDescription }
                }
            }
            .navigationTitle("Settings")
            .onDisappear {
                selfTestTask?.cancel()
                selfTestTask = nil
                if selfTestPhase == .running { selfTestPhase = .idle }
            }
        }
    }

    private func startCloudSelfTest() {
        selfTestTask?.cancel()
        selfTestPhase = .running
        selfTestReport = .initial
        selfTestTask = Task { @MainActor in
            let report = await VoIPPushController.shared.runCloudSelfTest { update in
                guard !Task.isCancelled else { return }
                selfTestReport = update
            }
            guard !Task.isCancelled else { return }
            selfTestReport = report
            selfTestPhase = .completed
            await model.refreshCloudStatusForDiagnostics()
        }
    }

    private var selectedMode: AirSIMConnectionMode {
        AirSIMConnectionMode(rawValue: connectionModeRaw) ?? .automatic
    }

    private var runtimePolicy: ConnectionModeRuntimePolicy {
        ConnectionModeRuntimePolicy(mode: selectedMode)
    }

    private func modeIcon(_ mode: AirSIMConnectionMode) -> String {
        switch mode {
        case .vowlan: return "wifi"
        case .cloud: return "cloud"
        case .automatic: return "arrow.triangle.branch"
        }
    }
}

/// 当前连接分区独立成子视图：可用性与心跳等模型读取移入子视图 body，
/// 这些变化不再触发整个设置表单重算（structure.md 失效边界）。
private struct CurrentConnectionSection: View {
    @Environment(AppModel.self) private var model
    let cloudModeEnabled: Bool

    var body: some View {
        Section("Current Connection") {
            LabeledContent("Current Mode", value: model.connectionModePresentation.title)
            LabeledContent("Connection Status", value: model.connectionModePresentation.status)
            LabeledContent("VoWLAN", value: VoWLANStatusCopy.text(for: model.vowlan.availability))
            LabeledContent(
                "Cloud Relay",
                value: cloudModeEnabled
                    ? (model.cloudAgentStatus?.cloudOnline == true ? "Agent Online" : "Unreachable")
                    : "Disabled in current mode"
            )
            Text(model.connectionModePresentation.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let connectionMessage = model.connectionMessage, !connectionMessage.isEmpty {
                Text(connectionMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// 云端自检分区独立成子视图：自检报告流式更新时，其余设置分区不再重算
/// （structure.md 失效边界）。
private struct CloudSelfTestSection: View {
    let isEnabled: Bool
    let phase: SelfTestPhase
    let report: CloudSelfTestReport?
    let onStart: () -> Void

    var body: some View {
        Section {
            Button {
                onStart()
            } label: {
                HStack {
                    Label("Run Cloud Self-Test", systemImage: "stethoscope")
                    Spacer()
                    if phase == .running {
                        ProgressView()
                    }
                }
            }
            .disabled(!isEnabled || phase == .running)

            if let report {
                ForEach(report.steps) { step in
                    CloudSelfTestStepRow(step: step)
                }
                if phase == .completed {
                    Text(report.allPassed ? "Cloud self-test passed" : "Self-test failed. Resolve the failed steps and try again.")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(report.allPassed ? .green : .orange)
                }
            }
        } header: {
            Text("Cloud Self-Test")
        } footer: {
            Text(!isEnabled
                ? "Cloud self-test is unavailable in the current connection mode."
                : "Checks local push credentials, AirSIM Relay identity, device registration, and an Agent heartbeat within the last 90 seconds. No calls or messages are sent.")
        }
    }
}

private struct CloudSelfTestStepRow: View {
    let step: CloudSelfTestStep

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: Self.symbol(for: step.state))
                .foregroundStyle(Self.color(for: step.state))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(step.title)
                Text(step.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static func symbol(for state: CloudSelfTestStepState) -> String {
        switch state {
        case .pending: return "circle"
        case .running: return "arrow.triangle.2.circlepath"
        case .passed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    private static func color(for state: CloudSelfTestStepState) -> Color {
        switch state {
        case .pending: return .secondary
        case .running: return .blue
        case .passed: return .green
        case .failed: return .red
        }
    }
}

/// swiftui-whats-new-27 item-binding.md：iOS 27 为 confirmationDialog 增加 item:
/// 重载，单一可选值同时驱动呈现并传给按钮；部署目标是 iOS 17，因此按参考的
/// ViewModifier 分流形式采用，旧系统分支保持原 isPresented + presenting 行为。
private struct DeletePairedDeviceConfirmation: ViewModifier {
    @Binding var item: AndroidAgentPresentation?
    let onConfirm: (AndroidAgentPresentation) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 27, *) {
            content.confirmationDialog(
                "Delete this device's local pairing record?",
                item: $item,
                titleVisibility: .visible
            ) { device in
                deleteActions(for: device)
            } message: { _ in
                deleteMessage
            }
        } else {
            content.confirmationDialog(
                "Delete this device's local pairing record?",
                isPresented: Binding(
                    get: { item != nil },
                    set: { if !$0 { item = nil } }
                ),
                titleVisibility: .visible,
                presenting: item
            ) { device in
                deleteActions(for: device)
            } message: { _ in
                deleteMessage
            }
        }
    }

    @ViewBuilder
    private func deleteActions(for device: AndroidAgentPresentation) -> some View {
        Button("Delete \(device.deviceName)", role: .destructive) {
            onConfirm(device)
        }
        Button("Cancel", role: .cancel) {}
    }

    private var deleteMessage: some View {
        Text("Clears this device's local record, binding, and cache. Calls, messages, and other devices are unaffected. Pair again to enable automatic connection. Remote credentials on an offline device are not automatically revoked.")
    }
}

private extension View {
    func deletePairedDeviceConfirmation(
        item: Binding<AndroidAgentPresentation?>,
        onConfirm: @escaping (AndroidAgentPresentation) -> Void
    ) -> some View {
        modifier(DeletePairedDeviceConfirmation(item: item, onConfirm: onConfirm))
    }
}
