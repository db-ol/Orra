import Foundation

/// What the welcome window suggests once Orra is ready: cleanup, translation and meeting
/// interpretation, each with one line and a button that opens Settings where it is set
/// up. Not a step. The user can ignore it, and Done still closes the window.
nonisolated struct WelcomeSuggestion: Equatable, Sendable, Identifiable {
    nonisolated enum Kind: CaseIterable, Sendable {
        case cleanup
        case translation
        case meeting
    }

    let kind: Kind
    /// Shown as on, with no button. Meeting interpretation is never shown as on, since it
    /// is made of more than one switch.
    let isOn: Bool
    let title: String
    let line: String
    /// The button's title, nil while the feature is on.
    let button: String?

    var id: Kind { kind }

    var symbol: String {
        switch kind {
        case .cleanup: "wand.and.sparkles"
        case .translation: "translate"
        case .meeting: "captions.bubble"
        }
    }

    /// Shown under "Orra is ready", so only once every step is done.
    static func shows(checklist: SetupChecklist) -> Bool {
        checklist.isComplete
    }

    static func all(cleanupOn: Bool, translationOn: Bool, locale: Locale = .interface) -> [WelcomeSuggestion] {
        Kind.allCases.map { kind in
            let isOn: Bool = switch kind {
            case .cleanup: cleanupOn
            case .translation: translationOn
            case .meeting: false
            }
            return WelcomeSuggestion(kind: kind, isOn: isOn, locale: locale)
        }
    }

    private init(kind: Kind, isOn: Bool, locale: Locale) {
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
            line = text("Hold the translation key and speak. Chinese becomes English, and English becomes Chinese.")
        case .meeting:
            title = text("Meeting interpretation")
            line = text("Read what others say in your language, and let them hear you in theirs, even in your own voice.")
        }
        if isOn {
            button = nil
        } else if kind == .meeting {
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
