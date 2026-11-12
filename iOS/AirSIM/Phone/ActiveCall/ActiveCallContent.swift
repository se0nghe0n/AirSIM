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
    let contact: ContactStore.Contact?
    let photo: Data?
    let startedAt: Date
    let isRecording: Bool
    let isRecordingBusy: Bool
    let canToggleRecording: Bool
    let isMuted: Bool
    let speakerEnabled: Bool
    let status: String
    /// Shown apart from the status badge, and only on a connected call.
    let audioError: String?
    let badgeTone: Tone
    let dotTone: Tone
    let monitorsProximity: Bool

    init(call: CallRecord, snapshot: AirSIMSnapshot) {
        phase = ["incoming", "waiting"].contains(call.state) ? .incoming : .connected
        header = phase == .incoming ? "AirSIM Incoming Call" : "AirSIM Call"
        let matchedContact = call.number.flatMap { snapshot.contacts.contact(for: $0) }
        contact = matchedContact
        name = snapshot.contacts.displayName(for: call.number)
        number = call.number
        showsNumber = call.number != nil && call.number != name
        photo = matchedContact?.photoData
        startedAt = call.startedAt
        isRecording = snapshot.isRecording
        isRecordingBusy = snapshot.isRecordingBusy
        canToggleRecording = snapshot.canToggleRecording && !snapshot.isRecordingBusy
        isMuted = snapshot.isMuted
        speakerEnabled = snapshot.speakerEnabled
        switch phase {
        case .incoming:
            let online = snapshot.isOnline || snapshot.cloudAgentStatus?.cloudOnline == true
            let signal = snapshot.modemStatus?.signalDBM ?? snapshot.cloudAgentStatus?.signalDBM
            status = (online ? "Module Online" : "Connecting to Module") + (signal.map { " · Signal \($0) dBm" } ?? "")
            audioError = nil
            badgeTone = online ? .green : .orange
            dotTone = badgeTone
        case .connected:
            let route = snapshot.audioActive && !snapshot.audioRoute.isEmpty ? " · \(snapshot.audioRoute)" : ""
            status = snapshot.callAudioStatusText + route
            audioError = snapshot.audioError.flatMap { $0.isEmpty ? nil : $0 }
            badgeTone = Self.audioTone(snapshot)
            dotTone = snapshot.callAudioIsActive ? .green : badgeTone
        }
        let placedOrLive = ["dialing", "alerting", "connecting", "active", "held", "ending"].contains(call.state)
        monitorsProximity = placedOrLive && !snapshot.speakerEnabled
    }

    var isIncoming: Bool { phase == .incoming }
    var showsDuration: Bool { phase == .connected }
    var showsRecordingPill: Bool { phase == .connected && (isRecording || isRecordingBusy) }

    var recordingMenuTitle: String {
        if isRecordingBusy {
            return "Updating Recording…"
        }
        return isRecording ? "Stop Recording" : "Call Recording"
    }

    var recordingMenuSubtitle: String {
        if isRecordingBusy {
            return "Please wait while local recording updates"
        }
        if isRecording {
            return "Recording locally · Tap to stop and save"
        }
        if canToggleRecording {
            return "Save both sides locally on this iPhone"
        }
        return "Available once call audio is connected"
    }

    var recordingPillTitle: String {
        if isRecordingBusy {
            return "Updating Recording…"
        }
        return "Recording · Stop"
    }

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
