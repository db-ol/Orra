import AppKit
import SwiftUI

/// The language of Orra's interface: the Mac's own choice, or English, Simplified Chinese,
/// Japanese or Spanish for Orra alone. Kept as AppleLanguages in Orra's own defaults, the
/// same setting System Settings writes under Language & Region, Applications. macOS reads
/// it at launch, so a change shows after Orra restarts.
nonisolated enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case chinese = "zh-Hans"
    case japanese = "ja"
    /// Latin American Spanish. A Mac in any Spanish, such as Spain's, falls back to it, and
    /// its wording matches the menu items SwiftUI adds, which come from SwiftUI's es_419.
    case spanish = "es-419"

    var id: String { rawValue }

    static let defaultsKey = "AppleLanguages"

    /// The language's own name, so it reads right whatever the interface language is.
    var nativeName: String? {
        switch self {
        case .system: nil
        case .english: "English"
        case .chinese: "简体中文"
        case .japanese: "日本語"
        case .spanish: "Español"
        }
    }

    /// The choice saved for Orra. Only Orra's own defaults count, not the Mac's languages.
    static func load(from defaults: UserDefaults = .standard, domain: String = Bundle.main.bundleIdentifier ?? "") -> AppLanguage {
        guard let languages = defaults.persistentDomain(forName: domain)?[defaultsKey] as? [String],
              let first = languages.first else { return .system }
        if first.hasPrefix("zh") { return .chinese }
        if first.hasPrefix("en") { return .english }
        if first.hasPrefix("ja") { return .japanese }
        if first.hasPrefix("es") { return .spanish }
        return .system
    }

    /// The localization this choice shows, such as "en" or "zh-Hans". For the Mac's choice it
    /// is the one macOS picks from the Mac's languages at launch, so Chinese only when it
    /// comes before English. A language Orra does not have is passed over, and with none of
    /// Orra's languages, such as French alone, Orra shows English.
    func localization(macLanguages: [String] = Self.macLanguages(), available: [String] = Bundle.main.localizations) -> String {
        let preferences = self == .system ? macLanguages : [rawValue]
        let chosen = Bundle.preferredLocalizations(from: available, forPreferences: preferences).first
        return chosen.flatMap { available.contains($0) ? $0 : nil } ?? Self.english.rawValue
    }

    /// The Mac's languages as System Settings lists them, without Orra's own choice, which
    /// macOS puts first in Locale.preferredLanguages.
    static func macLanguages(from defaults: UserDefaults = .standard) -> [String] {
        defaults.persistentDomain(forName: UserDefaults.globalDomain)?[defaultsKey] as? [String] ?? Locale.preferredLanguages
    }

    /// The localization macOS loaded when this copy of Orra started. The menu, Settings and
    /// the indicator show it until Orra restarts.
    static let launchLocalization = Bundle.main.preferredLocalizations.first ?? english.rawValue

    func save(to defaults: UserDefaults = .standard) {
        if self == .system {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else {
            defaults.set([rawValue], forKey: Self.defaultsKey)
        }
    }

    /// Opens Orra again a moment after it quits, so the new language shows.
    @MainActor
    static func restart() {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        do {
            try shell.run()
        } catch {
            return
        }
        NSApplication.shared.terminate(nil)
    }
}

extension Locale {
    /// The locale Orra's strings are looked up in until it restarts, see
    /// `AppLanguage.launchLocalization`. Its region is left out, as the strings do not
    /// depend on it.
    nonisolated static let interface = Locale(identifier: AppLanguage.launchLocalization)
}

extension EnvironmentValues {
    /// The locale for the text a view builds in code, such as a talk key's name. The
    /// welcome window sets it to the language picked there, together with `locale`, which
    /// SwiftUI looks up text literals in. Elsewhere it stays the language Orra started with.
    @Entry var interfaceLocale: Locale = .interface
}
