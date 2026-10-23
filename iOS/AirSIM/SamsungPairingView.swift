import SwiftUI

struct SamsungPairingView: View {
    @Environment(AppModel.self) private var model
    @State private var localPairingOnly = LocalModePreference.isEnabled()
    @State private var browser = SamsungPairingBrowser()
    @State private var code = ""
    @State private var pairingServiceID: String?
    @State private var message = ""

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $localPairingOnly) {
                    Label("Local-Only Pairing", systemImage: "wifi")
                }
                .disabled(pairingServiceID != nil)
                .accessibilityIdentifier("localPairingOnly")
                Text(localPairingOnly
                     ? "This pairing saves only the VoWLAN key, without checking or saving Relay and push settings. Your connection mode stays unchanged."
                     : "This pairing saves the VoWLAN key and Relay/push configuration. Cloud credentials must be ready. Your connection mode stays unchanged.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Connection Steps") {
                Label("Connect both devices to the same Wi-Fi", systemImage: "wifi")
                Label("Or connect this device to the Android hotspot", systemImage: "personalhotspot")
                Label("Tap Start One-Time Pairing in the Android app", systemImage: "key")
            }

            Section("Discovered Devices") {
                if browser.services.isEmpty {
                    HStack {
                        ProgressView()
                        Text(browser.stateText).foregroundStyle(.secondary)
                    }
                }
                ForEach(browser.services) { service in
                    VStack(alignment: .leading, spacing: 10) {
                        Label(service.displayName, systemImage: "iphone.radiowaves.left.and.right")
                            .font(.headline)
                        TextField("Six-digit code shown on Android", text: $code)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                            .onChange(of: code) { _, value in
                                code = String(value.filter(\.isNumber).prefix(6))
                            }
                        Button("Pair Securely", systemImage: "lock.shield") {
                            Task { await pair(service) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(code.count != 6 || pairingServiceID != nil)
                    }
                    .padding(.vertical, 4)
                }
            }

            if !message.isEmpty {
                Section("Result") { Text(message) }
            }
        }
        .navigationTitle("Pair Android Phone")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
    }

    @MainActor
    private func pair(_ service: SamsungPairingService) async {
        pairingServiceID = service.id
        message = localPairingOnly
            ? "Encrypting and saving the local VoWLAN key…"
            : "Encrypting and saving to the Android Agent…"
#if DEBUG
        print("[AirSIM Pair] claim_started session=\(service.sessionID)")
#endif
        defer { pairingServiceID = nil }
        do {
            message = try await VoIPPushController.shared.performAndroidPairing(
                localOnly: localPairingOnly
            ) { registration in
                try await SamsungPairingCompletionCoordinator.complete(
                performPairing: {
                    try await SamsungPairingClient.pair(
                        service: service,
                        code: code,
                        registration: registration
                    )
                },
                refreshVoWLAN: {
                    await model.vowlan.refreshAfterPairing()
                }
                )
            }
#if DEBUG
            print("[AirSIM Pair] claim_completed session=\(service.sessionID)")
#endif
        } catch {
            message = "Pairing failed: \(error.localizedDescription)"
#if DEBUG
            print("[AirSIM Pair] claim_failed session=\(service.sessionID) error=\(String(describing: type(of: error)))")
#endif
        }
    }
}

#Preview("Samsung Pairing") {
    NavigationStack {
        SamsungPairingView()
            .environment(AppModel())
    }
}
