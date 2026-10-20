import Foundation
import Testing
@testable import Orra

struct MailThreadsTests {
    private static let own: Set<String> = ["theo@studio.example"]
    private static let start = Date(timeIntervalSince1970: 1_790_000_000)

    private static func message(
        _ id: String,
        inReplyTo: [String] = [],
        references: [String] = [],
        subject: String = "Proofs",
        people: Set<String> = ["mei@orchard.example", "theo@studio.example"],
        day: Double = 0
    ) -> MailThreads.Message {
        MailThreads.Message(
            messageID: id, inReplyTo: inReplyTo, references: references, subject: subject, people: people,
            date: start.addingTimeInterval(day * 86_400))
    }

    private static func known(_ id: String, root: String, subject: String = "proofs", people: Set<String> = ["mei@orchard.example"], day: Double = 0) -> MailThreads.Known {
        MailThreads.Known(messageID: id, root: root, subjectKey: subject, people: people, date: start.addingTimeInterval(day * 86_400))
    }

    private static func root(_ message: MailThreads.Message, known: [MailThreads.Known] = []) -> String {
        MailThreads.root(
            of: message, ownAddresses: own,
            known: { id in known.first { $0.messageID == id } },
            sameSubject: { key in known.filter { $0.subjectKey == key } })
    }

    @Test func theFirstReferenceIsTheRoot() {
        #expect(Self.root(Self.message("c", references: ["a", "b"])) == "a")
        // A known first reference gives its own root.
        #expect(Self.root(Self.message("c", references: ["a", "b"]), known: [Self.known("a", root: "r")]) == "r")
        // The message itself in its References does not count.
        #expect(Self.root(Self.message("c", references: ["c", "b"])) == "b")
    }

    @Test func inReplyToCountsThroughAKnownMessage() {
        #expect(Self.root(Self.message("c", inReplyTo: ["b"]), known: [Self.known("b", root: "a")]) == "a")
        // A parent no one has seen is the root, as an unknown first reference is.
        #expect(Self.root(Self.message("c", inReplyTo: ["unknown"], subject: "New topic")) == "unknown")
        #expect(Self.root(Self.message("c", inReplyTo: ["c"], subject: "New topic")) == "c")
    }

    @Test func aReplyNamingOnlyItsParentJoinsTheRepliesThatListTheThread() {
        let messages = [
            Self.message("b", inReplyTo: ["a"], subject: "Re: Plan", day: 1),
            Self.message("c", inReplyTo: ["b"], references: ["a", "b"], subject: "Re: Plan", day: 2),
        ]
        #expect(MailThreads.roots(of: messages, ownAddresses: Self.own) == ["b": "a", "c": "a"])
    }

    @Test func theSubjectFallbackNeedsTheSamePeople() {
        let accountant = "ravi@ledger.example"
        let earlier = Self.known("a", root: "a", subject: "invoice", people: [accountant, "mei@orchard.example"], day: -3)
        // One person in common, but others who differ: two threads.
        let other = Self.message("b", subject: "Re: Invoice", people: [accountant, "lu@harbor.example", "theo@studio.example"])
        #expect(Self.root(other, known: [earlier]) == "b")
        // A reply to the sender alone still joins a reply to all.
        let toSender = Self.message("c", subject: "Re: Invoice", people: [accountant, "theo@studio.example"])
        #expect(Self.root(toSender, known: [earlier]) == "a")
    }

    @Test(arguments: ["Re: Proofs", "RE: proofs", "回复：Proofs", "回复: Proofs", "答复：Proofs", "AW: Proofs", "Fwd: Proofs", "FW: Proofs", "转发：Proofs", "Re[2]: Proofs", "Re: Re: Fwd:  Proofs "])
    func aReplySubjectJoinsAKnownMessage(_ subject: String) {
        let earlier = Self.known("a", root: "a", day: -3)
        #expect(Self.root(Self.message("b", subject: subject), known: [earlier]) == "a")
    }

    @Test func theSubjectFallbackNeedsAPrefixPeopleAndTime() {
        let earlier = Self.known("a", root: "root-a", day: -3)
        // No prefix: a new thread with the same subject.
        #expect(Self.root(Self.message("b", subject: "Proofs"), known: [earlier]) == "b")
        // Only the user in common.
        #expect(Self.root(Self.message("b", subject: "Re: Proofs", people: ["ravi@harbor.example", "theo@studio.example"]), known: [earlier]) == "b")
        // More than four weeks apart.
        #expect(Self.root(Self.message("b", subject: "Re: Proofs", day: 40), known: [earlier]) == "b")
        // Within four weeks the other way round too.
        #expect(Self.root(Self.message("b", subject: "Re: Proofs", day: -20), known: [earlier]) == "root-a")
        // An empty subject after the prefix.
        #expect(Self.root(Self.message("b", subject: "Re:"), known: [Self.known("a", root: "a", subject: "")]) == "b")
    }

    @Test func theNewestMatchWins() {
        let older = Self.known("a", root: "old", day: -10)
        let newer = Self.known("b", root: "new", day: -2)
        #expect(Self.root(Self.message("c", subject: "Re: Proofs"), known: [newer, older]) == "new")
    }

    @Test(arguments: [
        ("Re: Proofs", "proofs", true),
        ("  Proofs   for  Friday ", "proofs for friday", false),
        ("Re:Re[3]: FWD: Proofs", "proofs", true),
        ("回复：回复：样书", "样书", true),
        ("Regarding: proofs", "regarding: proofs", false),
        ("Re proofs", "re proofs", false),
        ("Re(2): proofs", "proofs", true),
        ("Re[x]: proofs", "re[x]: proofs", false),
        ("", "", false),
    ])
    func subjectKeys(_ subject: String, _ key: String, _ isReply: Bool) {
        let found = MailThreads.subjectKey(subject)
        #expect(found.key == key)
        #expect(found.isReply == isReply)
    }

    @Test func rootsOfABatchInDateOrder() {
        let messages = [
            Self.message("reply-2", references: ["start", "reply-1"], subject: "Re: Proofs", day: 2),
            Self.message("start", subject: "Proofs", day: 0),
            Self.message("reply-1", inReplyTo: ["start"], subject: "Re: Proofs", day: 1),
            Self.message("no-headers", subject: "Re: Proofs", day: 3),
            Self.message("other", subject: "Invoice", people: ["ravi@harbor.example"], day: 1),
            Self.message("late", subject: "Re: Proofs", day: 60),
        ]
        #expect(MailThreads.roots(of: messages, ownAddresses: Self.own) == [
            "start": "start", "reply-1": "start", "reply-2": "start", "no-headers": "start", "other": "other", "late": "late",
        ])
    }
}
