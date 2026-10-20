import AppKit
import os

/// Hands a draft reply to the user on a click in the Projects window. Orra never pastes the
/// draft and never sends mail. Only the user does, in Mail.
///
/// Open Reply in Mail, and Reply All, copy the draft first. Then Mail makes the reply and
/// opens its window, with the quote, the threading headers and the signature, see
/// MailBridge.reply. Then Mail comes to the front through NSRunningApplication's activate on
/// Mail's process, not through an Apple Event of its own (decision 19), and the user
/// presses Command V. While Mail does not run, Open Reply only copies and says so, since
/// Orra never opens Mail. When the reply fails, the draft stays on the clipboard. Copy only
/// puts the draft on the clipboard.
///
/// Code in Orra/Projects never uses the pasteboard, so the copy comes in as a closure, which
/// code outside it makes with ConcealedClipboard. That keeps the draft from clipboard
/// managers and from Universal Clipboard. Tests pass fakes of every closure and of Mail.
///
/// Logs what happened and error codes only.
struct ReplyHandoff {
    /// What a handoff did, for the window to say. None holds mail data.
    enum Outcome: Equatable, Sendable {
        /// The draft is on the clipboard, Mail opened the reply window and was asked to come
        /// to the front. The window says to press Command V there.
        case replyOpened
        /// The draft is on the clipboard and nothing else happened: Copy, or Open Reply ended
        /// before Mail was asked, such as when the window closed.
        case copied
        /// The draft is on the clipboard, but Mail does not run, so there is no reply
        /// window. Orra never opens Mail.
        case copiedMailNotRunning
        /// The draft is on the clipboard, but Mail did not make the reply, for this reason,
        /// such as `denied` while the user does not allow Orra to control Mail, or `notFound`
        /// when the message is no longer there.
        case copiedReplyFailed(MailBridgeError)
        /// The draft is empty or only white space, so nothing happened.
        case emptyDraft
        /// The pasteboard did not take the draft, so nothing else happened either.
        case notCopied
    }

    /// Puts the draft on the clipboard as it is, and says whether the pasteboard took it.
    var copy: (String) -> Bool
    /// Mail. The handoff uses only `isRunning` and `reply`.
    var mail: MailBridge
    /// Brings Mail to the front, once it opened the reply window.
    var bringMailToFront: () -> Void

    init(copy: @escaping (String) -> Bool, mail: MailBridge, bringMailToFront: @escaping () -> Void = { ReplyHandoff.bringMailToFront() }) {
        self.copy = copy
        self.mail = mail
        self.bringMailToFront = bringMailToFront
    }

    /// Open Reply in Mail, or Reply All with `all`. Only on the user's click.
    func openReply(_ draft: String, to message: MailMessageRef, all: Bool) async -> Outcome {
        let outcome = await handOver(draft, to: message, all: all)
        Logger.projects.notice("Reply handoff, open reply\(all ? " to all" : "", privacy: .public): \(String(describing: outcome), privacy: .public)")
        return outcome
    }

    /// Copy: puts the draft on the clipboard and asks nothing of Mail.
    func copyOnly(_ draft: String) -> Outcome {
        let outcome = put(draft)
        Logger.projects.notice("Reply handoff, copy: \(String(describing: outcome), privacy: .public)")
        return outcome
    }

    private func handOver(_ draft: String, to message: MailMessageRef, all: Bool) async -> Outcome {
        let copied = put(draft)
        guard copied == .copied else {
            return copied
        }
        guard mail.isRunning() else {
            return .copiedMailNotRunning
        }
        do {
            try await mail.reply(message, all)
        } catch let error as MailBridgeError {
            // mailNotRunning here means that Mail quit before it answered.
            return error == .mailNotRunning ? .copiedMailNotRunning : .copiedReplyFailed(error)
        } catch is CancellationError {
            // Cancelled before its turn on the send thread, so Mail was never asked.
            return .copied
        } catch {
            return .copiedReplyFailed(.failed(code: (error as NSError).code))
        }
        bringMailToFront()
        return .replyOpened
    }

    /// Puts the draft on the clipboard, unless it is empty.
    private func put(_ draft: String) -> Outcome {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .emptyDraft
        }
        return copy(draft) ? .copied : .notCopied
    }

    /// Brings the running Mail to the front with its own activate, never with an Apple
    /// Event, and never launches it. Only while Orra is the active app, as it is after the
    /// user's click, so a reply that took long never pulls Mail over an app the user went to
    /// meanwhile. Orra first yields its activation to Mail, which macOS asks of an app that
    /// activates another since macOS 14.
    static func bringMailToFront() {
        guard NSApplication.shared.isActive else {
            Logger.projects.info("Reply handoff: Orra is no longer in front, Mail stays where it is")
            return
        }
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
