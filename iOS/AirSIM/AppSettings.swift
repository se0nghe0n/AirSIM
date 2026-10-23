import SwiftUI
import UIKit

/// Centrally provides the mobile device name to avoid hardcoded iPad copy on iPhone.
enum DeviceContext {
    static var displayName: String {
        UIDevice.current.userInterfaceIdiom == .phone ? "iPhone" : "iPad"
    }

    static var symbolName: String {
        UIDevice.current.userInterfaceIdiom == .phone ? "iphone" : "ipad"
    }
}

/// Retains the Mac version's appearance options on iPhone/iPad.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return L10n.t("Follow System")
        case .light: return L10n.t("Light")
        case .dark: return L10n.t("Dark")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, zh, en
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return L10n.t("Follow System")
        case .zh: return L10n.t("Simplified Chinese")
        case .en: return "English"
        }
    }
}

@MainActor
@Observable
final class AppSettings {
    var appearance: AppAppearance {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: L10n.appearanceKey) }
    }
    var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: L10n.languageKey) }
    }

    init() {
        let defaults = UserDefaults.standard
        appearance = AppAppearance(rawValue: defaults.string(forKey: L10n.appearanceKey) ?? "") ?? .system
        language = AppLanguage(rawValue: defaults.string(forKey: L10n.languageKey) ?? "") ?? .en
    }
}

/// Lightweight localization helper shared across iOS/iPadOS views.
enum L10n {
    static let appearanceKey = "airsim.appearance"
    static let languageKey = "airsim.language"

    static var effectiveLanguage: AppLanguage {
        let saved = AppLanguage(rawValue: UserDefaults.standard.string(forKey: languageKey) ?? "") ?? .en
        if saved != .system { return saved }
        return (Locale.preferredLanguages.first ?? "").lowercased().hasPrefix("zh") ? .zh : .en
    }

    static func t(_ key: String) -> String {
        key
    }
}
