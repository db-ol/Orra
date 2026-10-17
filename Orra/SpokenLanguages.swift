import Foundation

/// The languages the user dictates in, from Languages I Speak in Settings: Chinese and
/// English always, and Spanish or Japanese when the user turns them on, as a beta.
/// LanguageGuard accepts a transcript in any of them, so text the model wrote in a language
/// the user speaks is pasted after one pass, as Chinese and English are. With none added,
/// Orra works as it did before the setting.
nonisolated struct SpokenLanguages: Equatable, Sendable {
    /// The languages the user can add, in the order Settings shows them.
    static let addable: [SpeechLanguage] = [.spanish, .japanese]
    /// Chinese and English only, the default.
    static let chineseAndEnglish = SpokenLanguages()

    /// The languages added to Chinese and English, each one of `addable`.
    private(set) var added: Set<SpeechLanguage>

    init(adding added: Set<SpeechLanguage> = []) {
        self.added = added.intersection(Self.addable)
    }

    func contains(_ language: SpeechLanguage) -> Bool {
        switch language {
        case .chinese, .english: true
        case .spanish, .japanese: added.contains(language)
        }
    }

    /// The same languages with `language` added or taken out. Chinese and English stay.
    func setting(_ language: SpeechLanguage, on: Bool) -> SpokenLanguages {
        var added = added
        if on {
            added.insert(language)
        } else {
            added.remove(language)
        }
        return SpokenLanguages(adding: added)
    }

    /// The languages LanguageGuard tells the model to write, in this order, when the model
    /// chose a language the user does not speak: Chinese and English first, as before the
    /// setting, then the added ones.
    var passes: [SpeechLanguage] {
        [.chinese, .english] + Self.addable.filter(added.contains)
    }
}

/// The languages the user added, saved by name. None until the user turns one on.
nonisolated enum SpokenLanguagesPreference {
    static let defaultsKey = "spokenLanguages"

    static func load(from defaults: UserDefaults = .standard) -> SpokenLanguages {
        let names = defaults.stringArray(forKey: defaultsKey) ?? []
        return SpokenLanguages(adding: Set(names.compactMap(SpeechLanguage.init(rawValue:))))
    }

    static func save(_ languages: SpokenLanguages, to defaults: UserDefaults = .standard) {
        defaults.set(SpokenLanguages.addable.filter(languages.added.contains).map(\.rawValue), forKey: defaultsKey)
    }
}
