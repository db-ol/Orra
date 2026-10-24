import CryptoKit
import Foundation

/// Suggested Projects: groups the mail in Needs a Project into projects the user may
/// create, in code. ProjectSuggestionService then has the model name each group, and the
/// user creates a project from one only with a click.
///
/// - Threads stay together, by the root the store found for each email.
/// - The other side of a thread is the sender of the mail the user received and the
///   recipients of the mail the user sent, as for sorting. Each person there gives an
///   anchor: the domain of their address, or their address alone at a shared mail provider
///   such as gmail.com or qq.com. People at the user's own domains are colleagues, who
///   write about every project, so they give none.
/// - A Mail mailbox the user files one party's mail into gives an anchor too, see
///   `Grouping.projectMailboxes(total:)`. The inbox, the sent mailbox or an archive, where
///   many people write who could each be a project, gives none.
/// - Each thread goes to such a mailbox, else to the anchor of its own with the most mail.
///   A group too small to suggest joins the group it shares a thread with, as a distributor
///   who writes to a client joins the client's group.
/// - Threads left over are grouped by a word their subjects share, such as the name of an
///   event, when at least `minimumWordThreads` share it.
/// - New Project is prefilled from a group with its domain or mailbox and the people who
///   write in it: at its domain, or in none of the other groups. `takes` counts the emails
///   sorting would then file in it by the rules alone, see `takes(of:in:existing:ownAddresses:)`.
///
/// Mail the user moved, list mail and anything an existing project names already are left
/// out, and so are groups that would take fewer than `minimumMails`. An anchor the user
/// dismissed anchors nothing, so its threads go to their next anchor, and a thread with no
/// other one is left out. Nothing is suggested before the user's own addresses are known,
/// since their own mail would then look like one large group.
nonisolated enum ProjectSuggestions {
    /// A person in a mail header.
    nonisolated struct Person: Sendable, Hashable {
        var name: String = ""
        var address: String
    }

    /// One email of Needs a Project as the grouping reads it.
    nonisolated struct Mail: Sendable, Equatable {
        /// The Message-ID, without angle brackets.
        var messageID: String
        var date: Date
        var sender: Person
        /// The To and Cc.
        var recipients: [Person] = []
        var subject: String
        /// The email's own text, as far as the store read it, for the model's prompt.
        var text: String = ""
        var attachmentNames: [String] = []
        /// The Mail mailbox it is in, in the form of `SortingInput.mailbox`.
        var mailbox: String? = nil
        var inReplyTo: [String] = []
        var references: [String] = []
        /// The Message-ID of the root of its thread, see MailThreads.
        var threadRoot: String
        var list = ListMail()
        /// Whether the user moved it to Needs a Project, so sorting never files it again.
        var movedByUser = false
    }

    /// What holds a group together.
    nonisolated enum Anchor: Sendable, Hashable {
        /// A Mail mailbox, in the form of `SortingInput.mailbox`.
        case mailbox(String)
        /// A domain, such as harbor.example.
        case domain(String)
        /// One address at a shared mail provider.
        case person(String)
        /// A word the subjects share.
        case word(String)

        /// The anchor in one string, unique among anchors.
        var key: String {
            switch self {
            case .mailbox(let name): "mailbox:" + name
            case .domain(let domain): "domain:" + domain
            case .person(let address): "person:" + address
            case .word(let word): "word:" + word
            }
        }
    }

    /// A group of mail that could be a project, with what New Project is prefilled with.
    nonisolated struct Group: Sendable, Equatable, Identifiable {
        var anchor: Anchor
        /// The people to list, those with the most mail first.
        var people: [Person]
        var domains: [String]
        /// The mailbox to link, in the form of `SortingInput.mailbox`.
        var mailbox: String?
        /// Its emails, newest first.
        var messageIDs: [String]
        /// The emails sorting would file in a project made from it by the rules alone,
        /// oldest first.
        var takes: [String]
        /// The language most of its emails are in.
        var language: ProjectsLanguage

        var id: String {
            anchor.key
        }

        /// The name it shows until the model names it, or when the model cannot: its
        /// domain, the person's name, the mailbox's last part or the word.
        var fallbackName: String {
            switch anchor {
            case .domain(let domain): domain
            case .person(let address): people.first { $0.address == address }.map { $0.name.isEmpty ? $0.address : $0.name } ?? address
            case .mailbox(let name): name.split(separator: "/").last.map(String.init) ?? name
            case .word(let word): word
            }
        }
    }

    /// The fewest emails a suggestion would take, and the fewest emails of a group.
    static let minimumMails = 3
    /// The fewest threads whose subjects share a word for a group of that word.
    static let minimumWordThreads = 3
    /// The most suggestions shown.
    static let maximumSuggestions = 8
    /// The most groups weighed for what they would take, those with the most emails. More
    /// than are shown, since the model may say some are no project.
    static let maximumGroups = 3 * maximumSuggestions
    /// The most people New Project is prefilled with.
    static let maximumPeople = 8
    /// A mailbox anchors a group only while it holds less than this share of the mail.
    static let maximumMailboxShare = 0.5
    /// How many anchors of a mailbox's threads must carry `mailboxCoverage` of its mail for
    /// it to anchor a group, see `Grouping.projectMailboxes(total:)`.
    static let mailboxParties = 3
    static let mailboxCoverage = 0.8
    /// The To and Cc addresses read of an email, as many as sorting reads.
    static let maximumRecipients = SortingService.maximumRecipients

    /// The key a dismissal of the group is kept under: the SHA-256 of its anchor in hex, so
    /// the project list keeps no address or word of the mail in plain text. A guessed
    /// address can still be checked against it.
    static func dismissalKey(_ anchor: Anchor) -> String {
        SHA256.hash(data: Data(anchor.key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Grouping

    /// The groups to suggest, those that would take the most emails first. Of the
    /// `maximumGroups` groups with the most emails, those that would take at least
    /// `minimumMails`. `projects` are the user's projects, `dismissed` the keys of the
    /// suggestions the user dismissed, see `dismissalKey(_:)`. Off the main actor, since it
    /// reads every email of Needs a Project.
    @concurrent
    static func groups(in mail: [Mail], ownAddresses: [String], projects: [SortingCandidate], dismissed: Set<String>) async -> [Group] {
        let own = Set(ownAddresses.compactMap(ProjectsAddress.normalized))
        guard !own.isEmpty else { return [] }
        let mail = normalized(mail)
        let found = Grouping(mail: mail, own: own, projects: projects, dismissed: dismissed).groups
        // What a group would take runs sorting's rules over its threads, so only the largest
        // groups are weighed.
        let largest = found
            .sorted { ($0.messageIDs.count, $1.id) > ($1.messageIDs.count, $0.id) }
            .prefix(maximumGroups)
        let index = MailIndex(mail.filter { !$0.movedByUser }, own: own)
        var groups: [Group] = []
        for var group in largest {
            group.takes = await takes(of: group, in: index, existing: projects, ownAddresses: own.sorted())
            if group.takes.count >= minimumMails {
                groups.append(group)
            }
        }
        return groups.sorted { ($0.takes.count, $0.messageIDs.count, $1.id) > ($1.takes.count, $1.messageIDs.count, $0.id) }
    }

    /// The mail with every address in its one form, see ProjectsAddress.normalized(_:), so
    /// each address is read once. A sender without one keeps an empty address. A recipient
    /// without one, or past the `maximumRecipients` that sorting reads, is left out.
    static func normalized(_ mail: [Mail]) -> [Mail] {
        mail.map { email in
            var email = email
            email.sender.address = ProjectsAddress.normalized(email.sender.address) ?? ""
            email.recipients = email.recipients.prefix(maximumRecipients).compactMap { person in
                ProjectsAddress.normalized(person.address).map { Person(name: person.name, address: $0) }
            }
            return email
        }
    }

    /// The mail sorting may still file, by what a project's settings name, so the takes of
    /// a group look up its threads instead of reading every email.
    nonisolated struct MailIndex: Sendable {
        /// The emails, with their addresses in their one form, see `normalized(_:)`.
        let mail: [Mail]
        /// The emails by the addresses in their headers other than the user's.
        private(set) var byAddress: [String: [Int]] = [:]
        /// The emails by the domains of those addresses.
        private(set) var byDomain: [String: [Int]] = [:]
        private(set) var byMailbox: [String: [Int]] = [:]
        private(set) var byRoot: [String: [Int]] = [:]

        /// `mail` with its addresses in their one form, and the user's own addresses.
        init(_ mail: [Mail], own: Set<String>) {
            self.mail = mail
            for (index, email) in mail.enumerated() {
                byRoot[email.threadRoot, default: []].append(index)
                if let mailbox = email.mailbox {
                    byMailbox[mailbox, default: []].append(index)
                }
                var addresses = Set<String>()
                var domains = Set<String>()
                for address in [email.sender.address] + email.recipients.map(\.address)
                where !address.isEmpty && !own.contains(address) && addresses.insert(address).inserted {
                    byAddress[address, default: []].append(index)
                    if let domain = ProjectSuggestions.domain(of: address), domains.insert(domain).inserted {
                        byDomain[domain, default: []].append(index)
                    }
                }
            }
        }
    }

    /// The emails sorting would file by the rules alone in a project made from the group,
    /// next to the user's projects, oldest first. Each email is sorted after the ones
    /// before it, so a reply follows its thread into the new project, as when sorting runs
    /// again after the project is created. The model and the words of the project are left
    /// out, so the project may take more once the model agrees.
    static func takes(of group: Group, in index: MailIndex, existing: [SortingCandidate], ownAddresses: [String]) async -> [String] {
        let candidate = SortingCandidate(
            id: UUID(), name: "",
            people: group.people.map { SortingCandidate.Person(name: $0.name, address: $0.address) },
            domains: group.domains,
            mailboxes: group.mailbox.map { [$0] } ?? [])
        let projects = await SortingProjects.prepare(existing + [candidate], ownAddresses: ownAddresses)
        // Only threads with an email the new project's settings name can follow it.
        var named = Set<Int>()
        if let mailbox = group.mailbox {
            named.formUnion(index.byMailbox[mailbox] ?? [])
        }
        for person in group.people {
            named.formUnion(index.byAddress[person.address] ?? [])
        }
        for (domain, emails) in index.byDomain where group.domains.contains(where: { isDomain(domain, under: $0) }) {
            named.formUnion(emails)
        }
        let roots = Set(named.map { index.mail[$0].threadRoot })
        let ordered = roots.flatMap { index.byRoot[$0] ?? [] }
            .sorted { (index.mail[$0].date, $0) < (index.mail[$1].date, $1) }
            .map { index.mail[$0] }
        var filed: [String: UUID] = [:]
        var taken: [String] = []
        for email in ordered {
            let parent = (email.inReplyTo + email.references.reversed()).lazy.compactMap { filed[$0] }.first
            let input = SortingInput(
                messageID: email.messageID,
                sender: email.sender.address,
                recipients: email.recipients.map(\.address),
                subject: email.subject,
                text: "",
                mailbox: email.mailbox,
                parentProject: parent,
                list: email.list)
            let signals = await SortingSignals.gather(for: input, among: projects, score: { _ in [:] })
            let decision = SortingPolicy.decide(signals, model: nil)
            guard decision.level == .sure, let project = decision.project else { continue }
            filed[email.messageID] = project
            if project == candidate.id {
                taken.append(email.messageID)
            }
        }
        return taken
    }

    /// The domain of an address, nil without one.
    static func domain(of address: String) -> String? {
        guard let at = address.lastIndex(of: "@") else { return nil }
        let domain = address[address.index(after: at)...]
        return domain.isEmpty ? nil : String(domain)
    }

    /// Whether the domain is this one or under it.
    static func isDomain(_ domain: String, under other: String) -> Bool {
        var other = SortingText.address(other)
        if other.hasPrefix("@") {
            other.removeFirst()
        }
        return !other.isEmpty && (domain == other || domain.hasSuffix("." + other))
    }

    /// Whether many unrelated people share the domain, such as gmail.com or qq.com.
    static func isSharedProvider(_ domain: String) -> Bool {
        SortingService.sharedMailDomains.contains { isDomain(domain, under: $0) }
    }
}

// MARK: The grouping

nonisolated extension ProjectSuggestions {
    /// One run of the grouping, over mail with its addresses in their one form.
    private struct Grouping {
        /// A thread of Needs a Project.
        struct Thread {
            var mail: [Mail]
            /// The other side's addresses, each once.
            var otherSide: [String]
            /// Its anchors, without those the user dismissed.
            var anchors: [Anchor] = []
            /// Whether all its anchors were dismissed, so it is left out.
            var isDismissed = false
        }

        let own: Set<String>
        let ownDomains: Set<String>
        let projects: [SortingCandidate]
        let dismissed: Set<String>
        var threads: [Thread] = []
        /// The most common name of each address.
        var names: [String: String] = [:]
        private(set) var groups: [Group] = []

        init(mail: [Mail], own: Set<String>, projects: [SortingCandidate], dismissed: Set<String>) {
            self.own = own
            ownDomains = Set(own.compactMap(ProjectSuggestions.domain(of:)))
            self.projects = projects
            self.dismissed = dismissed
            let eligible = mail.filter { !$0.movedByUser && !isListMail($0) }
            names = Self.names(in: eligible)
            readThreads(eligible)
            groups = makeGroups()
        }

        /// List mail: a newsletter or a notice the user received.
        private func isListMail(_ mail: Mail) -> Bool {
            let sender = mail.sender.address
            guard !sender.isEmpty, !own.contains(sender) else { return false }
            return mail.list.sign(sender: sender, text: mail.text) != nil
        }

        private func isDismissed(_ anchor: Anchor) -> Bool {
            !dismissed.isEmpty && dismissed.contains(ProjectSuggestions.dismissalKey(anchor))
        }

        private static func names(in mail: [Mail]) -> [String: String] {
            var counts: [String: [String: Int]] = [:]
            for email in mail {
                for person in [email.sender] + email.recipients {
                    let name = person.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty, !person.address.isEmpty else { continue }
                    counts[person.address, default: [:]][name, default: 0] += 1
                }
            }
            return counts.mapValues { names in names.max { ($0.value, $1.key) < ($1.value, $0.key) }!.key }
        }

        /// The threads of the mail, each with its other side and anchors.
        private mutating func readThreads(_ mail: [Mail]) {
            var order: [String] = []
            var byRoot: [String: [Mail]] = [:]
            for email in mail {
                let root = email.threadRoot.isEmpty ? email.messageID : email.threadRoot
                if byRoot[root] == nil {
                    order.append(root)
                }
                byRoot[root, default: []].append(email)
            }
            for root in order {
                let emails = byRoot[root] ?? []
                var side: [String] = []
                for email in emails {
                    for address in otherSide(of: email) where !side.contains(address) {
                        side.append(address)
                    }
                }
                threads.append(Thread(mail: emails, otherSide: side))
            }
            var dismissedAny = Array(repeating: false, count: threads.count)
            for index in threads.indices {
                var anchors: [Anchor] = []
                for address in threads[index].otherSide {
                    guard let anchor = anchor(for: address), !anchors.contains(anchor) else { continue }
                    if isDismissed(anchor) {
                        dismissedAny[index] = true
                    } else {
                        anchors.append(anchor)
                    }
                }
                threads[index].anchors = anchors
            }
            // A mailbox the user files one party's mail into goes first.
            let mailboxes = projectMailboxes(total: mail.count)
            for index in threads.indices {
                guard let mailbox = Self.mailbox(of: threads[index]), mailboxes.contains(mailbox) else { continue }
                if isDismissed(.mailbox(mailbox)) {
                    dismissedAny[index] = true
                } else {
                    threads[index].anchors.insert(.mailbox(mailbox), at: 0)
                }
            }
            for index in threads.indices {
                threads[index].isDismissed = dismissedAny[index] && threads[index].anchors.isEmpty
            }
        }

        /// The mailbox all of a thread's mail is in, nil when it is in several or none.
        private static func mailbox(of thread: Thread) -> String? {
            guard let mailbox = thread.mail.first?.mailbox, thread.mail.allSatisfy({ $0.mailbox == mailbox }) else { return nil }
            return mailbox
        }

        /// The sender of mail the user received, or the recipients of mail the user sent,
        /// none of them the user.
        private func otherSide(of mail: Mail) -> [String] {
            let sender = mail.sender.address
            guard !sender.isEmpty else { return [] }
            guard own.contains(sender) else { return [sender] }
            var addresses: [String] = []
            for person in mail.recipients where !own.contains(person.address) && !addresses.contains(person.address) {
                addresses.append(person.address)
            }
            return addresses
        }

        /// The anchor an address gives: its domain, or itself at a shared mail provider.
        /// None at the user's own domains, and none for what a project names already.
        private func anchor(for address: String) -> Anchor? {
            guard let domain = ProjectSuggestions.domain(of: address), !isNamedByProject(address) else { return nil }
            if ProjectSuggestions.isSharedProvider(domain) {
                return .person(address)
            }
            return ownDomains.contains(domain) ? nil : .domain(domain)
        }

        /// Whether a project of the user names the address, as a person, a sender rule, or
        /// a domain or a domain rule it is in.
        private func isNamedByProject(_ address: String) -> Bool {
            let domain = ProjectSuggestions.domain(of: address) ?? ""
            return projects.contains { project in
                project.people.contains { SortingText.address($0.address) == address }
                    || project.domains.contains { ProjectSuggestions.isDomain(domain, under: $0) }
                    || project.rules.contains { rule in
                        switch rule {
                        case .sender(let sender): SortingText.address(sender) == address
                        case .domain(let ruled): ProjectSuggestions.isDomain(domain, under: ruled)
                        case .list, .subjectCode: false
                        }
                    }
            }
        }

        /// The mailboxes the user files one party's mail into, which anchor a group before
        /// any other anchor. Such a mailbox is linked to no project and holds at least
        /// `minimumMails` emails and less than `maximumMailboxShare` of them. Of the threads
        /// wholly in it, at most `mailboxParties` anchors carry `mailboxCoverage` of the
        /// mail, and at most one anchor carries `minimumMails` or more and has at least half
        /// of its mail there. So the inbox, the sent mailbox or an archive, where many people
        /// write who could each be a project, never takes their threads.
        private func projectMailboxes(total: Int) -> Set<String> {
            var counts: [String: Int] = [:]
            var weight: [Anchor: Int] = [:]
            var inside: [String: [Int]] = [:]
            for (index, thread) in threads.enumerated() {
                for email in thread.mail {
                    if let mailbox = email.mailbox {
                        counts[mailbox, default: 0] += 1
                    }
                }
                for anchor in thread.anchors {
                    weight[anchor, default: 0] += thread.mail.count
                }
                if let mailbox = Self.mailbox(of: thread) {
                    inside[mailbox, default: []].append(index)
                }
            }
            let linked = Set(projects.flatMap(\.mailboxes))
            return Set(inside.compactMap { mailbox, indices -> String? in
                let count = counts[mailbox] ?? 0
                let held = indices.reduce(0) { $0 + threads[$1].mail.count }
                guard held >= minimumMails, Double(count) < maximumMailboxShare * Double(total), !linked.contains(mailbox) else { return nil }
                var carried: [Anchor: Int] = [:]
                for index in indices {
                    for anchor in threads[index].anchors {
                        carried[anchor, default: 0] += threads[index].mail.count
                    }
                }
                let parties = carried.sorted { ($0.value, $1.key.key) > ($1.value, $0.key.key) }.prefix(mailboxParties)
                let top = Set(parties.map(\.key))
                let covered = indices.filter { threads[$0].anchors.contains(where: top.contains) }.reduce(0) { $0 + threads[$1].mail.count }
                guard Double(covered) >= mailboxCoverage * Double(held) else { return nil }
                let large = parties.filter { $0.value >= minimumMails }
                guard large.count <= 1 else { return nil }
                if let party = large.first, 2 * party.value < weight[party.key, default: 0] {
                    return nil
                }
                return mailbox
            })
        }

        // MARK: Groups

        private func makeGroups() -> [Group] {
            var weight: [Anchor: Int] = [:]
            for thread in threads {
                for anchor in thread.anchors {
                    weight[anchor, default: 0] += thread.mail.count
                }
            }
            // Each thread to its mailbox, else to its anchor with the most mail.
            var members: [Anchor: [Int]] = [:]
            var primary: [Int: Anchor] = [:]
            var orphans: [Int] = []
            for (index, thread) in threads.enumerated() where !thread.isDismissed {
                let best = thread.anchors.reduce(nil as Anchor?) { best, anchor in
                    guard let best else { return anchor }
                    return Self.isStronger(anchor, weight[anchor] ?? 0, than: best, weight[best] ?? 0) ? anchor : best
                }
                guard let best else {
                    orphans.append(index)
                    continue
                }
                primary[index] = best
                members[best, default: []].append(index)
            }
            func size(_ anchor: Anchor) -> Int {
                (members[anchor] ?? []).reduce(0) { $0 + threads[$1].mail.count }
            }
            // A small group joins the large group it shares the most threads with.
            let small = members.keys.filter { size($0) < minimumMails }.sorted { (size($0), $0.key) < (size($1), $1.key) }
            for anchor in small {
                var shared: [Anchor: Int] = [:]
                for (index, thread) in threads.enumerated() where thread.anchors.contains(anchor) {
                    if let other = primary[index], other != anchor, size(other) >= minimumMails {
                        shared[other, default: 0] += 1
                    }
                }
                let indices = members[anchor] ?? []
                members[anchor] = nil
                if let target = shared.max(by: { ($0.value, size($0.key), $1.key.key) < ($1.value, size($1.key), $0.key.key) })?.key {
                    members[target, default: []] += indices
                    for index in indices {
                        primary[index] = target
                    }
                } else {
                    orphans += indices
                    for index in indices {
                        primary[index] = nil
                    }
                }
            }
            for (anchor, indices) in wordGroups(orphans.sorted()) {
                members[anchor] = indices
                for index in indices {
                    primary[index] = anchor
                }
            }
            // The groups each person of the other side writes in.
            var groupsOf: [String: Set<Anchor>] = [:]
            for (index, anchor) in primary {
                for address in threads[index].otherSide {
                    groupsOf[address, default: []].insert(anchor)
                }
            }
            return members.compactMap { anchor, indices in
                group(anchor, threads: indices, groupsOf: groupsOf)
            }
        }

        /// Whether a thread goes to this anchor rather than the other: its mailbox always,
        /// then the anchor with more mail, a domain before a person, then the smaller key,
        /// so the choice never depends on the order.
        private static func isStronger(_ anchor: Anchor, _ weight: Int, than other: Anchor, _ otherWeight: Int) -> Bool {
            func kind(_ anchor: Anchor) -> Int {
                switch anchor {
                case .mailbox: 3
                case .domain: 2
                case .person: 1
                case .word: 0
                }
            }
            if (kind(anchor) == 3) != (kind(other) == 3) {
                return kind(anchor) == 3
            }
            if weight != otherWeight {
                return weight > otherWeight
            }
            if kind(anchor) != kind(other) {
                return kind(anchor) > kind(other)
            }
            return anchor.key < other.key
        }

        /// Groups of the threads left over whose subjects share a word, at least
        /// `minimumWordThreads` threads with `minimumMails` emails each. A thread joins one
        /// group at most, that of the word most threads share.
        private func wordGroups(_ orphans: [Int]) -> [(Anchor, [Int])] {
            var threadsOf: [String: [Int]] = [:]
            for index in orphans {
                for word in subjectWords(threads[index]) {
                    threadsOf[word, default: []].append(index)
                }
            }
            var used = Set<Int>()
            var groups: [(Anchor, [Int])] = []
            let words = threadsOf.keys.sorted { (threadsOf[$0]!.count, $1) > (threadsOf[$1]!.count, $0) }
            for word in words {
                let indices = threadsOf[word]!.filter { !used.contains($0) }
                let anchor = Anchor.word(word)
                guard indices.count >= minimumWordThreads,
                      indices.reduce(0, { $0 + threads[$1].mail.count }) >= minimumMails,
                      !isDismissed(anchor) else { continue }
                used.formUnion(indices)
                groups.append((anchor, indices))
            }
            return groups
        }

        /// The words of a thread's subjects without their Re: and Fwd: prefixes that a
        /// project would be known by, as SortingProjects reads a project's own words. A
        /// subject that asks for a filing gives none, see FilingRequests.
        private func subjectWords(_ thread: Thread) -> Set<String> {
            let subjects = Set(thread.mail.filter { !FilingRequests.isFilingRequest($0.subject) }.map { MailThreads.subjectKey($0.subject).key })
            guard !subjects.isEmpty else { return [] }
            let candidate = SortingCandidate(id: UUID(), name: subjects.sorted().joined(separator: "\n"))
            return Set(SortingProjects.distinctiveWords([candidate], ownAddresses: own)[candidate.id] ?? [])
        }

        /// The group of an anchor with its threads, with what New Project is prefilled with.
        /// `groupsOf` gives the groups each person writes in.
        private func group(_ anchor: Anchor, threads indices: [Int], groupsOf: [String: Set<Anchor>]) -> Group? {
            let members = indices.flatMap { threads[$0].mail }
            guard members.count >= minimumMails else { return nil }
            // Mail per person of the other side in this group, and whether one writes in
            // another group too.
            var counts: [String: Int] = [:]
            for index in indices {
                for email in threads[index].mail {
                    for address in otherSide(of: email) {
                        counts[address, default: 0] += 1
                    }
                }
            }
            let anchorDomain: String? = if case .domain(let domain) = anchor { domain } else { nil }
            let people = counts.keys
                .filter { address in
                    guard let domain = ProjectSuggestions.domain(of: address), !isNamedByProject(address) else { return false }
                    if domain == anchorDomain || anchor == .person(address) {
                        return true
                    }
                    let colleague = ownDomains.contains(domain) && !ProjectSuggestions.isSharedProvider(domain)
                    return !colleague && groupsOf[address, default: []].subtracting([anchor]).isEmpty
                }
                .sorted { (counts[$0]!, $1) > (counts[$1]!, $0) }
                .prefix(maximumPeople)
                .map { Person(name: names[$0] ?? "", address: $0) }
            var mailbox: String?
            if case .mailbox(let name) = anchor {
                mailbox = name
            }
            return Group(
                anchor: anchor,
                people: people,
                domains: anchorDomain.map { [$0] } ?? [],
                mailbox: mailbox,
                messageIDs: members.sorted { $0.date > $1.date }.map(\.messageID),
                takes: [],
                language: Self.language(of: members))
        }

        /// The language most of the emails are in, by their subject and the start of their
        /// text. English when as many are in one language as in another.
        private static func language(of mail: [Mail]) -> ProjectsLanguage {
            var counts: [ProjectsLanguage: Int] = [:]
            for email in mail {
                counts[ProjectsLanguage.reading(email.subject + "\n" + email.text.prefix(300)), default: 0] += 1
            }
            // max(by:) keeps the first of equal counts.
            return [ProjectsLanguage.en, .zh, .other].max { counts[$0, default: 0] < counts[$1, default: 0] } ?? .en
        }
    }
}
