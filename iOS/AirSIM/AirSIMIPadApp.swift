import SwiftUI

/// AirSIM iPhone/iPad 入口：三星 VoWLAN 与独立云端 Relay。
@main
struct AirSIMIPadApp: App {
    @UIApplicationDelegateAdaptor(AirSIMNotificationDelegate.self) private var appDelegate
    @State private var settings = AppSettings()
    @Environment(\.scenePhase) private var scenePhase

    /// 恢复 @StateObject 的惰性时机：AppModel 只在 body 首次求值时创建，
    /// didFinishLaunching 仍能在 handler 为空时安装 CallKit 冷启动 handler，
    /// 锁屏 PushKit 唤醒时也不会抢先构建联系人缓存、音频会话等资源。
    @MainActor private enum AppModelHolder {
        static let shared = AppModel()
    }
    private var model: AppModel { AppModelHolder.shared }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(model.contacts)
                .environment(model.audio)
                .environment(settings)
                .onAppear {
                    WatchCallCoordinator.shared.configure(model: model)
                    WatchCallCoordinator.shared.start()
                    model.start(sceneIsActive: scenePhase == .active)
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                model.didBecomeActive()
            case .inactive:
                // 必须在真正进入后台前启动音频会话；等到 .background 才启动时，
                // iOS 可能已经冻结进程，后续来电和短信事件便无法继续等待。
                model.willResignActive()
            case .background:
                model.didEnterBackground()
            default:
                break
            }
        }
    }
}
