import ComposableArchitecture
import Foundation

@Reducer
struct RecordingsFeature {
    @ObservableState
    struct State: Equatable {
        @SharedReader fileprivate var snapshot: AirSIMSnapshot
        @Presents var alert: AlertState<Action.Alert>?

        init(snapshot: SharedReader<AirSIMSnapshot>) {
            _snapshot = snapshot
        }

        var recordings: [CallRecordingFile] { snapshot.recordings }
        var isSaving: Bool { snapshot.recordingsBusy }
        var playingID: UUID? { snapshot.playingRecordingID }
        var isCallActive: Bool { snapshot.callLifecycleSnapshot.state.representsCall }

        func recording(id: String) -> CallRecordingFile? {
            recordings.first { $0.id.uuidString == id }
        }

        func shareURL(for recording: CallRecordingFile) -> URL? {
            snapshot.recordingURLs[recording.id]
        }
    }

    enum Action: ViewAction {
        case view(View)
        case stopPlayback(deactivateSession: Bool)
        case failed(String)
        case alert(PresentationAction<Alert>)

        enum View {
            case appeared
            case disappeared
            case refreshPulled
            case playTapped(CallRecordingFile)
            case deleteTapped(CallRecordingFile)
        }

        enum Alert: Equatable {
            case ok
        }
    }

    @Dependency(\.airSIM) var client

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .view(.appeared), .view(.refreshPulled):
                return run(.reloadRecordings)

            case .view(.disappeared):
                return run(.stopPlayback(!state.isCallActive))

            case .view(.playTapped(let recording)):
                return run(.play(recording), failure: "Unable to play recording")

            case .view(.deleteTapped(let recording)):
                return run(.deleteRecording(recording), failure: "Unable to delete recording")

            case .stopPlayback(let deactivateSession):
                return run(.stopPlayback(deactivateSession))

            case .failed(let error):
                state.alert = .error(error, title: "Recording Error", ok: .ok)
                return .none

            case .alert:
                return .none
            }
        }
        .ifLet(\.$alert, action: \.alert)
    }

    /// A failure names its operation when one is given, e.g. "Unable to play recording: <reason>".
    private func run(_ command: AirSIMCommand, failure operation: String? = nil) -> Effect<Action> {
        .run { [client] send in
            do {
                try await client.command(command)
            } catch {
                let reason = error.localizedDescription
                await send(.failed(operation.map { "\($0): \(reason)" } ?? reason))
            }
        }
    }
}
