import Foundation

/// What the welcome window suggests once Orra is ready: cleanup, translation, meeting
/// interpretation and, on a Mac where it can be turned on, Projects, each with one line and
/// a button that opens Settings where it is set up. Not a step. The user can ignore it, and
/// Done still closes the window.
nonisolated struct WelcomeSuggestion: Equatable, Sendable, Identifiable {
    nonisolated enum Kind: CaseIterable, Sendable {
        case cleanup
        case translation
        case meeting
        /// Last, and only in a build that shows Projects on a Mac with the memory it needs.
        case projects
    }

    let kind: Kind
    /// Shown as on, with no button. Meeting interpretation is never shown as on, since it
    /// is made of more than one switch. Projects is on once its switch is.
    let isOn: Bool
    let title: String
    let line: String
    /// A second, smaller line, for where to find the parts of a feature.
    let note: String?
    /// The button's title. Nil while the feature is on, and while cleanup is on and waits
    /// for its model, since step 1 offers that download.
    let button: String?

    var id: Kind { kind }

    var symbol: String {
        switch kind {
        case .cleanup: "wand.and.sparkles"
        case .translation: "translate"
        case .meeting: "captions.bubble"
        case .projects: "briefcase"
        }
    }

    /// Shown under "Orra is ready", so only once every step is done.
    static func shows(checklist: SetupChecklist) -> Bool {
        checklist.isComplete
    }

    /// - Parameters:
    ///   - cleanupOn: Whether Clean Up Text is on.
    ///   - cleanupModelInstalled: Whether the cleanup model is on this Mac. Cleanup shows
    ///     On only with both, so the row never says On while step 1 offers the download.
    ///   - translationOn: Whether Translation is on.
    ///   - language: The dictation language, which translation goes between with English.
    ///   - translationKey: The translation key, which the translation line names.
    ///   - translationMode: How the translation key works, which the translation line says.
    ///   - projectsAvailable: Whether Projects can be turned on: a build that shows it, on a
    ///     Mac with the memory it needs. Its row shows only then.
    ///   - projectsOn: Whether Projects is on.
    static func all(cleanupOn: Bool, cleanupModelInstalled: Bool, translationOn: Bool, language: DictationLanguage = .chinese, translationKey: Hotkey = .rightOption, translationMode: TriggerMode = .newTranslationKeyMode, projectsAvailable: Bool = false, projectsOn: Bool = false, locale: Locale = .interface) -> [WelcomeSuggestion] {
        Kind.allCases.filter { $0 != .projects || projectsAvailable }.map { kind in
            let isOn: Bool = switch kind {
            case .cleanup: cleanupOn && cleanupModelInstalled
            case .translation: translationOn
            case .meeting: false
            case .projects: projectsOn
            }
            let waitsForModel = kind == .cleanup && cleanupOn && !cleanupModelInstalled
            return WelcomeSuggestion(kind: kind, isOn: isOn, waitsForModel: waitsForModel, language: language, translateHint: translationKey.translateHint(mode: translationMode, in: locale), locale: locale)
        }
    }

    private init(kind: Kind, isOn: Bool, waitsForModel: Bool, language: DictationLanguage, translateHint: String, locale: Locale) {
        self.kind = kind
        self.isOn = isOn
        func text(_ resource: LocalizedStringResource) -> String {
            var resource = resource
            resource.locale = locale
            return String(localized: resource)
        }
        switch kind {
        case .cleanup:
            title = text("Cleanup")
            line = text("Removes fillers and fixes what you correct while speaking.")
        case .translation:
            title = text("Translation")
            // How to use the key in its mode, such as "Press right Option to translate, and
            // again to finish", then what comes out.
            line = switch language {
            case .chinese: text("\(translateHint). Chinese becomes English, and English becomes Chinese.")
            case .japanese: text("\(translateHint). Japanese becomes English, and English becomes Japanese.")
            case .spanish: text("\(translateHint). Spanish becomes English, and English becomes Spanish.")
            }
        case .meeting:
            title = text("Meeting interpretation")
            line = text("Read what others say in your language, and let them hear you in theirs, even in your own voice.")
        case .projects:
            title = text("Projects")
            // The line at the top of Settings, Projects.
            line = text("Sorts your mail into projects and explains each email with the files of your projects.")
        }
        // The button opens the Meeting Interpretation page, and the Orra menu has the same
        // switches. Speaking translations waits for Translation, which has its own page.
        // So the row says where both parts are and what they need. Projects is a preview
        // that needs the Mail app, which its row says before the user turns it on.
        note = switch kind {
        case .meeting: text("Live Captions and Speak Translations to Others are under Meeting Interpretation, in Settings and in the Orra menu. Speaking translations needs Translation on.")
        case .projects: text("A preview. It works with the Mail app on this Mac.")
        case .cleanup, .translation: nil
        }
        if isOn || waitsForModel {
            button = nil
        } else if kind == .meeting || kind == .projects {
            // Turning Projects on is one step of its checklist in Settings.
            button = text("Set Up in Settings…")
        } else {
            button = text("Turn On in Settings…")
        }
    }

    /// The heading of the block.
    static func heading(locale: Locale = .interface) -> String {
        var resource: LocalizedStringResource = "Try next"
        resource.locale = locale
        return String(localized: resource)
    }

    /// What a feature that is on shows in place of its button.
    static func onLabel(locale: Locale = .interface) -> String {
        var resource: LocalizedStringResource = "On"
        resource.locale = locale
        return String(localized: resource)
    }
}
