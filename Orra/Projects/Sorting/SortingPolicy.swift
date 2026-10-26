import Foundation

/// How sure sorting is of an email's project.
nonisolated enum SortingLevel: String, Sendable, Codable, CaseIterable {
    /// Filed without a mark, still shown and reversible: the same thread, a rule, person or
    /// domain the user set, or a linked Mail mailbox.
    case sure
    /// Filed with a "suggested" mark: the model chose the project, and agreed with the
    /// rules when they pointed to one.
    case likely
    /// In Needs a Project. No project files are used for it until the user picks one.
    case unsure
    /// In Set Aside: list mail with no project people. Only the rules set mail aside.
    case setAside
}

/// Why sorting decided as it did, for the project chip.
nonisolated enum SortingReason: String, Sendable, Codable, CaseIterable {
    /// The same thread as an email in the project.
    case thread
    /// A rule the user made.
    case rule
    /// A person the user listed for the project.
    case person
    /// A domain the user listed for the project.
    case domain
    /// A Mail mailbox linked to the project.
    case mailbox
    /// Someone in the email wrote in the project before.
    case peopleSeen
    /// An attachment has the name of a project file.
    case attachment
    /// The email holds the project's own words.
    case words
    /// The model chose the project.
    case model
    /// List mail with no project people.
    case listMail
    /// No rule pointed to a project.
    case noSignal
    /// The rules pointed to more than one project.
    case signalsDisagree
    /// People in the email wrote in more than one project before.
    case peopleInSeveralProjects
    /// The model found no project.
    case modelSaidNone
    /// The model chose another project than the rules.
    case modelDisagreed
    /// The model's answer was not one of the choices.
    case modelAnswerInvalid
    /// The email does not fit into the model's prompt, so the model was never asked.
    case tooLongForModel
    /// The rules leave it to the model, which has not answered yet.
    case waitingForModel
}

/// Where sorting put an email, and why.
nonisolated struct SortingDecision: Sendable, Equatable, Codable {
    /// The project, or nil for Needs a Project and Set Aside.
    var project: UUID?
    var level: SortingLevel
    /// The reasons, strongest first. Never empty.
    var reasons: [SortingReason]

    /// The main reason, for the project chip.
    var reason: SortingReason {
        reasons.first ?? .noSignal
    }

    /// Whether the decision changes once the model answers. The window asks the model only
    /// while it is open, so with it closed such mail waits in Needs a Project.
    var waitsForModel: Bool {
        reasons.contains(.waitingForModel)
    }

    /// Whether the model's answer made the decision: a project it chose, or Needs a Project
    /// after its none, another choice than the rules, an answer that was none of the
    /// choices, or a prompt too long for it.
    var restsOnModel: Bool {
        reasons.contains { [SortingReason.model, .modelSaidNone, .modelDisagreed, .modelAnswerInvalid, .tooLongForModel].contains($0) }
    }
}

/// Rules first, the model as tie breaker (plan section 8, approved 2026-10-19).
///
/// - A thread (unless the user moved the message it answers) is sure, and the model is not
///   asked. A setting of the user that names the same project is a second reason, so the
///   reply counts as mail the user stands behind, see MailStore.peopleSeen.
/// - So is the user's own setting that names one project. The most exact kind that matches
///   decides: a rule the user made or a linked Mail mailbox, then a person the user listed,
///   then a domain. When the kind that decides names several projects, only those
///   projects stay in the running.
/// - Only the rules set mail aside: list mail with no project people, no setting of the
///   user and no thread.
/// - People seen before, an attachment name, the project's words, or a thread whose
///   message the user moved, vote. A project that has the only vote is likely, and the
///   model must agree before the mail is filed there.
/// - When the rules have no single project, the model may choose one of the top
///   candidates.
/// - The model's "none" sends the mail to Needs a Project, never out of the project.
///
/// On the synthetic set of phase 0 the prototype of this policy (match.py) filed 91 of 105
/// mails right, sent 10 to Needs a Project and filed 4 wrong. Rules alone gave 85, 17 and
/// 3.
nonisolated enum SortingPolicy {
    /// Whether the decision needs the model's answer.
    static func needsModel(_ signals: SortingSignals) -> Bool {
        decide(signals, model: nil).waitsForModel
    }

    /// Whether sorting again asks the model about an email decided as `before`, after a
    /// change of the projects in `changed`: when the rules leave it to the model and the
    /// model did not make `before`, when the prompt is not the one the model answered, or
    /// when the project the model chose is no longer a choice or lost a signal that pointed
    /// to it. Otherwise the change cannot alter the model's answer, and the same prompt
    /// asked again could get another one, see ProjectsModelQueue.
    /// - Parameter samePrompt: whether the prompt is the one the model answered for
    ///   `before`, nil when that is not known. Then a changed project among the candidates
    ///   the prompt shows stands for a change of the prompt, and a change that takes a
    ///   project out of them asks nothing.
    static func asksAgain(_ signals: SortingSignals, before: SortingDecision?, changed: Set<UUID>, samePrompt: Bool? = nil) -> Bool {
        guard needsModel(signals) else { return false }
        guard let before, before.restsOnModel else { return true }
        if let samePrompt {
            if !samePrompt {
                return true
            }
        } else if !changed.isDisjoint(with: signals.topCandidates) {
            return true
        }
        guard let project = before.project else { return false }
        let had = Set(before.reasons).subtracting([.model])
        return !choices(signals).contains(project) || !had.isSubset(of: Set(support(project, signals)))
    }

    /// The decision for an email. `model` is the model's answer to the SortingPrompt for
    /// these signals, or nil when the model was not asked.
    static func decide(_ signals: SortingSignals, model: SortingPrompt.Answer?) -> SortingDecision {
        let top = signals.topCandidates
        switch outcome(signals) {
        case .decided(let decision):
            return decision
        case .likely(let project):
            switch model {
            case nil:
                return unsure([.waitingForModel])
            case .project(let chosen)? where chosen == project:
                return SortingDecision(project: project, level: .likely, reasons: support(project, signals) + [.model])
            case .project(let chosen)? where top.contains(chosen):
                return unsure([.modelDisagreed])
            case .noProject?:
                return unsure([.modelSaidNone])
            case .project?, .invalid?:
                return unsure([.modelAnswerInvalid])
            }
        case .open(let why, let among):
            let choices = Self.choices(among: among, top: top)
            guard !choices.isEmpty else { return unsure([why]) }
            switch model {
            case nil:
                return unsure([.waitingForModel, why])
            case .project(let chosen)? where choices.contains(chosen):
                return SortingDecision(project: chosen, level: .likely, reasons: support(chosen, signals) + [.model])
            case .project(let chosen)? where top.contains(chosen):
                return unsure([.modelDisagreed, why])
            case .noProject?:
                return unsure([.modelSaidNone, why])
            case .project?, .invalid?:
                return unsure([.modelAnswerInvalid, why])
            }
        }
    }

    /// What the rules say on their own.
    private enum Outcome {
        /// Sure, set aside or unsure, and the model is not asked.
        case decided(SortingDecision)
        /// One project has the only vote, and the model must agree.
        case likely(UUID)
        /// No single project, and the model may choose one of the top candidates, or of
        /// those among them in `among` when it is not empty.
        case open(SortingReason, among: Set<UUID>)
    }

    /// The rules in the order of match.py.
    private static func outcome(_ signals: SortingSignals) -> Outcome {
        if let thread = signals.thread, !signals.threadMovedByUser {
            return .decided(SortingDecision(project: thread, level: .sure, reasons: [.thread] + settings(thread, signals)))
        }
        let ruled = userSettings(signals)
        if ruled.count == 1, let project = ruled.first {
            return .decided(SortingDecision(project: project, level: .sure, reasons: settings(project, signals)))
        }
        if ruled.isEmpty, signals.thread == nil, signals.listMail != nil, !signals.hasProjectPeople {
            return .decided(SortingDecision(project: nil, level: .setAside, reasons: [.listMail]))
        }
        // When the user's settings name several projects, votes for other projects do not
        // count.
        func counts(_ project: UUID) -> Bool {
            ruled.isEmpty || ruled.contains(project)
        }
        var votes: [UUID] = []
        if let thread = signals.thread, counts(thread) {
            votes.append(thread)
        }
        let seen = signals.peopleSeen.keys.filter(counts)
        if seen.count > 1 {
            return .open(.peopleInSeveralProjects, among: ruled)
        }
        if let project = seen.first {
            votes.append(project)
        }
        let attachments = signals.attachments.filter(counts)
        if attachments.count == 1, let project = attachments.first {
            votes.append(project)
        }
        if let project = wordsVote(signals.words.filter { counts($0.key) }) {
            votes.append(project)
        }
        switch Set(votes).count {
        case 0:
            return .open(ruled.isEmpty ? .noSignal : .signalsDisagree, among: ruled)
        case 1:
            // The model sees only the top candidates, so it could never agree with a vote
            // outside them.
            guard signals.topCandidates.contains(votes[0]) else {
                return .decided(unsure([.signalsDisagree]))
            }
            return .likely(votes[0])
        default:
            return .open(.signalsDisagree, among: ruled)
        }
    }

    /// The projects the model may choose for these signals, empty when the rules decide
    /// alone.
    private static func choices(_ signals: SortingSignals) -> [UUID] {
        switch outcome(signals) {
        case .decided: []
        case .likely(let project): [project]
        case .open(_, let among): choices(among: among, top: signals.topCandidates)
        }
    }

    /// The top candidates the model may choose when no single project has the vote: those
    /// among `among` when it is not empty.
    private static func choices(among: Set<UUID>, top: [UUID]) -> [UUID] {
        among.isEmpty ? top : top.filter(among.contains)
    }

    /// The user's own settings that name the project, for the chip: a rule, person or
    /// domain, then a linked mailbox.
    private static func settings(_ project: UUID, _ signals: SortingSignals) -> [SortingReason] {
        let reasons: [SortingReason?] = [signals.rules[project], signals.mailboxes.contains(project) ? .mailbox : nil]
        return reasons.compactMap { $0 }
    }

    /// The projects named by the most exact kind of the user's own settings that matches: a
    /// rule or a linked mailbox, then a person, then a domain. Empty when none matches.
    private static func userSettings(_ signals: SortingSignals) -> Set<UUID> {
        let rules = signals.rules.filter { $0.value == .rule }.keys
        let tiers: [Set<UUID>] = [
            Set(rules).union(signals.mailboxes),
            Set(signals.rules.filter { $0.value == .person }.keys),
            Set(signals.rules.filter { $0.value == .domain }.keys),
        ]
        return tiers.first { !$0.isEmpty } ?? []
    }

    /// The project whose words the email holds, when no other project's words come within
    /// two of it.
    private static func wordsVote(_ words: [UUID: [String]]) -> UUID? {
        let counts = words.map { (project: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
        guard let best = counts.first else { return nil }
        if counts.count == 1 || best.count >= counts[1].count + 2 {
            return best.project
        }
        return nil
    }

    /// Every signal that points to the project, strongest first, for the chip.
    private static func support(_ project: UUID, _ signals: SortingSignals) -> [SortingReason] {
        var reasons: [SortingReason] = []
        if signals.thread == project {
            reasons.append(.thread)
        }
        if let rule = signals.rules[project] {
            reasons.append(rule)
        }
        if signals.mailboxes.contains(project) {
            reasons.append(.mailbox)
        }
        if signals.peopleSeen[project] != nil {
            reasons.append(.peopleSeen)
        }
        if signals.attachments.contains(project) {
            reasons.append(.attachment)
        }
        if signals.words[project] != nil {
            reasons.append(.words)
        }
        return reasons
    }

    private static func unsure(_ reasons: [SortingReason]) -> SortingDecision {
        SortingDecision(project: nil, level: .unsure, reasons: reasons)
    }
}
