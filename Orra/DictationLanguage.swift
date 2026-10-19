import Foundation

/// The language a user dictates in besides English, from Dictation language in Settings,
/// Dictation, and in the welcome window. English is always the other one, so a user can mix
/// the two in one sentence, and there is no third.
///
/// Chinese, Mandarin and Cantonese, is how Orra has always worked. Japanese and Spanish are
/// a beta. LanguageGuard accepts text in them in place of Chinese and asks the speech model
/// for them before English, see LanguageGuard.verdict(on:for:). Their text skips what was
/// made for Chinese and English: simplified characters, the filler and number rules, the
/// cleanup model, whose prompt and RewriteGuard know those two languages only, and learning
/// from corrections. English text of such a user takes them as before.
nonisolated enum DictationLanguage: String, CaseIterable, Identifiable, Sendable {
    case chinese = "Chinese"
    case japanese = "Japanese"
    case spanish = "Spanish"

    var id: String { rawValue }

    /// The choice in its own languages, so a speaker finds it whatever the interface
    /// language is. Never translated.
    var name: String {
        switch self {
        case .chinese: "中文（普通话和粤语）+ English"
        case .japanese: "日本語 + English"
        case .spanish: "Español + English"
        }
    }

    /// Japanese and Spanish are new and measured on read speech only, so their choice says
    /// beta.
    var isBeta: Bool {
        self != .chinese
    }

    /// The language the speech model is told to write first when it chose a language the
    /// user does not dictate in.
    var speechLanguage: SpeechLanguage {
        switch self {
        case .chinese: .chinese
        case .japanese: .japanese
        case .spanish: .spanish
        }
    }

    /// The passes LanguageGuard asks for, in this order, see Transcription.checkingLanguage:
    /// this language, then English. For Chinese the passes Orra always had.
    var passes: [SpeechLanguage] {
        [speechLanguage, .english]
    }

    /// Whether traditional Chinese characters are turned into simplified ones, see
    /// ChineseText. Only for Chinese: Japanese writes Han characters of its own, such as
    /// 駅, which must stay.
    var simplifiesCharacters: Bool {
        self == .chinese
    }

    /// Whether a transcript written with the vocabulary may take its numbers from a pass
    /// without it, see ContextNumbers. Only for Chinese: in Japanese text numbers in Han
    /// characters are Japanese, and English and Spanish text hold none.
    var takesDigitsFromPassWithoutVocabulary: Bool {
        self == .chinese
    }

    /// The language translation goes between with English, see TranslationDirection.
    var translationLanguage: TranslationTarget {
        switch self {
        case .chinese: .chinese
        case .japanese: .japanese
        case .spanish: .spanish
        }
    }

    /// The targets of translation, English first, as the prompts are read ahead.
    var translationTargets: [TranslationTarget] {
        [.english, translationLanguage]
    }

    /// The routes into those targets, in the same order.
    var translationRoutes: [TranslationRoute] {
        translationTargets.map { TranslationRoute(self, into: $0) }
    }

    /// The fixed direction into this language.
    var translationDirection: TranslationDirection {
        switch self {
        case .chinese: .chinese
        case .japanese: .japanese
        case .spanish: .spanish
        }
    }

    /// The choice for a new user, from their own language, see OwnLanguage: Japanese for
    /// Japanese, Spanish for Spanish, and Chinese for Chinese or none of the three, such as
    /// on a Mac in English or French only.
    static func preferred(appLanguage: AppLanguage, macLanguages: [String]) -> DictationLanguage {
        OwnLanguage.current(appLanguage: appLanguage, macLanguages: macLanguages) ?? .chinese
    }
}

/// Keeps the dictation language in UserDefaults, by name.
///
/// A new user starts with their own language, see `DictationLanguage.preferred`. A user
/// who set Orra up before the choice existed dictated in Chinese and English, so keeps
/// Chinese until they pick another, see `TriggerModePreference.wasSetUpBefore`. A launch
/// with nothing saved saves the language the user started with, see `keep`, since a new
/// user looks set up from the next launch on.
///
/// A new user's dictation language follows a language picked for Orra in the welcome
/// window, until they pick a dictation language or setup is done, see `follows`. After
/// that it never changes by itself, since a wrong dictation language costs recognition
/// quality.
nonisolated enum DictationLanguagePreference {
    static let defaultsKey = "dictationLanguage"
    /// Set once the user picks a dictation language, in Settings or in the welcome window.
    static let pickedKey = "dictationLanguagePicked"
    /// Set by the launch that saves a new user's first dictation language, see `keep`, so
    /// a language an earlier user saved never follows, also when they look new at a launch.
    static let newUserKey = "dictationLanguageNewUser"

    /// The saved language, or nil when none is saved or the saved one is unknown.
    static func saved(in defaults: UserDefaults = .standard) -> DictationLanguage? {
        defaults.string(forKey: defaultsKey).flatMap(DictationLanguage.init(rawValue:))
    }

    /// The saved language, or the one the user starts with: their own language for a user
    /// who never set Orra up, Chinese otherwise.
    static func load(setUpBefore: Bool, appLanguage: AppLanguage = .load(), macLanguages: [String] = AppLanguage.macLanguages(), from defaults: UserDefaults = .standard) -> DictationLanguage {
        saved(in: defaults) ?? (setUpBefore ? .chinese : .preferred(appLanguage: appLanguage, macLanguages: macLanguages))
    }

    static func save(_ language: DictationLanguage, to defaults: UserDefaults = .standard) {
        defaults.set(language.rawValue, forKey: defaultsKey)
    }

    /// Saves the language the user started with, unless one is saved, so it stays once
    /// the user has set Orra up. LaunchMigrations runs it at launch. With `follows`, which
    /// is true only for a new user then, it also notes the new user, see `follows`.
    static func keep(_ language: DictationLanguage, follows: Bool, in defaults: UserDefaults = .standard) {
        guard saved(in: defaults) == nil else { return }
        save(language, to: defaults)
        if follows {
            defaults.set(true, forKey: newUserKey)
        }
    }

    /// Whether the user picked a dictation language. A language Orra saved for them, at
    /// launch or following the welcome window, does not count.
    static func isPicked(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: pickedKey)
    }

    static func savePicked(to defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: pickedKey)
    }

    /// Whether a language picked for Orra in the welcome window sets the dictation language
    /// too, see `PushToTalkController.followAppLanguage(_:setupComplete:macLanguages:)`.
    /// Only for a new user: at the first launch, with nothing saved, and at later launches
    /// once `keep` noted them. Only on a Mac not set up at this launch, since the
    /// welcome window comes back at launch whenever setup is incomplete, and a user who
    /// lost a permission keeps their language. And only until the user picks a dictation
    /// language.
    static func follows(setUpBefore: Bool, in defaults: UserDefaults = .standard) -> Bool {
        let newUser = saved(in: defaults) == nil || defaults.bool(forKey: newUserKey)
        return newUser && !setUpBefore && !isPicked(in: defaults)
    }
}
