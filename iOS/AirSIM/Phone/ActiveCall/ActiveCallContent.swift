import Foundation

struct ActiveCallContent: Equatable {
    enum Phase: Equatable {
        case incoming
        case connected
    }

    enum Tone: Equatable {
        case green
        case orange
        case red
    }

    let phase: Phase
    let header: String
    let name: String
    let number: String?
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

    func duration(at now: Date) -> String {
        guard showsDuration else { return "Waiting" }
        let seconds = max(0, Int(now.timeIntervalSince(startedAt)))
        return Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond(padMinuteToLength: 2)))
    }

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
