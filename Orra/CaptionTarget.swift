import Foundation

/// The language Live Captions translate into, apart from Translate into of the translation
/// key. Captions are what the user reads, the translation key is what others read or hear,
/// so each has its own setting. The caption window and the Meeting Interpretation page
/// choose it, and both write the same value, see CaptionTargetPreference.
///
/// Captions offer English and the dictation language, so every route is one of the two
/// routes of the dictation language, see `choices(for:)`. A target saved for another
/// dictation language stays saved, so going back to that language brings it back, and
/// meanwhile acts and shows as the dictation language, see `effective(_:for:)`.
///
/// Each sentence is read with the rule of the dictation language, as a dictation is, with
/// two exceptions for captions, see `source(of:in:)`. A sentence in the target already is
/// shown as it was said, on every route. Every other sentence goes into the target, and
/// one in neither language into English, see `target(source:into:in:)`.
nonisolated enum CaptionTarget {
    /// English and the dictation language, in the order Translate into lists them.
    static func choices(for language: DictationLanguage) -> [TranslationTarget] {
        language.translationTargets
    }

    /// What captions translate into for a user who dictates in `language`: `target` when
    /// it is one of the choices, and the dictation language otherwise. The window, Settings,
    /// the sentences and the prompts read ahead all follow it.
    static func effective(_ target: TranslationTarget, for language: DictationLanguage) -> TranslationTarget {
        choices(for: language).contains(target) ? target : language.translationLanguage
    }

    /// The route whose prompt is read ahead while captions run: the one into the target.
    /// A sentence in neither language goes into English on the other route, which is rare
    /// enough to fill when it comes.
    static func route(_ target: TranslationTarget, in language: DictationLanguage) -> TranslationRoute {
        TranslationRoute(language, into: effective(target, for: language))
    }

    /// The language of a caption sentence for a user who dictates in `language`, or nil
    /// when it has no letter to translate, see TranslationDirection.source(of:in:). Two
    /// readings change for captions, so that a meeting in the language the rule mistakes
    /// for the dictation language still goes into English, as under Automatic before
    /// captions had their own target, instead of showing as said:
    /// - Under the Chinese rule, a sentence read as Chinese that holds kana is Japanese,
    ///   since Japanese with kanji reads as Chinese. So is one in kana only, which the rule
    ///   finds nothing to translate in, so that all Japanese goes into English.
    /// - Under the Japanese rule, a sentence read as Japanese that holds Han characters and
    ///   no kana is not Japanese, since Chinese reads as Japanese. Japanese said without any
    ///   kana goes into English too, which is rare in speech.
    static func source(of text: String, in language: DictationLanguage) -> TranslationDirection.Source? {
        let source = TranslationDirection.source(of: text, in: language)
        guard source == .partner || (source == nil && language == .chinese) else { return source }
        let letters = text.precomposedStringWithCompatibilityMapping.unicodeScalars.filter(\.properties.isAlphabetic)
        let kana = letters.contains(where: LanguageGuard.isKana)
        switch language {
        case .chinese: return kana ? .other : source
        case .japanese: return !kana && letters.contains(where: LanguageGuard.isHan) ? .other : .partner
        case .spanish: return .partner
        }
    }

    /// The language a caption sentence in `source` is translated into for the caption
    /// target `target`, or nil when it needs no translation: nothing to translate, or a
    /// sentence in the target already. A sentence in neither language goes into English.
    static func target(source: TranslationDirection.Source?, into target: TranslationTarget, in language: DictationLanguage) -> TranslationTarget? {
        guard let source else { return nil }
        let target = effective(target, for: language)
        switch source {
        case .english: return target == .english ? nil : target
        case .partner: return target == language.translationLanguage ? nil : target
        case .other: return .english
        }
    }

    /// The route for a caption sentence and its language, read once, or nil when it needs
    /// no translation. Off the main actor, since the Spanish rule may run
    /// NLLanguageRecognizer. The checks of the translation take the language on.
    @concurrent
    static func plan(for text: String, into target: TranslationTarget, in language: DictationLanguage) async -> (route: TranslationRoute, source: TranslationDirection.Source)? {
        guard let source = source(of: text, in: language), let into = self.target(source: source, into: target, in: language) else { return nil }
        return (TranslationRoute(language, into: into), source)
    }
}

/// Keeps the caption target in UserDefaults, by the language code of TranslationTarget.
///
/// It is saved when the user picks one, in the caption window or in Settings, and once at
/// launch for a user of an earlier version, see `migrate`. Nothing else writes it, so a
/// target that is only the default never turns into a pick. Until a target is saved, it
/// follows the user's own language, see `defaultTarget(ownLanguage:)`, since a wrong
/// caption target costs one click to change.
nonisolated enum CaptionTargetPreference {
    static let defaultsKey = "captionTarget"
    /// Set by the first launch of a version with the caption target, so `migrate` runs
    /// once. Without it a new user, who looks set up from the second launch on, would be
    /// taken for an earlier user then.
    static let migratedKey = "captionTargetMigrated"

    /// The saved target, or nil when none is saved or the saved one is unknown.
    static func saved(in defaults: UserDefaults = .standard) -> TranslationTarget? {
        defaults.string(forKey: defaultsKey).flatMap(TranslationTarget.init(rawValue:))
    }

    static func save(_ target: TranslationTarget, to defaults: UserDefaults = .standard) {
        defaults.set(target.rawValue, forKey: defaultsKey)
    }

    /// The target while none is saved: the user's own language, see OwnLanguage, and
    /// English without one. So a Mac with English first and Chinese second, which shows
    /// Orra in English, reads an English meeting in Chinese, as under Automatic before.
    static func defaultTarget(ownLanguage: DictationLanguage?) -> TranslationTarget {
        ownLanguage?.translationLanguage ?? .english
    }

    /// The target that keeps an earlier user's captions as close as can be to what they
    /// were, when captions translated the way the translation key does: their Translate
    /// into when it is fixed to a language that fits their dictation language, otherwise
    /// their own language when it is one of the choices, otherwise their dictation
    /// language. An English meeting then still comes out in their language, as under
    /// Automatic. With English and the dictation language as the only choices, the own
    /// language counts only when it is the dictation language.
    static func earlierTarget(direction: TranslationDirection, language: DictationLanguage, ownLanguage: DictationLanguage?) -> TranslationTarget {
        if direction != .automatic, direction.fits(language) {
            return direction == .english ? .english : language.translationLanguage
        }
        if let own = ownLanguage?.translationLanguage, CaptionTarget.choices(for: language).contains(own) {
            return own
        }
        return language.translationLanguage
    }

    /// At the first launch of this version, saves `earlierTarget` for a user who set Orra
    /// up before, see TriggerModePreference.wasSetUpBefore, unless a target is saved.
    /// Runs once, see `migratedKey`. Returns the target it saved, nil when it saved none.
    /// LaunchMigrations runs it at every launch.
    @discardableResult
    static func migrate(setUpBefore: Bool, direction: TranslationDirection, language: DictationLanguage, ownLanguage: DictationLanguage?, in defaults: UserDefaults = .standard) -> TranslationTarget? {
        guard !defaults.bool(forKey: migratedKey) else { return nil }
        defaults.set(true, forKey: migratedKey)
        guard setUpBefore, saved(in: defaults) == nil else { return nil }
        let target = earlierTarget(direction: direction, language: language, ownLanguage: ownLanguage)
        save(target, to: defaults)
        return target
    }
}
