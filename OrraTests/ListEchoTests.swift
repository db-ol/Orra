import Foundation
import Testing
@testable import Orra

/// The protections against a list of names written over speech, with texts like those of
/// the context experiment of 2026-10-15, and the transcription path that uses them.
@MainActor
struct ListEchoTests {
    private let team = ["Dana Whitfield", "Bram Okafor", "Quorvia"]
    private let labs = ["Quorvia", "Thornsby Labs", "Kelpstone", "Lindqvist"]

    // MARK: The protections

    @Test func aNameSaidAloneStaysEvenWhenThePlainPassSpellsItOtherwise() {
        // 0.44 alike only, but just as long.
        #expect(VocabularyEcho.isOnlyTerms("尉迟岚。", of: ["尉迟岚", "Quorvia"]))
        #expect(ListEcho.soundSimilarity("鱼鳍蓝。", "尉迟岚。") < 0.5)
        #expect(!ListEcho.isListOverSpeech("尉迟岚。", plain: "鱼鳍蓝。"))
        #expect(!ListEcho.isListOverSpeech("Ngozi Adeyemi.", plain: "Ngozi Adeyemi."))
    }

    @Test func aListWrittenOverSpeechIsFound() {
        let list = "Ngozi Adeyemi, Bartholomew Crane, Nkosi Adebayo, Marrowind."
        #expect(VocabularyEcho.isOnlyTerms(list, of: ["Ngozi Adeyemi", "Bartholomew Crane", "Nkosi Adebayo", "Marrowind"]))
        #expect(ListEcho.isListOverSpeech(list, plain: "Let's ship it."))
    }

    @Test func aListAtTheStartIsFoundUnlessThePlainPassHasItsNames() {
        let text = "Dana Whitfield, Bram Okafor, we can ship the build on Friday."
        #expect(ListEcho.leadingItems(text, terms: team) == ["Dana Whitfield", "Bram Okafor"])
        #expect(ListEcho.mayBeList(text, terms: team))
        #expect(ListEcho.protection(text, plain: "We can ship the build on Friday.", terms: team, heardSpeech: true) == .leadingList)
        // Without speech the plain pass, which heard nothing, stands too.
        #expect(ListEcho.protection(text, plain: "", terms: team, heardSpeech: false) == .leadingList)
        // The user said the names, which the plain pass spells by ear.
        #expect(ListEcho.protection(text, plain: "Donna Whitfield, Brom Okafor, we can ship the build on Friday.", terms: team, heardSpeech: true) == nil)
    }

    @Test func aTextMostlyOfTermsIsFoundOnlyOverLongerSpeech() {
        let text = "Quorvia Thornsby Labs Kelpstone Lindqvist update."
        #expect(ListEcho.termCoverage(text, terms: labs) > 0.8)
        #expect(ListEcho.mayBeList(text, terms: labs))
        #expect(ListEcho.protection(text, plain: "Update.", terms: labs, heardSpeech: true) == .mostlyTerms)
        #expect(ListEcho.protection(text, plain: "", terms: labs, heardSpeech: false) == nil)
        // A greeting with a name is mostly the name, and stays.
        #expect(ListEcho.mayBeList("Hi Callum Reyes.", terms: ["Callum Reyes"]))
        #expect(ListEcho.protection("Hi Callum Reyes.", plain: "Hi Kalam Rayes.", terms: ["Callum Reyes"], heardSpeech: true) == nil)
    }

    @Test func ordinaryDictationsWithNamesNeedNoSecondPass() {
        #expect(!ListEcho.mayBeList("We can ship the build on Friday.", terms: team))
        #expect(!ListEcho.mayBeList("我们周五和 Dana 一起发布 Quorvia。", terms: team))
        #expect(!ListEcho.mayBeList("", terms: team))
    }

    // MARK: The transcription path

    private let samples = [Float](repeating: 0.1, count: 32_000)

    private func transcribe(_ speech: FakeSpeech, _ terms: [String], screenNames: Bool) async throws -> String {
        try await speech.transcription.transcribe(samples, vocabulary: terms, holdsScreenNames: screenNames, audioSeconds: 2)
    }

    @Test func withScreenNamesAListOverSpeechGivesWayToThePlainPass() async throws {
        let speech = FakeSpeech()
        speech.reply = "Dana Whitfield, Quorvia."
        speech.replyWithoutContext = "Let's go over the launch plan tomorrow."
        #expect(try await transcribe(speech, team, screenNames: true) == "Let's go over the launch plan tomorrow.")
        #expect(speech.receivedContexts == ["Dana Whitfield\nBram Okafor\nQuorvia", nil])
        // The vocabulary alone keeps today's check: the user is taken to have said the terms.
        #expect(try await transcribe(speech, team, screenNames: false) == "Dana Whitfield, Quorvia.")
    }

    @Test func withScreenNamesSilenceStillGivesNoText() async throws {
        let speech = FakeSpeech()
        speech.reply = "Dana Whitfield, Bram Okafor, Quorvia."
        speech.replyWithoutContext = ""
        #expect(try await transcribe(speech, team, screenNames: true) == "")
        #expect(try await transcribe(speech, team, screenNames: false) == "")
    }

    @Test func withScreenNamesANameSaidAloneStays() async throws {
        let speech = FakeSpeech()
        speech.reply = "尉迟岚。"
        speech.replyWithoutContext = "鱼鳍蓝。"
        #expect(try await transcribe(speech, ["尉迟岚", "Quorvia"], screenNames: true) == "尉迟岚。")
        #expect(speech.receivedContexts == ["尉迟岚\nQuorvia", nil])
    }

    @Test func withScreenNamesALeadingListGivesWayToThePlainPass() async throws {
        let speech = FakeSpeech()
        speech.reply = "Dana Whitfield, Bram Okafor, we can ship the build on Friday."
        speech.replyWithoutContext = "We can ship the build on Friday."
        #expect(try await transcribe(speech, team, screenNames: true) == "We can ship the build on Friday.")
        #expect(speech.receivedContexts == ["Dana Whitfield\nBram Okafor\nQuorvia", nil])
        // Without names from the screen the text is not checked.
        #expect(try await transcribe(speech, team, screenNames: false) == "Dana Whitfield, Bram Okafor, we can ship the build on Friday.")
        #expect(speech.receivedContexts.count == 3)
    }

    @Test func aFailedPlainPassKeepsATextThatMayBeAList() async throws {
        let speech = FakeSpeech()
        speech.reply = "Dana Whitfield, Bram Okafor, we can ship the build on Friday."
        speech.transcribeErrorWithoutContext = TestError()
        #expect(try await transcribe(speech, team, screenNames: true) == "Dana Whitfield, Bram Okafor, we can ship the build on Friday.")
        #expect(speech.receivedContexts == ["Dana Whitfield\nBram Okafor\nQuorvia", nil])
    }

    @Test func aTextThatIsNoListTakesItsDigitsFromTheSamePlainPass() async throws {
        let speech = FakeSpeech()
        speech.reply = "Quorvia，Kelpstone，在二零二六年发布。"
        speech.replyWithoutContext = "Quorvia，Kelpstone，在2026年发布。"
        #expect(try await transcribe(speech, labs, screenNames: true) == "Quorvia，Kelpstone，在2026年发布。")
        #expect(speech.receivedContexts == ["Quorvia\nThornsby Labs\nKelpstone\nLindqvist", nil])
    }

    @Test func anOrdinaryDictationWithScreenNamesIsTranscribedOnce() async throws {
        let speech = FakeSpeech()
        speech.reply = "我们周五和 Dana 一起发布 Quorvia。"
        speech.replyWithoutContext = "我们周五和达娜一起发布。"
        #expect(try await transcribe(speech, team, screenNames: true) == "我们周五和 Dana 一起发布 Quorvia。")
        #expect(speech.receivedContexts == ["Dana Whitfield\nBram Okafor\nQuorvia"])
    }
}
