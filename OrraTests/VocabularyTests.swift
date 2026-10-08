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

    @Test func theVocabularyIsSavedOnThisMac() throws {
        let suite = "io.github.db-ol.OrraTests.vocabulary-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(VocabularyPreference.load(from: defaults).isEmpty)
        VocabularyPreference.save(["Orra", "通义千问"], to: defaults)
        #expect(VocabularyPreference.load(from: defaults) == ["Orra", "通义千问"])
    }
}
