import Foundation

/// Everything the in-app call screen shows for one call, ready to draw.
struct ActiveCallContent: Equatable {
    enum Phase: Equatable {
        /// Ringing or waiting: Accept and Decline, no duration.
        case incoming
        /// Every other state: the in-call controls, End and the running duration.
        case connected
    }

    /// The color of the status badge or its dot. The call screen maps it to a system color.
    enum Tone: Equatable {
        case green
        case orange
        case red
    }

    let phase: Phase
    let header: String
    /// The contact's name, else the number, else "Unknown Number".
    let name: String
    let number: String?
    /// False without a number or when the name already is the number.
    let showsNumber: Bool
    let photo: Data?
    let startedAt: Date
    let isRecording: Bool
    let canToggleRecording: Bool
    let isMuted: Bool
    let speakerEnabled: Bool
    let status: String
    let badgeTone: Tone
    let dotTone: Tone
    /// The proximity sensor turns the screen off at the ear while a call is placed or live and the speaker is off.
    let monitorsProximity: Bool

    init(call: CallRecord, snapshot: AirSIMSnapshot) {
        phase = ["incoming", "waiting"].contains(call.state) ? .incoming : .connected
        header = phase == .incoming ? "AirSIM Incoming Call" : "AirSIM Call"
        name = snapshot.contacts.displayName(for: call.number)
        number = call.number
        showsNumber = call.number != nil && call.number != name
        photo = call.number.flatMap { snapshot.contacts.contact(for: $0)?.photoData }
        startedAt = call.startedAt
        isRecording = snapshot.isRecording
        canToggleRecording = snapshot.canToggleRecording && !snapshot.isRecordingBusy
        isMuted = snapshot.isMuted
        speakerEnabled = snapshot.speakerEnabled
        switch phase {
        case .incoming:
            let online = snapshot.isOnline || snapshot.cloudAgentStatus?.cloudOnline == true
            let signal = snapshot.modemStatus?.signalDBM ?? snapshot.cloudAgentStatus?.signalDBM
            status = (online ? "Module Online" : "Connecting to Module") + (signal.map { " · Signal \($0) dBm" } ?? "")
            badgeTone = online ? .green : .orange
            dotTone = badgeTone
        case .connected:
            let route = snapshot.audioActive && !snapshot.audioRoute.isEmpty ? " · \(snapshot.audioRoute)" : ""
            let error = snapshot.audioError.map { "\n\($0)" } ?? ""
            status = snapshot.callAudioStatusText + route + error
            badgeTone = Self.audioTone(snapshot)
            dotTone = snapshot.callAudioIsActive ? .green : badgeTone
        }
        let placedOrLive = ["dialing", "alerting", "connecting", "active", "held", "ending"].contains(call.state)
        monitorsProximity = placedOrLive && !snapshot.speakerEnabled
    }

    var isIncoming: Bool { phase == .incoming }
    var showsDuration: Bool { phase == .connected }

    /// "01:05" once connected, "Waiting" before.
    func duration(at now: Date) -> String {
        guard showsDuration else { return "Waiting" }
        let seconds = max(0, Int(now.timeIntervalSince(startedAt)))
        return Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond(padMinuteToLength: 2)))
    }

    /// Red once the call audio failed, green once it connected, orange while it starts.
    private static func audioTone(_ snapshot: AirSIMSnapshot) -> Tone {
        switch snapshot.cloudCallAudioState {
        case .failed:
            .red
        case .connected:
            .green
        case .starting, .connecting:
            .orange
        case .idle:
            snapshot.audioActive ? .green : .orange
        }
    }
}
