import Foundation

enum AppLanguageOption: String, CaseIterable, Identifiable, Sendable {
    case system
    case english
    case simplifiedChinese
    case japanese

    static let storageKey = "codex.mailroom.appLanguage"

    var id: String { rawValue }

    static func stored(in defaults: UserDefaults = .standard) -> AppLanguageOption {
        guard let rawValue = defaults.string(forKey: storageKey),
              let language = AppLanguageOption(rawValue: rawValue) else {
            return .system
        }
        return language
    }

    static func currentResolved(
        defaults: UserDefaults = .standard,
        locale: Locale = .autoupdatingCurrent
    ) -> AppResolvedLanguage {
        stored(in: defaults).resolved(using: locale)
    }

    func resolved(using locale: Locale = .autoupdatingCurrent) -> AppResolvedLanguage {
        switch self {
        case .system:
            let identifier = locale.language.languageCode?.identifier ?? locale.identifier.lowercased()
            if identifier.hasPrefix("zh") {
                return .simplifiedChinese
            }
            if identifier.hasPrefix("ja") {
                return .japanese
            }
            return .english
        case .english:
            return .english
        case .simplifiedChinese:
            return .simplifiedChinese
        case .japanese:
            return .japanese
        }
    }

    var nativeName: String {
        switch self {
        case .system:
            return LT("System", "跟随系统", "システム")
        case .english:
            return "English"
        case .simplifiedChinese:
            return "简体中文"
        case .japanese:
            return "日本語"
        }
    }

    var helperLabel: String {
        switch self {
        case .system:
            return LT("Follow the macOS language", "跟随 macOS 语言", "macOS の言語設定に従う")
        case .english:
            return LT("English interface", "英文界面", "英語インターフェース")
        case .simplifiedChinese:
            return LT("Simplified Chinese interface", "简体中文界面", "簡体字中国語インターフェース")
        case .japanese:
            return LT("Japanese interface", "日文界面", "日本語インターフェース")
        }
    }
}

enum AppResolvedLanguage: Sendable {
    case english
    case simplifiedChinese
    case japanese

    func text(_ english: String, _ simplifiedChinese: String, _ japanese: String) -> String {
        switch self {
        case .english:
            return english
        case .simplifiedChinese:
            return simplifiedChinese
        case .japanese:
            return japanese
        }
    }
}

@inline(__always)
func LT(_ english: String, _ simplifiedChinese: String, _ japanese: String) -> String {
    AppLanguageOption.currentResolved().text(english, simplifiedChinese, japanese)
}
