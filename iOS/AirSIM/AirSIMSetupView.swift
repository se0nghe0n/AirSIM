import SwiftUI

/// AirSIM 只引导三星配对；不检查旧模块 USB ECM、AT 或 QDC507 固件。
struct AirSIMFirstConnectionView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("airsim.first-connection-complete") private var completed = false
    @AppStorage(ConnectionModePreference.key) private var connectionModeRaw = ConnectionModePreference.selected().rawValue
    @State private var showingPairing = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.system(size: 42, weight: .medium))
                    .foregroundStyle(.blue)
                    .frame(width: 76, height: 76)
                    .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 22))

                VStack(alignment: .leading, spacing: 8) {
                    Text("Connect Android Phone")
                        .font(.largeTitle.bold())
                    Text("AirSIM connects to your Android phone over VoWLAN, Bluetooth, or a cloud Relay.")
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 18) {
                    Label("Start AirSIM and the audio bridge on Android", systemImage: "1.circle.fill")
                    Label(selectedMode == .bluetooth ? "Turn on Bluetooth on both devices" : "Set up the network or Bluetooth for your selected mode", systemImage: "2.circle.fill")
                    Label("Verify the security code and finish pairing", systemImage: "3.circle.fill")
                }
                .font(.body.weight(.medium))
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))

                Picker("Connection Mode", selection: $connectionModeRaw) {
                    ForEach(AirSIMConnectionMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: connectionModeRaw) { rawValue in
                    guard let mode = AirSIMConnectionMode(rawValue: rawValue) else { return }
                    model.setConnectionMode(mode)
                }
                Text(selectedMode.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Start Pairing", systemImage: "lock.shield") {
                    showingPairing = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)

                Button("Pair Later in Settings") { completed = true }
                    .frame(maxWidth: .infinity)
            }
            .padding(24)
            .navigationTitle("AirSIM")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingPairing, onDismiss: {
                if model.vowlan.availability.isOnlineForDisplay || model.voble.state == .ready { completed = true }
            }) {
                NavigationStack {
                    Group {
                        if selectedMode == .bluetooth {
                            VoBLEPairingView()
                        } else {
                            SamsungPairingView()
                        }
                    }
                        .environmentObject(model)
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
                      device.bluetoothOnline ? "VoBLE Online" : nil,
                      device.cloudOnline ? "Cloud Online" : nil].compactMap { $0 }
        return routes.isEmpty ? "Offline · Refreshes on reconnection" : routes.joined(separator: " · ")
    }
}

struct AirSIMSettingsView: View {
    private enum SelfTestPhase {
        case idle
        case running
        case completed
    }

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
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
        NavigationStack {
            Form {
                Section {
                    Picker("Connection Mode", selection: $connectionModeRaw) {
                        ForEach(AirSIMConnectionMode.allCases) { mode in
                            Label(mode.title, systemImage: modeIcon(mode)).tag(mode.rawValue)
                        }
                    }
                    .onChange(of: connectionModeRaw) { rawValue in
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

                Section("Current Connection") {
                    LabeledContent("Current Mode", value: model.connectionModePresentation.title)
                    LabeledContent("Connection Status", value: model.connectionModePresentation.status)
                    LabeledContent("VoWLAN", value: VoWLANStatusCopy.text(for: model.vowlan.availability))
                    LabeledContent(
                        "Cloud Relay",
                        value: runtimePolicy.startsCloud
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

                Section("Bluetooth Connection") {
                    LabeledContent("VoBLE", value: voBLEStatus)
                    NavigationLink {
                        VoBLEPairingView()
                    } label: {
                        Label("Pair Bluetooth Agent", systemImage: "wave.3.right")
                    }
                    Button("Scan for Bluetooth Agents Again", systemImage: "arrow.clockwise") {
                        model.voble.stop()
                        model.voble.start()
                    }
                    .disabled(!runtimePolicy.startsBluetooth)
                }

                if runtimePolicy.startsBluetooth {
                    Section("Bluetooth Diagnostics (Redacted)") {
                        let diagnostics = model.vobleDiagnostics
                        LabeledContent("Authentication", value: diagnostics.peerAuthenticated ? "Passed" : "Incomplete")
                        LabeledContent("PCM", value: diagnostics.pcmReady ? "Running" : "Not Started")
                        LabeledContent("Codec", value: diagnostics.codec)
                        LabeledContent("Send Queue", value: "\(diagnostics.queuedFrames) / 8 frames")
                        LabeledContent("Dropped Frames", value: "\(diagnostics.droppedFrames)")
                        LabeledContent("Jitter Buffer", value: "\(diagnostics.jitterFrames) frames")
                        LabeledContent("Last Error", value: diagnostics.lastError.rawValue)
                        Text("Diagnostics exclude phone numbers, keys, nonces, authentication tags, and audio content.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Toggle(isOn: $liveActivityEnabled) {
                        Label("Show Dynamic Island", systemImage: "platter.filled.top.iphone")
                    }
                    .onChange(of: liveActivityEnabled) { enabled in
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

                Section {
                    Button {
                        startCloudSelfTest()
                    } label: {
                        HStack {
                            Label("Run Cloud Self-Test", systemImage: "stethoscope")
                            Spacer()
                            if selfTestPhase == .running {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(!runtimePolicy.startsCloud || selfTestPhase == .running)

                    if let report = selfTestReport {
                        ForEach(report.steps) { step in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: selfTestSymbol(for: step.state))
                                    .foregroundStyle(selfTestColor(for: step.state))
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(step.title)
                                    Text(step.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        if selfTestPhase == .completed {
                            Text(report.allPassed ? "Cloud self-test passed" : "Self-test failed. Resolve the failed steps and try again.")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(report.allPassed ? .green : .orange)
                        }
                    }
                } header: {
                    Text("Cloud Self-Test")
                } footer: {
                    Text(!runtimePolicy.startsCloud
                        ? "Cloud self-test is unavailable in the current connection mode."
                        : "Checks local push credentials, AirSIM Relay identity, device registration, and an Agent heartbeat within the last 90 seconds. No calls or messages are sent.")
                }

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
            .confirmationDialog("Delete this device's local pairing record?",
                isPresented: Binding(get: { deletingDevice != nil }, set: { if !$0 { deletingDevice = nil } }),
                titleVisibility: .visible, presenting: deletingDevice) { device in
                Button("Delete \(device.deviceName)", role: .destructive) {
                    deviceDeletionInProgress = true
                    Task {
                        defer { deviceDeletionInProgress = false }
                        do { try await model.forgetAndroidDevice(device.id) }
                        catch { message = error.localizedDescription }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Clears this device's local record, binding, and cache. Calls, messages, and other devices are unaffected. Pair again to enable automatic connection. Remote credentials on an offline device are not automatically revoked.")
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

    private var voBLEStatus: String {
        switch model.voble.state {
        case .stopped: return runtimePolicy.startsBluetooth ? "Not Started" : "Disabled in current mode"
        case .bluetoothUnavailable: return "Bluetooth Unavailable"
        case .scanning: return "Discovering"
        case .connecting, .connected: return "Connecting"
        case .authenticating: return "Authenticating"
        case .ready: return "Authenticated"
        case .failed(let message): return "Failed: \(message)"
        }
    }

    private func modeIcon(_ mode: AirSIMConnectionMode) -> String {
        switch mode {
        case .vowlan: return "wifi"
        case .bluetooth: return "wave.3.right"
        case .cloud: return "cloud"
        case .automatic: return "arrow.triangle.branch"
        }
    }

    private func selfTestSymbol(for state: CloudSelfTestStepState) -> String {
        switch state {
        case .pending: return "circle"
        case .running: return "arrow.triangle.2.circlepath"
        case .passed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    private func selfTestColor(for state: CloudSelfTestStepState) -> Color {
        switch state {
        case .pending: return .secondary
        case .running: return .blue
        case .passed: return .green
        case .failed: return .red
        }
    }
}
