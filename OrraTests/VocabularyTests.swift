import Foundation
import Testing
@testable import Orra

struct VocabularyTests {
    @Test func linesBecomeTermsTrimmedOnceEach() {
        let text = "  Claude Code \n\nQwen3-ASR\nclaude code\n阿里云\n  \n"
        #expect(Vocabulary.terms(from: text) == ["Claude Code", "Qwen3-ASR", "阿里云"])
    }

    @Test func longTermsAreCutAndTheListIsCapped() {
        let long = String(repeating: "a", count: 100)
        #expect(Vocabulary.terms(from: long) == [String(repeating: "a", count: Vocabulary.maximumLength)])
        let many = (1...150).map { "term\($0)" }.joined(separator: "\n")
        let terms = Vocabulary.terms(from: many)
        #expect(terms.count == Vocabulary.limit)
        #expect(terms.first == "term1")
    }

    @Test func theModelGetsOneTermPerLineOrNothing() {
        #expect(Vocabulary.context([]) == nil)
        #expect(Vocabulary.context(["Orra", "通义千问"]) == "Orra\n通义千问")
    }

    @Test func addingAndRemovingKeepTheListClean() {
        #expect(Vocabulary.adding("  Orra ", to: []) == ["Orra"])
        #expect(Vocabulary.adding("orra", to: ["Orra"]) == ["Orra"])
        #expect(Vocabulary.adding("   ", to: ["Orra"]) == ["Orra"])
        let full = (1...Vocabulary.limit).map { "term\($0)" }
        #expect(Vocabulary.adding("one more", to: full) == full)
        #expect(Vocabulary.removing("Orra", from: ["Orra", "通义千问"]) == ["通义千问"])
    }

    @Test func aCopiedWordCanBeAddedButNotALongText() {
        #expect(Vocabulary.candidate(fromClipboard: "  SGLang-Omni \n", in: []) == "SGLang-Omni")
        #expect(Vocabulary.candidate(fromClipboard: "sglang-omni", in: ["SGLang-Omni"]) == nil)
        #expect(Vocabulary.candidate(fromClipboard: "two\nlines", in: []) == nil)
        #expect(Vocabulary.candidate(fromClipboard: String(repeating: "a", count: 41), in: []) == nil)
        #expect(Vocabulary.candidate(fromClipboard: nil, in: []) == nil)
    }

    @MainActor
    @Test func theClipboardIsNotReadWhileDictating() {
        var reads = 0
        var dictating = true
        let clipboard = ClipboardWord(read: { reads += 1; return "SGLang-Omni" }, isDictating: { dictating }, vocabulary: { [] })
        clipboard.refresh()
        #expect(reads == 0)
        #expect(clipboard.word == nil)
        dictating = false
        clipboard.refresh()
        #expect(reads == 1)
        #expect(clipboard.word == "SGLang-Omni")
        clipboard.clear()
        #expect(clipboard.word == nil)
    }

    @Test func theVocabularyIsSavedOnThisMac() throws {
        let suite = "io.github.db-ol.OrraTests.vocabulary-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(VocabularyPreference.load(from: defaults).isEmpty)
        VocabularyPreference.save(["Orra", "通义千问"], to: defaults)
        #expect(VocabularyPreference.load(from: defaults) == ["Orra", "通义千问"])
    }

    @Test func onlyTermsInAnyOrderAndRepeatedCountAsAnEcho() {
        let terms = ["极速借呗", "IRS transcripts", "Pine Bluff", "瑞麒 G 六"]
        #expect(VocabularyEcho.isOnlyTerms("极速借呗。", of: terms))
        #expect(VocabularyEcho.isOnlyTerms("极速借呗", of: terms))
        #expect(VocabularyEcho.isOnlyTerms("I R S transcripts。极速借呗。Pine Bluff。", of: terms))
        #expect(VocabularyEcho.isOnlyTerms("pine bluff, PINE BLUFF! 極速借唄", of: terms))
        #expect(VocabularyEcho.isOnlyTerms("瑞麒G六，极速借呗", of: terms))
    }

    @Test func aLastTermCutShortStillCountsAfterAWholeOne() {
        let terms = ["极速借呗", "Equifax reports", "Rafael Rosen"]
        #expect(VocabularyEcho.isOnlyTerms("极速借呗。Equifax repo", of: terms))
        #expect(VocabularyEcho.isOnlyTerms("极速借呗。 Rafael R", of: terms))
        #expect(!VocabularyEcho.isOnlyTerms("Equifax", of: terms))
    }

    @Test func speechAroundTermsIsNotAnEcho() {
        let terms = ["Orra", "极速借呗", "a"]
        #expect(!VocabularyEcho.isOnlyTerms("我们用 Orra 写字", of: terms))
        #expect(!VocabularyEcho.isOnlyTerms("Orra is great", of: terms))
        #expect(!VocabularyEcho.isOnlyTerms("极速借呗怎么样", of: terms))
        #expect(!VocabularyEcho.isOnlyTerms("你好", of: terms))
    }

    @Test func emptyTextOrNoTermsIsNeverAnEcho() {
        #expect(!VocabularyEcho.isOnlyTerms("", of: ["Orra"]))
        #expect(!VocabularyEcho.isOnlyTerms("。，  ", of: ["Orra"]))
        #expect(!VocabularyEcho.isOnlyTerms("Orra", of: []))
        #expect(!VocabularyEcho.isOnlyTerms("Orra", of: ["。", "  "]))
    }
}
