import Foundation

/// The words of the files of a reply: Files This Email Asks For, Attachments for the Reply,
/// the line above Open Reply in Mail and the note after a handoff with files. None names a
/// file but the one it is about, and none is logged.
extension ProjectsWindowText {
    /// What VoiceOver reads for a request of the email, before its sentence.
    static func request(_ request: FileRequest) -> String {
        String(localized: "The email asks: \(request.sentence)")
    }

    /// What VoiceOver reads for the checkbox of a file.
    static func attachLabel(_ name: String) -> String {
        String(localized: "Attach \(name) to the reply")
    }

    /// What VoiceOver reads for Remove beside a ticked file.
    static func removeLabel(_ name: String) -> String {
        String(localized: "Remove \(name) from the reply")
    }

    /// The orange line under a ticked file: the people a reply to all reaches outside the
    /// file's project.
    static func outside(project: String, addresses: [String]) -> String {
        String(localized: "Your reply may reach people outside \(project): \(addresses.joined(separator: ", "))")
    }

    /// Why a file cannot go into the reply, as the line under its row says it.
    static func replyFileProblem(_ problem: ReplyFileProblem) -> String {
        switch problem {
        case .notInAddedFolder: String(localized: "No longer in a folder you added to a project.")
        case .moved: String(localized: "No longer in its folder.")
        case .changed: String(localized: "It changed after you ticked it. Tick it again.")
        case .notDownloaded: String(localized: "Not downloaded to this Mac")
        case .package: String(localized: "Orra attaches single files only, not packages such as some Keynote or Pages documents.")
        }
    }

    /// Why a file of a handoff is not in the reply.
    static func attachProblem(_ problem: ReplyHandoff.AttachProblem) -> String {
        switch problem {
        case .notChecked(let problem): replyFileProblem(problem)
        case .noReplyNamed: String(localized: "Mail did not say which reply it opened.")
        case .replyClosed: String(localized: "The reply window closed first.")
        case .refused: String(localized: "Mail did not take it.")
        case .timedOut: String(localized: "Mail was slow to answer. Check whether the reply holds it.")
        case .afterTimeOut: String(localized: "Mail was slow with a file before it, so Orra did not ask for this one.")
        case .notAllowed: String(localized: "Orra may not control Mail. Allow it in Settings.")
        case .mailQuit: String(localized: "Mail quit.")
        }
    }

    /// A file of a handoff that is not in the reply, with why.
    static func notAttachedLine(name: String, problem: ReplyHandoff.AttachProblem) -> String {
        String(localized: "\(name): \(attachProblem(problem))", comment: "A file that is not in the reply, and why, such as floor-plan.pdf: Mail did not take it.")
    }

    /// The line under the area when the user ticked one file more than a reply takes.
    static var attachCap: String {
        String(localized: "Orra attaches at most \(ReplyFiles.maximum) files to one reply.")
    }

    /// The line under the area when the ticked files add up to more than many mail servers
    /// take, with their size as Finder writes it.
    static func largeTotal(_ bytes: Int64, locale: Locale = .interface) -> String {
        let size = bytes.formatted(ByteCountFormatStyle(style: .file, allowedUnits: .all, spellsOutZero: false, includesActualByteCount: false, locale: locale))
        return String(localized: "These files add up to \(size), more than many mail servers take.")
    }

    /// Why a file chosen with Add File… or dropped on the area was not added.
    static func refusal(_ refusal: ProjectsReplyFiles.Refusal) -> String {
        switch refusal.problem {
        case .notDownloaded:
            String(localized: "\(refusal.name) is not downloaded to this Mac. Download it in Finder first.")
        case .package:
            replyFileProblem(.package)
        case .notInAddedFolder, .moved, .changed:
            String(localized: "Orra attaches only files in the folders you added to a project, once Projects has read them. Add the file's folder to a project first, then wait until Projects has read it.")
        }
    }

    /// The line above Open Reply in Mail, by whether there is a draft and a ticked file.
    static func handoffLine(hasDraft: Bool, hasFiles: Bool) -> String {
        switch (hasDraft, hasFiles) {
        case (true, false):
            String(localized: "Open Reply in Mail puts the draft on the clipboard. Press ⌘V in the reply window, check the recipients and send it yourself.")
        case (true, true):
            String(localized: "Open Reply in Mail puts the draft on the clipboard and adds the files you ticked. Press ⌘V in the reply window, check the recipients and the files, and send it yourself.")
        case (false, _):
            String(localized: "Open Reply in Mail opens the reply with the files you ticked. Write your reply in Mail, check the recipients and send it yourself.")
        }
    }

    /// The note under the buttons after a handoff, a line each: what the handoff did, and
    /// for one with files or without a draft, how many files Mail took and each file it did
    /// not take with why, or that no file went when the reply did not open. A handoff with a
    /// draft and no file says what `handoff(_:)` says.
    static func handoffLines(_ note: ProjectsEmailModel.HandoffNote, files: ProjectsEmailModel.HandoffFiles?) -> [String] {
        guard let files else { return [handoff(note)] }
        guard case .outcome(.replyOpened) = note else {
            return [handoff(note)] + (files.given > 0 ? [String(localized: "No files were attached.")] : [])
        }
        var lines: [String] = []
        switch (files.withDraft, files.attached) {
        case (true, 0): lines.append(handoff(note))
        case (true, 1): lines.append(String(localized: "Mail opened the reply with 1 file attached, and the draft is on the clipboard. Press ⌘V in the reply window."))
        case (true, let count): lines.append(String(localized: "Mail opened the reply with \(count) files attached, and the draft is on the clipboard. Press ⌘V in the reply window."))
        case (false, 0): lines.append(String(localized: "Mail opened the reply. Write your reply there."))
        case (false, 1): lines.append(String(localized: "Mail opened the reply with 1 file attached. Write your reply there."))
        case (false, let count): lines.append(String(localized: "Mail opened the reply with \(count) files attached. Write your reply there."))
        }
        if !files.notAttached.isEmpty {
            lines.append(String(localized: "These files are not attached. Drag them from Attachments for the Reply into the reply window:"))
            lines += files.notAttached.map { notAttachedLine(name: $0.name, problem: $0.problem) }
        }
        return lines
    }

    /// Whether the note after a handoff says that Mail is not open, so Open Mail shows beside
    /// it.
    static func saysMailIsNotOpen(_ note: ProjectsEmailModel.HandoffNote) -> Bool {
        switch note {
        case .outcome(.copiedMailNotRunning), .outcome(.mailNotRunning): true
        default: false
        }
    }

    /// The line of Files This Email Asks For that says where Orra did not look, nil where it
    /// looked in every project's folders.
    static func scope(_ scope: ProjectsReplyFiles.Scope) -> String? {
        switch scope {
        case .everyProject: nil
        case .ownProject: String(localized: "This email has warnings, so Orra looked only in the folders of its project.")
        case .nowhere: String(localized: "This email has warnings and no project, so Orra does not look for files for it.")
        case .spoofed: String(localized: "Orra offers no files for this email, as its sender may not be who they claim to be.")
        }
    }
}
