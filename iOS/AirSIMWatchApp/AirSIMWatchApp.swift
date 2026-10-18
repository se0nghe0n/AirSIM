import SwiftUI

@main
struct AirSIMWatchApp: App {
    @State private var callSession = WatchCallSession()

    var body: some Scene {
        WindowGroup {
            WatchCallView()
                .environment(callSession)
        }
    }
}
