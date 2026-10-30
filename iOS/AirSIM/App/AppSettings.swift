import Observation
import UIKit

/// Centrally provides the mobile device name to avoid hardcoded iPad copy on iPhone.
enum DeviceContext {
    static var displayName: String {
        UIDevice.current.userInterfaceIdiom == .phone ? "iPhone" : "iPad"
    }
}

/// Retains the Mac version's appearance options on iPhone/iPad.
enum AppAppearance: String, CaseIterable, Sendable {
    case system, light, dark

    var title: String {
        switch self {
        case .system: return L10n.t("Follow System")
        case .light: return L10n.t("Light")
        case .dark: return L10n.t("Dark")
        }
    }

    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: return .unspecified
        case .light: return .light
        case .dark: return .dark
        }
    }
}

@MainActor
@Observable
final class AppSettings {
    var appearance: AppAppearance {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: L10n.appearanceKey) }
    }

    init() {
        let defaults = UserDefaults.standard
        appearance = AppAppearance(rawValue: defaults.string(forKey: L10n.appearanceKey) ?? "") ?? .system
    }
}

/// Lightweight localization helper shared across iOS/iPadOS views.
enum L10n {
    static let appearanceKey = "airsim.appearance"

    static func t(_ key: String) -> String {
        key
    }
}
