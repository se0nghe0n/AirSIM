import ComposableArchitecture
import Foundation

@Reducer
struct RecordingsFeature {
    @ObservableState struct State: Equatable {
        var playingID: UUID?
        @Presents var alert: AlertState<Action.Alert>?
    }
    enum Action {
        case play(CallRecordingFile), stop(Bool), delete(CallRecordingFile), reload, failed(String), alert(PresentationAction<Alert>)
        enum Alert: Equatable { case ok }
    }
    @Dependency(\.airSIM) var client
    var body: some ReducerOf<Self> {
        Reduce { state, action in
            let command: AirSIMCommand
            switch action {
            case .play(let file): command = .play(file)
            case .stop(let deactivate): command = .stopPlayback(deactivate)
            case .delete(let file): command = .deleteRecording(file)
            case .reload: command = .reloadRecordings
            case .failed(let error): state.alert = .error(error, title: "Recording Error", ok: .ok); return .none
            case .alert: return .none
            }
            return .run { [client] send in do { try await client.command(command) } catch { await send(.failed(error.localizedDescription)) } }
        }
        .ifLet(\.$alert, action: \.alert)
    }
}
