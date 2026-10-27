import Foundation
import UniformTypeIdentifiers

/// The words of the Projects window and its menu item for the values Projects code returns,
/// mapped to localized text in one place (plan section 2.8).
nonisolated enum ProjectsWindowText {
    /// The menu item that opens the window, in the menu bar menu and the Dock menu, with the
    /// count of mail waiting for a reply, in the language of `locale`, Orra's own by default.
    /// It names the window, as the button on the Projects page of Settings does.
    static func menuTitle(replyDue: Int, locale: Locale = .interface) -> String {
        if replyDue > 0 {
            String(localized: LocalizedStringResource("Open Projects Window (\(replyDue) to Reply)", locale: locale))
        } else {
            String(localized: LocalizedStringResource("Open Projects Window", locale: locale))
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

    /// The line under the mail list while the cleanup model is not on this Mac: how far its
    /// download is, with the words of Settings, that Orra checks its files, or that it is
    /// missing. Nil once it is on this Mac.
    static func modelLine(_ status: ProjectsRuntime.ModelDownloadStatus) -> String? {
        switch status {
        case .none: nil
        case .downloading(let bytes, let total): CleanupLabels.progress(bytes: bytes, total: total)
        case .verifying: String(localized: "Checking the downloaded files…")
        case .missing: String(localized: "The cleanup model is not on this Mac yet. Download it in Projects Settings to explain mail.")
        }
    }

    /// What the scan does, or what ended its last pass.
    static func scan(_ state: ProjectsRuntime.ScanState) -> String {
        switch state {
        case .reading(saved: 0): String(localized: "Reading mail…")
        case .reading(saved: 1): String(localized: "Reading mail… 1 email read.")
        case .reading(let saved): String(localized: "Reading mail… \(saved) emails read.")
        case .mailIsSlow: String(localized: "Mail is slow to answer. Projects tries again later.")
        case .notAllowed: selection(.notAllowed)
        case .failed: String(localized: "Some mail could not be read.")
        }
    }

    /// What Explain Message Selected in Mail found, when it shows no email.
    static func selection(_ found: ProjectsRuntime.SelectedMessage) -> String {
        switch found {
        case .found: ""
        case .noMailboxChosen: String(localized: "Projects reads no mail yet. Choose its mailboxes in Settings.")
        case .mailNotRunning: String(localized: "Open Mail first.")
        case .nothingSelected: String(localized: "Select a message in Mail first.")
        case .notInChosenMailbox: String(localized: "This message is in a mailbox Projects does not read. Choose the mailbox in Settings first.")
        case .notRead(let days): String(localized: "Projects has not read this message. It reads the mail of the last \(days) days in the mailboxes you chose.")
        case .stillReading: String(localized: "Projects is still reading your mail. Try again in a moment.")
        case .notSaved: String(localized: "Projects could not save this message on this Mac. Try again later.")
        case .otherEmail: String(localized: "This message looks like an email Projects read, but its sender, recipients or date differ, so Projects cannot explain it.")
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
        case .ruleNotRemoved: String(localized: "The rule could not be removed. Try again.")
        }
    }

    /// The line under a list that shows only its newest emails.
    static func olderEmails(shown: Int, total: Int) -> String {
        String(localized: "Showing the newest \(shown) of \(total) emails.")
    }

    static func explainFailure(_ failure: ProjectsWindowModel.ExplainFailure) -> String {
        switch failure {
        case .noModel: String(localized: "The cleanup model is not on this Mac.")
        case .modelNotLoaded: String(localized: "The cleanup model could not be loaded.")
        case .tooLong: String(localized: "This email is too long to explain.")
        case .other: String(localized: "The email could not be explained. Try again.")
        }
    }

    /// The offer of a rule after two moves of the same kind: a sender rule or a domain rule.
    /// It says assign, not file or move, since Orra moves nothing in Mail.
    static func ruleOffer(_ rule: SortingCandidate.Rule, project: String) -> String {
        String(localized: "Always assign mail from \(who(rule)) to \(project)?")
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

    /// Why a file gives no text, for the project page. The page only counts the files of
    /// some reasons, see `FolderWalk.countedSkips` and `FolderIndex.countedSkips`.
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
        case .noAccess: String(localized: "Orra is not allowed to read it")
        case .unreadable: String(localized: "Could not be read")
        case .locked: String(localized: "Locked with a password")
        case .tooSlow: String(localized: "Took too long to read")
        case .noText: String(localized: "Holds no text")
        case .cancelled: String(localized: "Not read yet")
        case .waitsForRecognition: String(localized: "Waiting for text recognition")
        case .imageWithoutText: String(localized: "An image without text")
        case .overFileLimit: String(localized: "Past the number of files Projects reads")
        }
    }

    /// Why text recognition waits, for the project page, nil for the pauses that pass soon,
    /// a dictation, Live Captions and a request of the user, which the page does not show.
    static func recognitionPause(_ pause: FolderIndex.RecognitionPause) -> String? {
        switch pause {
        case .dictation, .captions, .request: nil
        case .memory: String(localized: "Text recognition waits while this Mac is low on memory.")
        case .lowPower: String(localized: "Text recognition waits while Low Power Mode is on.")
        case .heat: String(localized: "Text recognition waits until this Mac cools down.")
        }
    }

    /// A linked mailbox's name: the account's name and the mailbox's path, or On My Mac and
    /// the path, see ProjectsRuntime.mailboxName(_:).
    static func mailbox(_ name: String) -> String {
        name.hasPrefix("/") ? String(localized: "On My Mac") + name : name
    }

    // MARK: The email view

    /// Why sorting put an email where it is, for the project chip, strongest first.
    static func reason(_ reason: SortingReason) -> String {
        switch reason {
        case .thread: String(localized: "Same thread as an email in the project")
        case .rule: String(localized: "A rule you made")
        case .person: String(localized: "A person you listed for the project")
        case .domain: String(localized: "A domain you listed for the project")
        case .mailbox: String(localized: "A Mail mailbox linked to the project")
        case .peopleSeen: String(localized: "Someone in it wrote in the project before")
        case .attachment: String(localized: "An attachment has the name of a project file")
        case .words: String(localized: "It uses the project's own words")
        case .model: String(localized: "The model chose the project")
        case .listMail: String(localized: "List mail with none of the project's people")
        case .noSignal: String(localized: "Nothing pointed to a project")
        case .signalsDisagree: String(localized: "The signs point to more than one project")
        case .peopleInSeveralProjects: String(localized: "People in it wrote in more than one project")
        case .modelSaidNone: String(localized: "The model found no project")
        case .modelDisagreed: String(localized: "The model chose another project than the rules")
        case .modelAnswerInvalid: String(localized: "The model's answer was none of the projects")
        case .tooLongForModel: String(localized: "Too long for the model to sort")
        case .waitingForModel: String(localized: "Waits for the model, which sorts while this window is open")
        }
    }

    /// Why the email is where it is: the user's move, or sorting's reasons.
    static func reasons(_ email: MailStore.Listed) -> [String] {
        if email.movedByUser {
            return [String(localized: "You assigned it here")]
        }
        return email.reasons.map(reason)
    }

    /// A warning about the email, a project file or a reply, whatever found it. Each says what
    /// its check found and no more. The content checks match words, not intent, so a payment
    /// or a password is mentioned, not asked for. A quote counts as not found when Projects
    /// did not read the mail it quotes, and a sender as unknown when Projects knows neither
    /// the address nor its domain, see ContentChecks. A domain looks alike when it looks like
    /// the user's own, a project's or that of someone the user exchanged mail with, see
    /// SenderChecks. No check in code finds false urgency, a forward request or a request for
    /// confidential data yet.
    static func warning(_ warning: ProjectsWarning) -> String {
        switch warning {
        case .hiddenText: String(localized: "It holds text its reader cannot see.")
        case .instructionToAssistant: String(localized: "A line in it speaks to an assistant.")
        case .documentInstruction: String(localized: "A line in a project file speaks to an assistant.")
        case .claimsToBeOrra: String(localized: "Text in it claims to come from Orra.")
        case .lookalikeDomain: String(localized: "The sender's domain looks like a domain Projects knows, but it is a different one.")
        case .senderNameMismatch: String(localized: "The sender's name does not match the address.")
        case .forgedQuote: String(localized: "It quotes you. Projects did not find those words in the sent mail it read.")
        case .paymentChange: String(localized: "It mentions a change of where to pay.")
        case .paymentTermsChange: String(localized: "It mentions a change of amounts, dates or other terms of payment.")
        case .unknownSenderPayment: String(localized: "It mentions payment, and Projects does not know the sender.")
        case .falseUrgency: String(localized: "It pushes you to act at once.")
        case .link: String(localized: "It holds a link.")
        case .forwardRequest: String(localized: "It asks you to forward mail or files.")
        case .confidentialDataRequest: String(localized: "It asks for confidential project data.")
        case .personalDataRequest: String(localized: "It mentions personal data, such as an ID number. Check what it asks you to do.")
        case .credentialRequest: String(localized: "It mentions a password, a code or another credential. Check what it asks you to do.")
        case .recipientNotInProjectPeople: String(localized: "A reply reaches someone who is not one of the project's people.")
        case .attachmentNameSpoofing: String(localized: "An attachment may run code, or its name hides its real type.")
        }
    }

    /// What PromptHygiene took out of a text before the model read it.
    static func takenOut(_ kind: PromptHygiene.Finding.Kind) -> String {
        switch kind {
        case .hidden: String(localized: "Hidden from the reader")
        case .addressesAssistant: String(localized: "Speaks to an assistant")
        }
    }

    /// What OutputChecks found in a point or a draft.
    static func finding(_ finding: OutputChecks.Finding) -> String {
        switch finding.kind {
        case .dateWeekdayMismatch: String(localized: "Check this date, its weekday is wrong: \(finding.text)")
        case .amountWithoutSource: String(localized: "No source holds this amount: \(finding.text)")
        }
    }

    /// A flag of DraftCheck on the draft.
    static func flag(_ flag: DraftCheck.Flag) -> String {
        switch flag {
        case .output(let found): finding(found)
        case .decidesQuestion: String(localized: "The draft may decide something only you can. Compare it with Before you reply.")
        }
    }

    /// What DraftCheck took out of the draft, where its placeholder now stands.
    static func removal(_ kind: DraftCheck.Removal.Kind) -> String {
        switch kind {
        case .link: String(localized: "A link was taken out.")
        case .actionClaim: String(localized: "A sentence that claims something was done was taken out. Orra does nothing in Mail for you.")
        case .assistantVoice: String(localized: "A sentence that speaks as an assistant was taken out.")
        case .projectData: String(localized: "Project data was taken out, since the reply reaches someone outside the project.")
        case .otherProjectData: String(localized: "Data from another project's files was taken out.")
        case .otherProjectText: String(localized: "A sentence from another project's file was taken out.")
        }
    }

    /// The line under the points when one cites an excerpt of another project's file. It says
    /// that a request without those excerpts wrote the draft, see ExplainService.explain(_:),
    /// only when the explanation has a draft: none is written when no reply is due or the
    /// email is in another language, and the draft's request may fail.
    static func otherProjectsNote(_ explanation: Explanation) -> String {
        if case .checked = explanation.draft {
            return String(localized: "Some sources are files of other projects. They are only for you, and the draft was written without them.")
        }
        return String(localized: "Some sources are files of other projects. They are only for you.")
    }

    /// Why the explanation holds no draft to change.
    static func noDraft(_ draft: Explanation.Draft) -> String? {
        switch draft {
        case .checked(let result): result.draft == nil ? String(localized: "The model wrote the draft in another language, so it was held back.") : nil
        case .noReply(.sentByUser): String(localized: "No reply needed. You sent this email.")
        case .noReply(.answeredLater): String(localized: "No reply needed. You answered it later in the thread.")
        case .noReply(.listMail): String(localized: "No reply needed. It went to a list or came from a machine.")
        case .noDraft: String(localized: "This email is in a language Projects writes no drafts in.")
        case .missing: String(localized: "The model wrote no draft. Explain the email again to try once more.")
        case .expired: String(localized: "Projects removed this draft \(days(Retention.drafts)) days after its last change. Explain the email again for a new one.")
        }
    }

    /// What What it says shows when it holds no point: that the model did not finish the
    /// section, or that it named none.
    static func noPoints(_ explanation: Explanation) -> String {
        explanation.problems.contains(.missing(.points)) ? unfinished : String(localized: "The model named no points.")
    }

    /// What Before you reply shows when it holds no question. Only a section the model wrote
    /// and left empty says that nothing was found. An answer without the section, as one
    /// that stopped early, checked nothing.
    static func noQuestions(_ explanation: Explanation) -> String {
        explanation.problems.contains(.missing(.questions)) ? unfinished : String(localized: "No decisions found.")
    }

    /// A section the model's answer does not hold.
    private static var unfinished: String {
        String(localized: "The model did not finish this part. Explain the email again to try once more.")
    }

    /// The line under a point that has no source, in place of its chips. A source the
    /// prompt does not have is dropped, so a point that named only such sources has none.
    static func noSource(_ point: Explanation.Point) -> String? {
        point.sources.isEmpty ? String(localized: "No source provided") : nil
    }

    /// The notice in the explanation when Projects did not read the text of an attachment
    /// of a kind it reads, nil when it read them all. The list under Original Email says
    /// why. A kind it never reads, such as an image, gives no notice, since many emails
    /// carry one in their signature, and the list names it. The kind comes from the name
    /// and the type, since an attachment Mail has not downloaded, one in an email too large
    /// to read and one saved earlier have that state whatever their kind.
    static func unreadAttachments(_ attachments: [MailAttachment]) -> String? {
        let unread = attachments.filter { attachment in
            attachment.state != .read && attachment.state != .otherType
                && MailAttachment.format(name: attachment.name, type: attachment.type) != nil
        }.count
        switch unread {
        case 0: return nil
        case 1: return String(localized: "Projects could not read an attachment. See Original Email.")
        default: return String(localized: "Projects could not read some attachments. See Original Email.")
        }
    }

    /// Why the email view has no text to explain, nil while it has: the email was too large
    /// for Projects to read, or Retention removed its text.
    static func noText(_ email: MailStore.Listed) -> String? {
        if email.isTooLarge {
            return String(localized: "Projects did not read this email, as it is too large. Read it in Mail.")
        }
        guard !email.hasText else { return nil }
        return String(localized: "Projects removed its copy of this email's text \(days(Retention.mailText)) days after reading it. Read the email in Mail.")
    }

    /// A period of Retention in whole days.
    private static func days(_ period: TimeInterval) -> Int {
        Int(period / Retention.day)
    }

    /// Why a change, a translation or the answer check gave nothing new.
    static func note(_ note: ProjectsEmailModel.Note, for work: EmailWork) -> String {
        switch note {
        case .noModel: return String(localized: "The cleanup model is not on this Mac.")
        case .modelNotLoaded: return String(localized: "The cleanup model could not be loaded.")
        case .emptyDraft: return String(localized: "The draft is empty.")
        case .heldBack: return String(localized: "The new version came back in another language, so the draft stays as it was.")
        case .notKept: return String(localized: "The email changed meanwhile, so the new version was not kept.")
        case .tooLong, .noAnswer, .other: break
        }
        switch (work, note) {
        case (.change, .tooLong): return String(localized: "The draft or the change is too long for the model.")
        case (.change, .noAnswer): return String(localized: "The model gave no usable version. Try again.")
        case (.change, _): return String(localized: "The draft could not be changed. Try again.")
        case (.translation, .tooLong): return String(localized: "The draft is too long to translate.")
        case (.translation, _): return String(localized: "The draft could not be translated. Try again.")
        case (.answers, _): return String(localized: "The answer check did not work. Try again.")
        }
    }

    /// The request on the draft a note is about.
    nonisolated enum EmailWork {
        case change
        case translation
        case answers
    }

    /// The placeholders a new version left out of the draft before it.
    static func dropped(_ placeholders: [String], tone: Bool) -> String {
        let list = placeholders.joined(separator: ", ")
        return tone
            ? String(localized: "The new tone left out \(list). Put it back before you send.")
            : String(localized: "This version leaves out \(list). Check that your change settled it.")
    }

    /// The people outside the project whom a reply to all reaches, see
    /// DraftCheck.Result.outsideRecipients.
    static func outsideRecipients(_ addresses: [String]) -> String {
        String(localized: "A reply to all reaches people outside the project: \(addresses.joined(separator: ", "))")
    }

    /// The label of Show in My Language, which names the language: the one the user reads
    /// explanations in (decision 8).
    static func showTranslation(in language: ProjectsLanguage) -> String {
        language == .zh ? String(localized: "Show in Chinese") : String(localized: "Show in English")
    }

    /// What a change took out and put in, for VoiceOver, which does not read the highlight.
    static func changeSummary(_ segments: [ProjectsDraftDiff.Segment]) -> String {
        segments.compactMap { segment in
            switch segment.kind {
            case .same: nil
            case .removed: String(localized: "Removed: \(segment.text)")
            case .added: String(localized: "Added: \(segment.text)")
            }
        }
        .joined(separator: "\n")
    }

    /// The answer check: how many questions the email asks and how many the draft answers.
    static func answers(asked: Int, answered: Int) -> String {
        asked == 1
            ? String(localized: "They asked 1 thing, your draft answers \(answered).")
            : String(localized: "They asked \(asked) things, your draft answers \(answered).")
    }

    static func status(_ status: RevisePrompt.AnswerCheck.Status) -> String {
        switch status {
        case .answered: String(localized: "Answered")
        case .toConfirm: String(localized: "Left for you to confirm")
        case .notAnswered: String(localized: "Not answered")
        }
    }

    static func tone(_ tone: RevisePrompt.Tone) -> String {
        switch tone {
        case .formal: String(localized: "Formal")
        case .warm: String(localized: "Warm")
        case .firm: String(localized: "Firm")
        }
    }

    /// The line under the draft about saving it.
    static func save(_ note: ProjectsEmailModel.SaveNote) -> String {
        switch note {
        case .saved: String(localized: "Saved on this Mac.")
        case .notSaved: String(localized: "The draft could not be saved. Copy it before you close the window.")
        }
    }

    /// What the last handoff did, with the hint to press Command V in Mail.
    static func handoff(_ note: ProjectsEmailModel.HandoffNote) -> String {
        switch note {
        case .messageNotFound: String(localized: "Projects cannot find this email in Mail now, so the draft is only on the clipboard. Reply to it in Mail and press ⌘V.")
        case .outcome(.replyOpened): String(localized: "Mail opened the reply, and the draft is on the clipboard. Press ⌘V in the reply window.")
        case .outcome(.copied): String(localized: "The draft is on the clipboard.")
        case .outcome(.copiedMailNotRunning): String(localized: "Mail is not open, so the draft is only on the clipboard.")
        case .outcome(.copiedReplyFailed(.timedOut)): String(localized: "Mail is slow to answer. The reply may still open. The draft is on the clipboard.")
        case .outcome(.copiedReplyFailed(.denied)), .outcome(.copiedReplyFailed(.notAsked)): String(localized: "Orra may not control Mail, so the draft is only on the clipboard. Allow it in Settings.")
        case .outcome(.copiedReplyFailed(.notFound)): String(localized: "Mail no longer has this email. The draft is on the clipboard.")
        case .outcome(.copiedReplyFailed): String(localized: "Mail did not open the reply. The draft is on the clipboard.")
        case .outcome(.emptyDraft): String(localized: "The draft is empty.")
        case .outcome(.notCopied): String(localized: "The draft could not be copied. Try again.")
        }
    }

    /// The label of a source chip.
    static func source(_ source: ProjectsEmailModel.Source) -> String {
        switch source {
        case .thisEmail:
            return String(localized: "This email")
        case .mail(_, let sender?, let date?):
            let day = date.formatted(.dateTime.month(.abbreviated).day().locale(.interface))
            return String(localized: "\(sender), \(day)")
        case .mail:
            return String(localized: "An earlier email")
        case .file(let chunk):
            return file(chunk.file.lastPathComponent, at: place(of: chunk))
        case .otherProjectFile(let chunk, let project):
            let file = Self.source(.file(chunk))
            return String(
                localized: "\(file) (\(project ?? String(localized: "another project")))",
                comment: "A file of another project with that project, such as floor-plan.pdf, page 1 (Kiln studio)")
        case .attachment(let name, _):
            return name
        }
    }

    /// The label of another project's file in two parts, the file and then the project in
    /// its brackets, as `source(_:)` writes them, so the chip can shorten the file's name and
    /// keep the project's. Nil for any other source, and when a translation puts the file
    /// elsewhere than first.
    static func sourceParts(_ source: ProjectsEmailModel.Source) -> (file: String, project: String)? {
        guard case .otherProjectFile(let chunk, _) = source else { return nil }
        let file = Self.source(.file(chunk))
        let whole = Self.source(source)
        guard whole.hasPrefix(file), whole.count > file.count else { return nil }
        return (file, String(whole.dropFirst(file.count)))
    }

    /// Where an excerpt lies in its file: a page of a PDF, a slide of a deck or a sheet of a
    /// workbook. Every label of an excerpt names its place through `place(of:)`, so a slide
    /// or a sheet never reads as a page.
    nonisolated enum Place: Hashable {
        case page(Int)
        case slide(Int)
        case sheet(String)
    }

    /// The place of an excerpt, nil for a file without pages, such as a docx. A chunk's page
    /// is a slide in a pptx or ppsx.
    static func place(of chunk: TextChunker.Chunk) -> Place? {
        if let sheet = chunk.sheet, !sheet.isEmpty { return .sheet(sheet) }
        guard let page = chunk.page else { return nil }
        return ["pptx", "ppsx"].contains(chunk.file.pathExtension.lowercased()) ? .slide(page) : .page(page)
    }

    /// A place on a line of its own, such as Page 2, Slide 3 or Sheet “Budget”.
    static func place(_ place: Place) -> String {
        switch place {
        case .page(let page): String(localized: "Page \(page)")
        case .slide(let slide): String(localized: "Slide \(slide)")
        case .sheet(let sheet): String(localized: "Sheet “\(sheet)”")
        }
    }

    /// A file's name with the place of an excerpt in it, such as schedule.pdf, page 2.
    static func file(_ name: String, at place: Place?) -> String {
        switch place {
        case nil: name
        case .page(let page)?: String(localized: "\(name), page \(page)")
        case .slide(let slide)?: String(localized: "\(name), slide \(slide)")
        case .sheet(let sheet)?: String(localized: "\(name), sheet “\(sheet)”")
        }
    }

    /// The note under the place of an excerpt whose text was recognized in an image or on a
    /// scanned page, nil for any other.
    static func recognized(_ chunk: TextChunker.Chunk) -> String? {
        chunk.recognized == true ? String(localized: "Recognized from an image, so words and numbers may be wrong.") : nil
    }

    /// What VoiceOver reads for a source's chip: its text, for an attachment that it is
    /// one, since its chip may show the name of a project file too, and for another
    /// project's file the project it is from.
    static func sourceLabel(_ source: ProjectsEmailModel.Source) -> String {
        switch source {
        case .attachment(let name, _):
            return String(localized: "Attachment \(name)")
        case .otherProjectFile(let chunk, let project?):
            return String(localized: "\(sourceLabel(.file(chunk))), from the project \(project)")
        case .otherProjectFile(let chunk, nil):
            return String(localized: "\(sourceLabel(.file(chunk))), from another project")
        case .thisEmail, .mail, .file:
            return Self.source(source)
        }
    }

    /// The line under a file's name in the popover of its excerpt, with its page, slide or
    /// sheet. The explanation keeps the excerpt as the index had it, with any lines that the
    /// hygiene took out before the model read it, so the popover calls it saved.
    static func savedExcerpt(_ chunk: TextChunker.Chunk) -> String {
        switch place(of: chunk) {
        case nil: String(localized: "Saved excerpt")
        case .page(let page)?: String(localized: "Saved excerpt, page \(page)")
        case .slide(let slide)?: String(localized: "Saved excerpt, slide \(slide)")
        case .sheet(let sheet)?: String(localized: "Saved excerpt, sheet “\(sheet)”")
        }
    }

    // MARK: The project files of an explanation

    /// The heading of the folded list of the project files an explanation gave the model,
    /// with their count.
    static func projectFiles(_ count: Int) -> String {
        String(localized: "Project Files for This Explanation (\(count))")
    }

    /// What the list says when the explanation gave the model no excerpt of a project file,
    /// for an email in a project or in none. Assigning an email in no project takes its
    /// explanation away, see MailStore.move(_:to:), and the window then shows the next email
    /// of its list, see ProjectsWindowModel.move(_:to:), so the line says to explain the
    /// email in its project's list.
    static func noProjectFiles(inProject: Bool) -> String {
        inProject
            ? String(localized: "No project file excerpts were included in this explanation. The project's folders may hold no file Projects reads yet, or a long email or thread left no room for them.")
            : String(localized: "No project file excerpts were included in this explanation. Assign the email to a project, then click Explain in that project's list to include the project's files.")
    }

    /// Whether a point under What it says names one of a file's excerpts as its source. The
    /// words say cited, never used, since a citation does not prove what the model relied on.
    static func citation(_ isCited: Bool) -> String {
        isCited ? String(localized: "Cited in explanation") : String(localized: "Not cited in explanation")
    }

    /// Why a file was in the prompt. Nil for an explanation saved before Orra 0.6.1, and for
    /// a reason this Orra does not know.
    static func fileReason(_ reason: ExplainPrompt.FileOrigin.Reason?) -> String? {
        switch reason {
        case .match: return String(localized: "Found by search")
        case .newest: return String(localized: "One of the project's newest files, added because search found few matches")
        case .chosen: return String(localized: "Chosen by you")
        case nil: return nil
        }
    }

    /// The line of a file from the folders of another project than the email's: that
    /// project's name, or that it is another project once the project is gone.
    static func otherProject(_ name: String?) -> String {
        guard let name else { return String(localized: "From the folders of another project") }
        return String(localized: "From the folders of \(name)")
    }

    /// A file's folder: the project folder that holds it and the folders inside it down to
    /// the file, joined with "/", or for a file in none of them, the folder it is in with ~
    /// for the home folder.
    static func folder(_ place: ProjectsEmailFiles.Place) -> String {
        switch place {
        case .inFolder(let name, let path), .unavailable(let name, let path):
            ([name] + path).joined(separator: "/")
        case .outside(let folder):
            (folder.path as NSString).abbreviatingWithTildeInPath
        }
    }

    /// The line under a file's folder when the file is not in an available folder of its
    /// project now. A folder that is not available, such as one on a disk that is not
    /// connected, is still the project's.
    static func placeNote(_ place: ProjectsEmailFiles.Place) -> String? {
        switch place {
        case .inFolder: nil
        case .unavailable: String(localized: "Its project folder is not available now")
        case .outside: String(localized: "Not in the project's folders now")
        }
    }

    /// The chip of a saved excerpt in the list of an explanation's files: its page, slide or
    /// sheet, as `place(_:)` names it, or Saved Excerpt for a file without them. With its
    /// number when the file has several excerpts of that place, or several without one, see
    /// ProjectsEmailFiles.File.chipNumbers, such as Page 4, Saved Excerpt 2.
    static func excerptChip(_ chunk: TextChunker.Chunk, number: Int?) -> String {
        guard let place = Self.place(of: chunk) else { return savedExcerptChip(number) }
        let name = Self.place(place)
        guard number != nil else { return name }
        return String(localized: "\(name), \(savedExcerptChip(number))")
    }

    /// What VoiceOver reads for the chip of a saved excerpt: the file with its page, slide or
    /// sheet, as for the file's chip under a point, and the excerpt when the chip names it.
    static func excerptChipLabel(_ chunk: TextChunker.Chunk, number: Int?) -> String {
        let file = sourceLabel(.file(chunk))
        guard place(of: chunk) == nil || number != nil else { return file }
        return String(localized: "\(file), \(savedExcerptChip(number))")
    }

    /// Saved Excerpt, with its number among the excerpts whose chips would read the same
    /// without it.
    private static func savedExcerptChip(_ number: Int?) -> String {
        guard let number else { return String(localized: "Saved Excerpt") }
        return String(localized: "Saved Excerpt \(number)")
    }

    /// An attachment's kind as Finder names it, such as PDF document, and its size, in the
    /// language of `locale`.
    static func attachmentKind(_ attachment: MailAttachment, locale: Locale = .interface) -> String {
        let fileExtension = MIMEMessage.fileExtension(of: attachment.name)
        let type = [UTType(filenameExtension: fileExtension), UTType(mimeType: attachment.type)]
            .lazy.compactMap { $0 }.first { !$0.isDynamic && $0.localizedDescription != nil }
        let kind = type?.localizedDescription ?? attachment.type
        guard let size = attachment.size else { return kind }
        let bytes = Int64(size).formatted(ByteCountFormatStyle(style: .file, allowedUnits: .all, spellsOutZero: false, includesActualByteCount: false, locale: locale))
        return String(localized: LocalizedStringResource("\(kind), \(bytes)", locale: locale))
    }

    /// An attachment's kind and size, and whether Projects read its text, on one line.
    static func attachmentLine(_ attachment: MailAttachment) -> String {
        String(localized: "\(attachmentKind(attachment)). \(attachmentState(attachment))")
    }

    /// Whether Projects read an attachment's text, or why not.
    static func attachmentState(_ attachment: MailAttachment) -> String {
        switch attachment.state {
        case .read where attachment.isCut: String(localized: "Projects read the start of its text.")
        case .read: String(localized: "Projects read its text.")
        case .notDownloaded: String(localized: "Mail has not downloaded it, so Projects knows only its name.")
        case .tooLarge: String(localized: "Projects did not read it, as it is over 10 MB.")
        case .emailTooLarge: String(localized: "Projects did not read it, as the email is too large.")
        case .otherType: String(localized: "Projects does not read this kind of file.")
        case .unreadable: String(localized: "Projects could not read it.")
        case .noText: String(localized: "Projects found no text in it.")
        case .notRead: String(localized: "Projects did not read it.")
        case .savedEarlier: String(localized: "Projects saved this email before it read attachments.")
        }
    }

    /// The deadline mark: today, the weekday within the next 6 days, or the day. Nil once the
    /// day has passed, such as in a window left open past midnight.
    static func deadline(_ date: Date, now: Date, calendar: Calendar = .current) -> String? {
        guard let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day, days >= 0 else {
            return nil
        }
        if days == 0 {
            return String(localized: "Deadline today")
        }
        var format = Date.FormatStyle.dateTime.locale(.interface)
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        let day = days < 7 ? date.formatted(format.weekday(.wide)) : date.formatted(format.month(.abbreviated).day())
        return String(localized: "Deadline \(day)")
    }

    /// Why an added folder is not indexed.
    static func refusal(_ refusal: FolderWalk.Refusal) -> String {
        switch refusal {
        case .notAFolder: String(localized: "This folder is missing or cannot be read.")
        case .home: String(localized: "Projects never reads your home folder.")
        case .volumeRoot: String(localized: "Projects never reads a whole disk.")
        case .mailData: String(localized: "Projects never reads Mail's local data files.")
        }
    }

    // MARK: Choosing files for an email

    /// The line under Explain or Explain Again about what the next explanation uses.
    static func choiceNote(_ note: ProjectsEmailModel.ChoiceNote) -> String {
        switch note {
        case .explainUses(1): String(localized: "Explain uses the file you chose.")
        case .explainUses(let count): String(localized: "Explain uses the \(count) files you chose.")
        case .explainAgainUses(1): String(localized: "Explain Again uses the file you chose.")
        case .explainAgainUses(let count): String(localized: "Explain Again uses the \(count) files you chose.")
        case .explainAgainGoesBack: String(localized: "Explain Again goes back to the automatic selection.")
        }
    }

    /// Why a chosen file gave the explanation nothing, for its row in the list of the
    /// explanation's files.
    static func chosenMissing(_ missing: Explanation.ChosenFile.Missing) -> String {
        switch missing {
        case .notInIndex: String(localized: "Projects had not read it, so the model did not get it.")
        case .leftOut: String(localized: "Left out, as the email and its sources were too long")
        }
    }

    /// How many files the sheet has ticked.
    static func chosenCount(_ count: Int) -> String {
        count == 0
            ? String(localized: "None chosen. Orra finds the files itself.")
            : String(localized: "\(count) chosen, up to \(ExplainPrompt.chosenFileLimit)")
    }

    /// What a file of the index gives an explanation.
    static func reading(_ reading: FolderIndex.ListedFile.Reading) -> String {
        switch reading {
        case .text: String(localized: "With text")
        case .recognizedText: String(localized: "Recognized text")
        case .waitsForRecognition: String(localized: "Waiting for text recognition")
        case .nameOnly: String(localized: "Name only")
        }
    }

    /// A file's kind as Finder names it, such as PDF document, with a capital first letter
    /// where macOS gives a lowercase one, such as text, or its extension in capitals when
    /// macOS has no name for it.
    static func fileKind(_ file: URL) -> String {
        let fileExtension = file.pathExtension
        if let type = UTType(filenameExtension: fileExtension), !type.isDynamic, let name = type.localizedDescription, let first = name.first {
            return first.uppercased() + name.dropFirst()
        }
        return fileExtension.uppercased()
    }

    /// The third line of a file in the sheet: its kind, what it gives an explanation, when
    /// it changed, and whether the saved explanation holds it.
    static func listedFile(kind: String, reading: FolderIndex.ListedFile.Reading?, modified: Date?, inExplanation: Bool) -> String {
        var parts = [kind].filter { !$0.isEmpty }
        if let reading {
            parts.append(Self.reading(reading))
        }
        if let modified {
            let day = modified.formatted(.dateTime.year().month(.abbreviated).day().locale(.interface))
            parts.append(String(localized: "Changed \(day)"))
        }
        if inExplanation {
            parts.append(String(localized: "In this explanation"))
        }
        guard let first = parts.first else { return "" }
        return parts.dropFirst().reduce(first) { line, part in String(localized: "\(line), \(part)") }
    }

    /// The line under a section that shows only its newest files.
    static func moreFiles(shown: Int, total: Int, searching: Bool) -> String {
        searching
            ? String(localized: "Showing the newest \(shown) of \(total) files that match.")
            : String(localized: "Showing the newest \(shown) of \(total) files. Search by name to find the others.")
    }

    /// The title of the section of the email's project in the sheet.
    static func emailsProject(_ name: String) -> String {
        String(localized: "\(name) (This Email's Project)")
    }

    /// What VoiceOver reads at the end of a file's row: the project whose folders hold it.
    static func inProject(_ name: String) -> String {
        String(localized: "In \(name)")
    }

    /// The line of the sheet's search when no file name matches.
    static func noFileNameMatches(_ text: String) -> String {
        String(localized: "No file name matches “\(text)”.")
    }

    static func addFolder(to project: String) -> String {
        String(localized: "Add a Folder to “\(project)”…")
    }

    static func addItsFolder(to project: String) -> String {
        String(localized: "Add Its Folder to “\(project)”…")
    }

    /// The message of the open panel that adds a folder to a project from the sheet.
    static func folderPanelMessage(_ project: String) -> String {
        String(localized: "Projects reads the files in the folder you choose for all mail of “\(project)”, and never changes them.")
    }

    /// A line of the sheet after a tick, a drop, an added folder or a save.
    static func choiceNotice(_ line: ProjectsFileChoice.Notice) -> String {
        switch line {
        case .limit: String(localized: "You can choose up to \(ExplainPrompt.chosenFileLimit) files for an email.")
        case .chosen(let name): String(localized: "“\(name)” is chosen.")
        case .notRead(let name): String(localized: "Projects has not read “\(name)”. It may be new, too large or not on this Mac. The project's page lists the files it skipped.")
        case .outside(let file): String(localized: "“\(file.lastPathComponent)” is not in a folder of your projects. Projects reads only the folders you add.")
        case .reading(let name): String(localized: "Projects is reading the folder. “\(name)” is chosen once it is read.")
        case .notInFolder(let name): String(localized: "The folder you added does not hold “\(name)”.")
        case .refused(let found): refusal(found)
        case .projectNotSaved: notice(.projectNotSaved)
        case .notSaved: String(localized: "The choice could not be saved. Try again.")
        }
    }
}
