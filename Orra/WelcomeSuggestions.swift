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
    /// A second, smaller line, for where to find what Settings does not have.
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
    static func all(cleanupOn: Bool, cleanupModelInstalled: Bool, translationOn: Bool, locale: Locale = .interface) -> [WelcomeSuggestion] {
        Kind.allCases.map { kind in
            let isOn: Bool = switch kind {
            case .cleanup: cleanupOn && cleanupModelInstalled
            case .translation: translationOn
            case .meeting: false
            }
            let waitsForModel = kind == .cleanup && cleanupOn && !cleanupModelInstalled
            return WelcomeSuggestion(kind: kind, isOn: isOn, waitsForModel: waitsForModel, locale: locale)
        }
    }

    private init(kind: Kind, isOn: Bool, waitsForModel: Bool, locale: Locale) {
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
        // Meeting Captions is only in the Orra menu, and Speak translation waits for
        // Translation, so the row says where each is.
        note = kind == .meeting
            ? text("Turn on Meeting Captions in the Orra menu. Speak translation is in Settings, under General, once Translation is on.")
            : nil
        if isOn || waitsForModel {
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
