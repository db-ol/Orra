import AppKit

/// The language of Orra's interface: the Mac's own choice, or English or Simplified Chinese
/// for Orra alone. Kept as AppleLanguages in Orra's own defaults, the same setting System
/// Settings writes under Language & Region, Applications. macOS reads it at launch, so a
/// change shows after Orra restarts.
nonisolated enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case chinese = "zh-Hans"

    var id: String { rawValue }

    static let defaultsKey = "AppleLanguages"

    /// The language's own name, so it reads right whatever the interface language is.
    var nativeName: String? {
        switch self {
        case .system: nil
        case .english: "English"
        case .chinese: "简体中文"
        }
    }

    /// The choice saved for Orra. Only Orra's own defaults count, not the Mac's languages.
    static func load(from defaults: UserDefaults = .standard, domain: String = Bundle.main.bundleIdentifier ?? "") -> AppLanguage {
        guard let languages = defaults.persistentDomain(forName: domain)?[defaultsKey] as? [String],
              let first = languages.first else { return .system }
        if first.hasPrefix("zh") { return .chinese }
        if first.hasPrefix("en") { return .english }
        return .system
    }

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
