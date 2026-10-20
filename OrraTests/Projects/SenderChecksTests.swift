import Foundation
import Testing
@testable import Orra

/// The sender warnings: lookalike domains and names that do not fit their address. The
/// cases are written for these tests, on the reserved .example domains, and modeled on the
/// attack kinds of the phase 0 set (a31, a32 and a51).
struct SenderChecksTests {
    static let people: [SenderChecks.Person] = [
        .init(name: "Owen Pike", address: "owen@pike-build.example"),
        .init(name: "宋雨桐", address: "song.yutong@harborlights.example"),
        .init(name: "顾晨 Chen Gu", address: "gu.chen@northwind-co.example"),
        .init(name: "Ivy Tam", address: "ivy.tam@inbox.example"),
    ]
    static let domains = ["pike-build.example", "harborlights.example", "northwind-co.example"]
    static let own: [SenderChecks.Person] = [
        .init(name: "白露", address: "bai.lu@lumenhaus.example"),
        .init(name: "Bai Lu", address: "bai.lu@lumenhaus.example"),
    ]

    private func warnings(name: String, address: String) -> [ProjectsWarning] {
        SenderChecks.warnings(for: .init(sender: .init(name: name, address: address), people: Self.people, domains: Self.domains, own: Self.own))
    }

    // MARK: Lookalike domains

    @Test(arguments: [
        // One letter changed (a31)
        "office@harborlighs.example",
        "office@pike-buiId.example",
        // One letter added (a32)
        "desk@harborlightss.example",
        // A Cyrillic а in place of a Latin a (a51), and its punycode form
        "song@hаrborlights.example",
        "song@xn--hrborlights-yij.example",
        // A zero for an o, and rn for m
        "billing@harb0rlights.example",
        "a@northwind-co.exarnple",
        // The real domain as a part of a longer one
        "speakers@harborlights.example.verify-mail.example",
        "pay@pike-build-pay.example",
        // Another top level domain
        "owen@pike-build.co",
        // A lookalike of the user's own domain
        "finance@lumenhous.example",
    ])
    func findsLookalikeDomains(_ address: String) {
        #expect(warnings(name: "", address: address).contains(.lookalikeDomain))
    }

    @Test(arguments: [
        "owen@pike-build.example",
        "site@mail.harborlights.example",
        "someone@unrelated-studio.example",
        "news@harborview.example",
        "ivy.tam@inbox.example",
        "friend@inbox.example",
        "hello@harborlightsmuseum.example",
        // A shared provider's domain in another country is no lookalike of it.
        "friend@inbox.co",
        "friend@inbox.example.jp",
    ])
    func leavesOtherDomainsAlone(_ address: String) {
        #expect(!warnings(name: "", address: address).contains(.lookalikeDomain))
    }

    /// The domain of someone outside the guarded domains, such as a shared provider, is
    /// guarded against homoglyphs only.
    @Test func otherKnownDomainsAreGuardedAgainstHomoglyphs() {
        #expect(warnings(name: "", address: "friend@inb0x.example") == [.lookalikeDomain])
        #expect(warnings(name: "", address: "friend@lnbox.example") == [.lookalikeDomain])
        #expect(warnings(name: "", address: "friend@inbax.example").isEmpty)
    }

    /// The punycode form in the test above is the Cyrillic а one, as the IDNA encoder
    /// writes it, so it decodes and reads as the real domain.
    @Test func decodesPunycodeLabels() {
        #expect(SenderChecks.isLookalike("xn--hrborlights-yij.example", of: ["harborlights.example"]))
        #expect(!SenderChecks.isLookalike("xn--bcher-kva.example", of: ["harborlights.example"]))
        #expect(!SenderChecks.isLookalike("xn--.example", of: ["harborlights.example"]))
        #expect(!SenderChecks.isLookalike("xn--zz-zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz.example", of: ["harborlights.example"]))
    }

    /// Letters of two scripts in one label warn even when no known domain is near.
    @Test func mixedScriptsAlwaysWarn() {
        #expect(SenderChecks.isLookalike("pаypal-help.example", of: []))
        #expect(!SenderChecks.isLookalike("例子.example", of: []))
    }

    // MARK: Names

    /// A known name on an address that person never used, as a free mail address in the
    /// name of a client.
    @Test func findsAKnownNameOnAnUnknownAddress() {
        #expect(warnings(name: "宋雨桐", address: "songyutong.museum@freemail.example") == [.senderNameMismatch])
        #expect(warnings(name: "Owen Pike", address: "owen.pike.builder@freemail.example") == [.senderNameMismatch])
        #expect(warnings(name: "Chen Gu", address: "chengu@freemail.example") == [.senderNameMismatch])
        #expect(warnings(name: "\"宋 雨桐\"", address: "songyutong.museum@freemail.example") == [.senderNameMismatch])
    }

    @Test func findsTheUsersOwnNameFromAnotherAddress() {
        #expect(warnings(name: "白露", address: "bailu.finance@freemail.example") == [.senderNameMismatch])
        #expect(warnings(name: "Bai Lu", address: "bai.lu@lumenhaus-mail.example").contains(.senderNameMismatch))
    }

    @Test func findsAnAddressInTheDisplayName() {
        #expect(warnings(name: "owen@pike-build.example", address: "billing@freemail.example") == [.senderNameMismatch])
        #expect(warnings(name: "Owen Pike (owen@pike-build.example)", address: "owen@pike-build.example").isEmpty)
    }

    /// A new address at a domain the user listed is the same organization, and a name
    /// nobody has is no mismatch. A lone given name never stands for a person.
    @Test func leavesFittingNamesAlone() {
        #expect(warnings(name: "Owen Pike", address: "o.pike@pike-build.example").isEmpty)
        #expect(warnings(name: "Owen Pike", address: "owen@pike-build.example").isEmpty)
        #expect(warnings(name: "Mara Quinn", address: "mara@freemail.example").isEmpty)
        #expect(warnings(name: "Owen", address: "owen@freemail.example").isEmpty)
        #expect(warnings(name: "", address: "noreply@freemail.example").isEmpty)
    }

    /// A one word name, such as a given name or a role, is no person, so two senders may
    /// share it.
    @Test func oneWordNamesStandForNobody() {
        let people: [SenderChecks.Person] = [.init(name: "Support", address: "support@tiles-shop.example"), .init(name: "Ana", address: "ana@freemail.example")]
        for sender in [SenderChecks.Person(name: "Support", address: "help@glass-shop.example"), .init(name: "Ana", address: "ana.r@studio.example")] {
            #expect(SenderChecks.warnings(for: .init(sender: sender, people: people)).isEmpty)
        }
    }

    /// A free mail address is no organization, so a known name on another address there
    /// still warns.
    @Test func aSharedProviderIsNoOrganization() {
        #expect(warnings(name: "Ivy Tam", address: "ivy.t@inbox.example") == [.senderNameMismatch])
    }

    @Test func mailFromTheUserGetsNoWarning() {
        #expect(warnings(name: "白露", address: "Bai.Lu@Lumenhaus.example").isEmpty)
    }

    @Test func bothWarningsComeInTheirOrder() {
        #expect(warnings(name: "Owen Pike", address: "owen@pike-bui1d.example") == [.lookalikeDomain, .senderNameMismatch])
    }

    @Test func nameFormsSplitBilingualNames() {
        #expect(SenderChecks.nameForms("顾晨 Chen Gu") == ["顾晨 chen gu", "顾晨", "chen gu"])
        #expect(SenderChecks.nameForms(" \"宋 雨桐\" (Harbor Lights) ") == ["宋雨桐"])
        #expect(SenderChecks.nameForms("Ｏｗｅｎ  Pike") == ["owen pike"])
        #expect(SenderChecks.nameForms("Owen").isEmpty)
        #expect(SenderChecks.nameForms("客服") == ["客服"])
        #expect(SenderChecks.nameForms("owen@pike-build.example").isEmpty)
        #expect(SenderChecks.nameForms("  ").isEmpty)
        #expect(SenderChecks.nameForms(String(repeating: "(", count: 10_000) + " Owen Pike").isEmpty)
    }
}
