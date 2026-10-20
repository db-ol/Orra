import Foundation

/// The words of the Projects window and its menu item for the values Projects code returns,
/// mapped to localized text in one place (plan section 2.8).
nonisolated enum ProjectsWindowText {
    /// The menu item that opens the window, with the count of mail waiting for a reply, in
    /// the language of `locale`, Orra's own by default.
    static func menuTitle(replyDue: Int, locale: Locale = .interface) -> String {
        if replyDue > 0 {
            String(localized: LocalizedStringResource("Projects (\(replyDue) to Reply)…", locale: locale))
        } else {
            String(localized: LocalizedStringResource("Projects…", locale: locale))
        }
    }

    /// Why the model work waits now.
    static func pause(_ pause: ProjectsModelQueue.Pause) -> String {
        switch pause {
        case .dictation: String(localized: "Paused while you dictate.")
        case .captions: String(localized: "Paused while Live Captions run.")
        case .memory: String(localized: "Paused while this Mac is low on memory.")
        case .voice: String(localized: "Paused while the voice for Speak Translations to Others is loaded.")
        case .loading: String(localized: "Loading the cleanup model…")
        }
    }

    /// What Explain Selected Message found, when it shows no email.
    static func selection(_ found: ProjectsRuntime.SelectedMessage) -> String {
        switch found {
        case .found: ""
        case .noMailboxChosen: String(localized: "Projects reads no mail yet. Choose its mailboxes in Settings.")
        case .mailNotRunning: String(localized: "Open Mail first.")
        case .nothingSelected: String(localized: "Select a message in Mail first.")
        case .notInChosenMailbox: String(localized: "This message is in a mailbox Projects does not read. Choose the mailbox in Settings first.")
        case .notRead(let days): String(localized: "Projects has not read this message. It reads the mail of the last \(days) days in the mailboxes you chose.")
        case .stillReading: String(localized: "Projects is still reading your mail. Try again in a moment.")
        case .notAllowed: String(localized: "Orra is not allowed to read Mail yet. Allow it in Settings.")
        case .failed: String(localized: "Mail did not answer. Try again.")
        }
    }

    static func notice(_ notice: ProjectsWindowModel.Notice) -> String {
        switch notice {
        case .selection(let found): selection(found)
        case .projectNotSaved: String(localized: "The project could not be saved. Try again.")
        case .projectNotForgotten: String(localized: "The project could not be forgotten. Try again.")
        case .ruleNotSaved: String(localized: "The rule could not be saved. Try again.")
        }
    }

    static func explainFailure(_ failure: ProjectsWindowModel.ExplainFailure) -> String {
        switch failure {
        case .noModel: String(localized: "The cleanup model is not on this Mac.")
        case .tooLong: String(localized: "This email is too long to explain.")
        case .other: String(localized: "The email could not be explained. Try again.")
        }
    }

    /// The offer of a rule after two moves of the same kind: a sender rule or a domain rule.
    static func ruleOffer(_ rule: SortingCandidate.Rule, project: String) -> String {
        String(localized: "Always file mail from \(who(rule)) in \(project)?")
    }

    /// A rule of a project, for the project page.
    static func rule(_ rule: SortingCandidate.Rule) -> String {
        switch rule {
        case .sender, .domain: String(localized: "Mail from \(who(rule))")
        case .list(let list): String(localized: "Mail of the list \(list)")
        case .subjectCode(let code): String(localized: "Mail with \(code) in the subject")
        }
    }

    /// The address or the domain of a sender or domain rule, such as @harbor.example.
    private static func who(_ rule: SortingCandidate.Rule) -> String {
        switch rule {
        case .sender(let address): address
        case .domain(let domain): "@" + domain
        case .list(let value), .subjectCode(let value): value
        }
    }

    /// Why a file gives no text, for the project page.
    static func skipReason(_ reason: FileSkipReason) -> String {
        switch reason {
        case .hidden: String(localized: "Hidden")
        case .package: String(localized: "An app or a package")
        case .gitFolder, .nodeModules: String(localized: "A folder of code tools")
        case .archive: String(localized: "An archive, never opened")
        case .symbolicLink, .alias: String(localized: "A link, never followed")
        case .outsideFolder: String(localized: "Leads outside the folder")
        case .volume: String(localized: "Another disk")
        case .protectedFolder: String(localized: "A folder Projects never reads")
        case .tooLarge: String(localized: "Too large")
        case .dataless, .notDownloaded: String(localized: "Not downloaded to this Mac")
        case .unsupportedFormat: String(localized: "A format Projects does not read")
        case .spreadsheetOrSlides: String(localized: "Excel and PowerPoint files are not read yet")
        case .noAccess: String(localized: "Orra is not allowed to read it")
        case .unreadable: String(localized: "Could not be read")
        case .locked: String(localized: "Locked with a password")
        case .tooSlow: String(localized: "Took too long to read")
        case .noText: String(localized: "Holds no text")
        case .cancelled: String(localized: "Not read yet")
        }
    }

    /// A linked mailbox's name: the account's name and the mailbox's path, or On My Mac and
    /// the path, see ProjectsRuntime.mailboxName(_:).
    static func mailbox(_ name: String) -> String {
        name.hasPrefix("/") ? String(localized: "On My Mac") + name : name
    }

    /// Why an added folder is not indexed.
    static func refusal(_ refusal: FolderWalk.Refusal) -> String {
        switch refusal {
        case .notAFolder: String(localized: "This folder is missing or cannot be read.")
        case .home: String(localized: "Projects never reads your home folder.")
        case .volumeRoot: String(localized: "Projects never reads a whole disk.")
        case .mailData: String(localized: "Projects never reads the data of Mail.")
        }
    }
}
