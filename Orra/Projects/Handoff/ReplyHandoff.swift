import AppKit
import os

/// Hands a draft reply to the user on a click in the Projects window. Orra never pastes the
/// draft and never sends mail. Only the user does, in Mail.
///
/// Open Reply in Mail, and Reply All, copy the draft first. Then Mail makes the reply and
/// opens its window, with the quote, the threading headers and the signature, see
/// MailBridge.reply. Then, while Orra is still in front, the draft goes on the clipboard
/// again and Mail comes to the front through NSRunningApplication's activate on Mail's
/// process, not through an Apple Event of its own (decision 19), and the user presses
/// Command V. When the window closes while Mail makes the reply, the reply window still
/// opens, but the clipboard and Mail stay as they are. While Mail does not run, Open Reply
/// only copies and says so, since Orra opens Mail only when the user clicks Open Mail. When
/// the reply fails, the draft stays on the clipboard. Copy only puts the draft on the
/// clipboard.
///
/// Between the reply and the second copy, Mail adds the files the user ticked for the
/// reply, one event a file in their order, each at the end of that reply, see
/// `attach(_:to:)`. Each file is checked again right before its event, so what Mail reads is
/// still the file the user ticked, in a folder a project holds at that moment, and still
/// ticked at that moment. An email
/// Projects wrote no draft for gets the reply and its files without the clipboard: with no
/// draft, no step of a handoff, the failed ones included, puts anything on the clipboard.
/// The draft and the files go to Mail only on the user's click.
///
/// The window runs one handoff at a time. It turns off Open Reply, Reply All and Copy while
/// one runs, so the clipboard holds the draft of the reply window that Mail brings forward.
///
/// Code in Orra/Projects never uses the pasteboard, so the copy comes in as a closure, which
/// code outside it makes with ConcealedClipboard. That keeps the draft from clipboard
/// managers and from Universal Clipboard. No closure has a default: the app passes
/// `{ NSApp.isActive }` and `ReplyHandoff.bringMailToFront`, and tests pass fakes of every
/// closure and of Mail.
///
/// Logs what happened and error codes only.
struct ReplyHandoff {
    /// What a handoff did, for the window to say. None holds mail data, a file's name or
    /// its path, so the log may show it.
    nonisolated enum Outcome: Equatable, Sendable {
        /// Mail opened the reply window, with what became of each file in the order given,
        /// empty when no file was given. With a draft, the draft went on the clipboard, and
        /// while Orra was still in front and the window open it went there again. Then Mail
        /// was asked to come to the front. The window says to press Command V there. The
        /// files are fewer than given when the window closed while Mail added them: Mail
        /// was not asked for the rest.
        case replyOpened(files: [FileResult])
        /// The draft is on the clipboard and nothing else happened: Copy, or Open Reply ended
        /// before Mail was asked, such as when the window closed.
        case copied
        /// The draft is on the clipboard, but Mail does not run, so there is no reply
        /// window. Orra opens Mail only when the user clicks Open Mail.
        case copiedMailNotRunning
        /// The draft is on the clipboard, but Mail did not make the reply, for this reason,
        /// such as `denied` while the user does not allow Orra to control Mail, or `notFound`
        /// when the message is no longer there. With `timedOut`, Mail may still open the
        /// reply window later, without coming to the front, so the window says the reply may
        /// still open rather than that it failed.
        case copiedReplyFailed(MailBridgeError)
        /// The draft is empty or only white space, so nothing happened.
        case emptyDraft
        /// The pasteboard did not take the draft, so nothing else happened either.
        case notCopied
        /// Without a draft: Mail does not run, so there is no reply window, and nothing
        /// went on the clipboard.
        case mailNotRunning
        /// Without a draft: Mail did not make the reply, for this reason, and nothing went
        /// on the clipboard. With `timedOut`, Mail may still open the reply window later.
        case replyFailed(MailBridgeError)
        /// Without a draft: the handoff ended before Mail was asked, such as when the window
        /// closed. Nothing changed.
        case stopped
    }

    /// What became of a file given for the reply.
    nonisolated enum FileResult: Equatable, Sendable {
        /// Mail took it into the reply.
        case attached
        case notAttached(AttachProblem)
    }

    /// Why a file is not in the reply. None names the file.
    nonisolated enum AttachProblem: Equatable, Sendable {
        /// The check right before its event found it changed, gone, outside the folders the
        /// projects hold now, or not on this Mac, so Mail was not asked for it. The next
        /// file still goes.
        case notChecked(ReplyFileProblem)
        /// It was no longer ticked when its turn came, as when a warning that the sender may
        /// not be who they claim arrived while earlier files went, so Mail was not asked for
        /// it. The next file still goes.
        case unticked
        /// Mail's answer to the reply named no outgoing message of its own, or Mail started
        /// again while it made the reply, so Orra cannot say where the files go.
        case noReplyNamed
        /// -1728: the reply is gone, as when the user closed its window first.
        case replyClosed
        /// Mail did not take this file, with its error code. The next file still goes.
        case refused(code: Int)
        /// Mail did not answer in time, and may still add the file.
        case timedOut
        /// Not asked for, since Mail did not answer in time for a file before it. A Mail that
        /// slow would hold the send thread up to the timeout for each of the rest.
        case afterTimeOut
        /// -1743 or -1744: Orra may not control Mail.
        case notAllowed
        /// The Mail that made the reply quit, also when another Mail runs now.
        case mailQuit
    }

    /// The files the user ticked for a reply, in their order, with the check each passes
    /// again right before Mail is asked to add it, such as ReplyFiles.recheck with the
    /// folders the projects hold at that moment. The check gives the file as it is then, at
    /// its new place after a rename, and the event takes that place. `isTicked` says whether
    /// the user still has the file ticked, asked before its check and again right before its
    /// event, so a file that went off the reply meanwhile, as every file does once the sender
    /// looks spoofed, is not given to Mail.
    nonisolated struct Files: Sendable {
        var files: [ReplyFile]
        var isTicked: @Sendable (ReplyFile) async -> Bool
        var check: @Sendable (ReplyFile) async -> Result<ReplyFile, ReplyFileProblem>

        init(
            _ files: [ReplyFile],
            isTicked: @escaping @Sendable (ReplyFile) async -> Bool = { _ in true },
            check: @escaping @Sendable (ReplyFile) async -> Result<ReplyFile, ReplyFileProblem>
        ) {
            self.files = files
            self.isTicked = isTicked
            self.check = check
        }

        /// No file, as for every reply before the user ticks one.
        static let none = Files([]) { .success($0) }
    }

    /// Puts the draft on the clipboard as it is, and says whether the pasteboard took it.
    let copy: (String) -> Bool
    /// Mail. The handoff uses only `isRunning`, `reply` and `attach`.
    let mail: MailBridge
    /// Whether Orra is the active app, as it is right after the user's click.
    let isOrraActive: () -> Bool
    /// Brings Mail to the front, once it opened the reply window.
    let bringMailToFront: () -> Void

    /// Open Reply in Mail, or Reply All with `all`, with the files the user ticked for the
    /// reply, in their order. Only on the user's click. A nil draft is an email Projects
    /// wrote no draft for, and nothing then goes on the clipboard.
    func openReply(_ draft: String?, to message: MailMessageRef, all: Bool, files: Files = .none) async -> Outcome {
        let outcome = await handOver(draft, to: message, all: all, files: files)
        Logger.projects.notice("Reply handoff, open reply\(all ? " to all" : "", privacy: .public) with \(files.files.count) files: \(String(describing: outcome), privacy: .public)")
        return outcome
    }

    /// Open Reply in Mail, or Reply All, when no reply can be asked for: Mail did not confirm
    /// that its message is the email, for this reason, or does not run. With a draft, the
    /// draft goes on the clipboard as Copy puts it, and the outcome says why no reply opened.
    /// Without a draft nothing goes on the clipboard.
    func replyNotAsked(_ draft: String?, because error: MailBridgeError) -> Outcome {
        guard let draft else {
            return error == .mailNotRunning ? .mailNotRunning : .replyFailed(error)
        }
        let copied = put(draft)
        guard copied == .copied else {
            return copied
        }
        return error == .mailNotRunning ? .copiedMailNotRunning : .copiedReplyFailed(error)
    }

    /// Copy: puts the draft on the clipboard and asks nothing of Mail.
    func copyOnly(_ draft: String) -> Outcome {
        let outcome = put(draft)
        Logger.projects.notice("Reply handoff, copy: \(String(describing: outcome), privacy: .public)")
        return outcome
    }

    private func handOver(_ draft: String?, to message: MailMessageRef, all: Bool, files: Files) async -> Outcome {
        if let draft {
            let copied = put(draft)
            guard copied == .copied else {
                return copied
            }
        }
        guard mail.isRunning() else {
            return draft == nil ? .mailNotRunning : .copiedMailNotRunning
        }
        let reply: MailReplyRef?
        do {
            reply = try await mail.reply(message, all)
        } catch is CancellationError {
            // Cancelled before its turn on the send thread, so Mail was never asked.
            return draft == nil ? .stopped : .copied
        } catch {
            // mailNotRunning here means that Mail quit before it answered.
            let error = error as? MailBridgeError ?? .failed(code: (error as NSError).code)
            guard draft != nil else {
                return error == .mailNotRunning ? .mailNotRunning : .replyFailed(error)
            }
            return error == .mailNotRunning ? .copiedMailNotRunning : .copiedReplyFailed(error)
        }
        let results = await attach(files, to: reply)
        // The window closed while Mail made the reply or added the files, such as when the
        // user closed it or Projects turned off. Mail was asked, so the reply window opens,
        // but the clipboard and Mail stay as they are.
        guard !Task.isCancelled else {
            Logger.projects.info("Reply handoff: the window closed, Mail stays where it is")
            return .replyOpened(files: results)
        }
        // A reply can take seconds. When the user went to another app meanwhile, Orra leaves
        // the clipboard and Mail as they are, so a copy made there is kept and Mail never
        // comes over that app. Otherwise the draft goes on the clipboard again, in case a
        // click in the window copied another one meanwhile, and Mail comes forward.
        guard isOrraActive() else {
            Logger.projects.info("Reply handoff: Orra is no longer in front, Mail stays where it is")
            return .replyOpened(files: results)
        }
        if let draft {
            _ = copy(draft)
        }
        bringMailToFront()
        return .replyOpened(files: results)
    }

    /// Adds the files to the reply Mail made, one event a file, in order, each at the end of
    /// the reply. Without a reply Mail named, none goes. Each file is checked again right
    /// before its event, and one that fails the check, or is no longer ticked before or after
    /// it, is left out, with the reason. A closed reply window, a refused permission, Mail
    /// quitting and a timeout stop the files after it: a timeout since a slow Mail would hold
    /// the send thread for each file in turn. Any other error skips its file only. A
    /// cancelled task ends the loop, and the files after it are left out of the results,
    /// since Mail was never asked for them.
    private func attach(_ files: Files, to reply: MailReplyRef?) async -> [FileResult] {
        guard let reply else {
            return files.files.map { _ in .notAttached(.noReplyNamed) }
        }
        var results: [FileResult] = []
        var stopped: AttachProblem?
        for file in files.files {
            if let stopped {
                results.append(.notAttached(stopped))
                continue
            }
            guard !Task.isCancelled else { break }
            guard await files.isTicked(file) else {
                results.append(.notAttached(.unticked))
                continue
            }
            let current: ReplyFile
            switch await files.check(file) {
            case .success(let checked):
                current = checked
            case .failure(let problem):
                results.append(.notAttached(.notChecked(problem)))
                continue
            }
            guard !Task.isCancelled else { break }
            // The check can take a while, on a folder of a share for one.
            guard await files.isTicked(file) else {
                results.append(.notAttached(.unticked))
                continue
            }
            do {
                try await mail.attach(current.url, reply)
                results.append(.attached)
            } catch is CancellationError {
                break
            } catch {
                let problem = Self.problem(error as? MailBridgeError ?? .failed(code: (error as NSError).code))
                results.append(.notAttached(problem))
                switch problem {
                case .replyClosed, .notAllowed, .mailQuit:
                    stopped = problem
                case .timedOut:
                    stopped = .afterTimeOut
                case .noReplyNamed, .refused, .afterTimeOut, .notChecked, .unticked:
                    break
                }
            }
        }
        return results
    }

    /// What an error of `attach` means for the file.
    private static func problem(_ error: MailBridgeError) -> AttachProblem {
        switch error {
        case .notFound: .replyClosed
        case .denied, .notAsked: .notAllowed
        case .mailNotRunning: .mailQuit
        case .timedOut: .timedOut
        case .notAnswered(let code), .failed(let code): .refused(code: code)
        case .changedWhileReading, .unexpectedReply: .refused(code: 0)
        }
    }

    /// Puts the draft on the clipboard, unless it is empty.
    private func put(_ draft: String) -> Outcome {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .emptyDraft
        }
        return copy(draft) ? .copied : .notCopied
    }

    /// Brings the running Mail to the front with its own activate, never with an Apple
    /// Event, and never launches it. Orra first yields its activation to Mail, which macOS
    /// asks of an app that activates another since macOS 14. Tests never call it.
    static func bringMailToFront() {
        guard let mail = MailEvents.runningMail() else {
            Logger.projects.info("Reply handoff: Mail quit before it came to the front")
            return
        }
        NSApplication.shared.yieldActivation(to: mail)
        if !mail.activate() {
            Logger.projects.info("Reply handoff: macOS did not bring Mail to the front")
        }
    }
}
