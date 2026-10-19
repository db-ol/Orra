import Foundation
import Testing
@testable import Orra

/// The types every Projects change shares: the warnings and the kinds of hidden text, the
/// language of a text and the form of an address.
struct ProjectsSharedTypesTests {
    /// The release gate scores the warnings by these words, which the synthetic test set uses.
    @Test func warningsCarryTheWordsOfTheTestSet() {
        #expect(ProjectsWarning.allCases.map(\.rawValue) == [
            "hidden_text", "instruction_to_assistant", "document_instruction", "claims_to_be_orra",
            "lookalike_domain", "sender_name_mismatch", "forged_quote", "payment_change",
            "payment_terms_change", "unknown_sender_payment", "false_urgency", "link",
            "forward_request", "confidential_data_request", "personal_data_request",
            "credential_request", "recipient_not_in_project_people", "attachment_name_spoofing",
        ])
    }

    @Test func hiddenTextKindsKeepTheirNames() {
        #expect(ProjectsHiddenText.allCases.map(\.rawValue) == [
            "hiddenStyle", "tinyFont", "sameColor", "transparent", "htmlComment", "imageText",
            "invisibleCharacters", "tagCharacters", "bidiControls", "chatTemplateTokens", "afterBlankLines",
        ])
    }

    @Test func languagesKeepTheirCodes() {
        #expect(ProjectsLanguage.allCases.map(\.rawValue) == ["zh", "en", "other"])
    }

    /// Saved findings come back as they were written, by their raw values.
    @Test func theTypesRoundTripThroughJSON() throws {
        let json = Data(#"{"warnings":["link","hidden_text"],"hidden":["tagCharacters"],"language":"zh"}"#.utf8)
        let saved = try JSONDecoder().decode(Saved.self, from: json)
        #expect(saved.warnings == [.link, .hiddenText])
        #expect(saved.hidden == [.tagCharacters])
        #expect(saved.language == .zh)
        #expect(try JSONDecoder().decode(Saved.self, from: JSONEncoder().encode(saved)) == saved)
    }

    private struct Saved: Codable, Equatable {
        var warnings: [ProjectsWarning]
        var hidden: [ProjectsHiddenText]
        var language: ProjectsLanguage
    }

    @Test(arguments: [
        "请在周五前确认合同。",
        "下周三开会",
        "这个 PR 先 merge 一下",
        "附件是 v2 版的报价单，请查收。",
        "请把报价单发给安娜・林，谢谢。",
        "大家好ー明天上午十点开会。",
    ])
    func chineseReadsAsChinese(_ text: String) {
        #expect(ProjectsLanguage.reading(text) == .zh)
    }

    @Test(arguments: [
        "Please confirm the contract by Friday.",
        "OK",
        "Can we move the call to 3 pm?",
        "The draft for 合同 is attached.",
        "Thanks, see you at the café.",
        "Hi Mei, please confirm the booking for the harbor venue by Friday. Thanks, Lu",
        "Hi Lu, please loop in Budi Santoso and Siti Rahayu from the harbor team on the quote.",
        "Hi Mei, danke für die Unterlagen, see you Friday.",
    ])
    func englishReadsAsEnglish(_ text: String) {
        #expect(ProjectsLanguage.reading(text) == .en)
    }

    @Test(arguments: [
        "日本語を話します",
        "会議は東京駅で行います。",
        "来週の打ち合わせ",
        "다음 주 회의",
        "Встреча в пятницу",
        "",
        "2026-10-18 15:00",
    ])
    func otherScriptsAndTextWithoutLettersReadAsOther(_ text: String) {
        #expect(ProjectsLanguage.reading(text) == .other)
    }

    /// Phase 1 drafts only in Chinese and English, so a draft or a mail in German or
    /// Spanish must not read as English.
    @Test(arguments: [
        "Hallo Mei, kannst du die Buchung für Freitag bestätigen? Danke, Lu",
        "Sehr geehrte Frau Tan, anbei die Rechnung für Oktober und der neue Zeitplan.",
        "Hola Mei, gracias por el presupuesto. Lo reviso mañana y te escribo.",
        "Bonjour Mei, pouvez-vous confirmer la réservation de la salle pour vendredi ?",
    ])
    func otherLanguagesInLatinLettersReadAsOther(_ text: String) {
        #expect(ProjectsLanguage.reading(text) == .other)
    }

    /// Mixed text goes by which script carries more of it.
    @Test func mixedTextGoesByTheLargerPart() {
        #expect(ProjectsLanguage.reading("合同 OK") == .zh)
        #expect(ProjectsLanguage.reading("我们明天讨论 the budget") == .zh)
        #expect(ProjectsLanguage.reading("We can discuss the budget and the schedule 明天") == .en)
        #expect(ProjectsLanguage.reading("Meeting notes さくら") == .en)
    }

    @Test func explanationsAreChineseOnlyForAChineseInterface() {
        #expect(ProjectsLanguage.forExplanations(interface: "zh-Hans") == .zh)
        #expect(ProjectsLanguage.forExplanations(interface: "zh") == .zh)
        #expect(ProjectsLanguage.forExplanations(interface: "en") == .en)
        #expect(ProjectsLanguage.forExplanations(interface: "ja") == .en)
        #expect(ProjectsLanguage.forExplanations(interface: "es-419") == .en)
    }

    @Test func addressesBecomeLowercaseLocalAtDomain() {
        #expect(ProjectsAddress.normalized("Mei.Tan@Harbor.example") == "mei.tan@harbor.example")
        #expect(ProjectsAddress.normalized("  mei@harbor.example\n") == "mei@harbor.example")
        #expect(ProjectsAddress.normalized("<Mei@Harbor.example>") == "mei@harbor.example")
        #expect(ProjectsAddress.normalized("Mei Tan <Mei.Tan@Harbor.example>") == "mei.tan@harbor.example")
        #expect(ProjectsAddress.normalized("\"Tan, Mei\" <mei.tan@harbor.example>") == "mei.tan@harbor.example")
        #expect(ProjectsAddress.normalized("谭梅 < mei+orders@harbor.example >") == "mei+orders@harbor.example")
        #expect(ProjectsAddress.normalized("mei@港湾.example") == "mei@港湾.example")
        #expect(ProjectsAddress.normalized("Tan, Mei <mei.tan@harbor.example>") == "mei.tan@harbor.example")
        #expect(ProjectsAddress.normalized("mei@harbor.example <Mei@Harbor.example>") == "mei@harbor.example")
        #expect(ProjectsAddress.normalized("\"Lu <sales>, Mei@x\" <mei@harbor.example>") == "mei@harbor.example")
    }

    /// The same address keeps the same bytes, whether its letters come composed or not.
    @Test func addressesAreComposed() {
        let decomposed = ProjectsAddress.normalized("Jose\u{301}@Harbor.example")
        #expect(decomposed.map { Array($0.utf8) } == Array("josé@harbor.example".precomposedStringWithCanonicalMapping.utf8))
    }

    @Test(arguments: [
        "",
        "Mei Tan",
        "mei.harbor.example",
        "@harbor.example",
        "mei@",
        "mei@@harbor.example",
        "mei@harbor@example",
        "mei@.harbor.example",
        "mei@harbor.example.",
        "mei@harbor..example",
        "mei tan@harbor.example",
        "mei@harbor.example, lu@harbor.example",
        "Mei <mei@harbor.example>, Lu <lu@harbor.example>",
        "lu@harbor.example, Mei <mei@harbor.example>",
        "Mei <mei@harbor.example> <lu@harbor.example>",
        "\"Mei <mei@harbor.example>",
        "Mei Tan mei@harbor.example",
        "<mei@harbor.example",
        "mailto:mei@harbor.example",
        "mei\u{200B}@harbor.example",
        "mei@harbor\u{202E}elpmaxe",
        "mei@harbor.example\u{0}",
    ])
    func textThatIsNotOneAddressGivesNil(_ text: String) {
        #expect(ProjectsAddress.normalized(text) == nil)
    }

    /// A lookalike letter is not folded into the real one, so a lookalike domain stays apart.
    @Test func lookalikeLettersStayApart() {
        let lookalike = ProjectsAddress.normalized("mei@h\u{0430}rbor.example")
        #expect(lookalike != nil)
        #expect(lookalike != ProjectsAddress.normalized("mei@harbor.example"))
    }
}
