import SwiftUI

struct VoBLEPairingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingUnpairConfirmation = false
    @State private var unpairing = false

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: stateSymbol)
                        .font(.title2)
                        .foregroundStyle(stateColor)
                        .frame(width: 42, height: 42)
                        .background(stateColor.opacity(0.12), in: Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text(stateTitle).font(.headline)
                        Text(stateDetail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)

                if let identity = model.voble.authenticatedIdentity {
                    LabeledContent("Authenticated Agent", value: identity)
                }
                if let message = model.voble.errorMessage, !message.isEmpty {
                    Text(message).font(.footnote).foregroundStyle(.red)
                }
            } header: {
                Text("Bluetooth Connection")
            } footer: {
                Text("Bluetooth works independently of VoWLAN and cloud Relay. Call control and audio become available after authentication.")
            }

            if let sas = model.voble.pendingSAS {
                Section("Verify Security Code") {
                    Text(sas)
                        .font(.system(size: 38, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("Bluetooth pairing security code \(sas)")
                    Text("Confirm that these six digits match Android AirSIM.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Codes Match — Finish Pairing", systemImage: "checkmark.shield.fill") {
                        model.voble.confirmPairing()
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Cancel Pairing", role: .cancel) {
                        model.voble.cancelPairing()
                    }
                }
            }

            if !model.voble.discoveredPeers.isEmpty {
                Section("Discovered Android Agents") {
                    ForEach(model.voble.discoveredPeers) { peer in
                        Button {
                            model.voble.connect(peer)
                        } label: {
                            HStack {
                                Label(peer.name, systemImage: "smartphone")
                                Spacer()
                                Text("\(peer.signal) dBm")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section {
                Button("Scan Again", systemImage: "arrow.clockwise") {
                    model.voble.stop()
                    model.voble.start()
                }
                if model.voble.authenticatedIdentity != nil {
                    Button("Unpair VoBLE", systemImage: "trash", role: .destructive) {
                        showingUnpairConfirmation = true
                    }
                    .disabled(unpairing)
                } else if model.voble.recoverableIdentity != nil,
                          case .failed = model.voble.state {
                    Button("Clear Local Credentials and Scan Again", systemImage: "arrow.counterclockwise") {
                        model.voble.clearLocalCredentialAndRetry()
                    }
                }
            }
        }
        .navigationTitle("Bluetooth Agent")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.voble.start() }
        .confirmationDialog(
            "Delete VoBLE credentials on both iPhone and Android?",
            isPresented: $showingUnpairConfirmation,
            titleVisibility: .visible
        ) {
            Button("Unpair", role: .destructive) {
                unpairing = true
                Task {
                    defer { unpairing = false }
                    try? await model.voble.unpairCurrentPeer()
                }
            }
            Button("Keep Pairing", role: .cancel) {}
        } message: {
            Text("You will need to verify the six-digit code again. VoWLAN and cloud settings are unaffected.")
        }
    }

    private var stateTitle: String {
        switch model.voble.state {
        case .stopped: "Not Started"
        case .bluetoothUnavailable: "Bluetooth Unavailable"
        case .scanning: "Searching for Android Agents"
        case .connecting: "Connecting"
        case .connected: "Connected, discovering services"
        case .authenticating: "Authenticating with Agent"
        case .ready: "Bluetooth Calls Ready"
        case .failed: "Connection Failed"
        }
    }

    private var stateDetail: String {
        switch model.voble.state {
        case .ready: "Control channel authenticated. Audio starts during a call."
        case .failed(let message): message
        case .bluetoothUnavailable: "Turn on Bluetooth in Settings and allow AirSIM access"
        default: "Keep Android AirSIM running with Bluetooth mode enabled"
        }
    }

    private var stateSymbol: String {
        switch model.voble.state {
        case .ready: "checkmark.circle.fill"
        case .failed, .bluetoothUnavailable: "exclamationmark.triangle.fill"
        case .stopped: "wave.3.right.circle"
        default: "wave.3.right"
        }
    }

    private var stateColor: Color {
        switch model.voble.state {
        case .ready: .green
        case .failed, .bluetoothUnavailable: .orange
        case .stopped: .secondary
        default: .blue
        }
    }
}
