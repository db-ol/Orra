import Foundation
import Testing
@testable import Orra

/// Vocabulary words with the same dates, for tests.
func vocabularyWords(_ texts: String..., added: Date = .distantPast) -> [VocabularyWord] {
    vocabularyWords(texts, added: added)
}

func vocabularyWords(_ texts: [String], added: Date = .distantPast) -> [VocabularyWord] {
    texts.map { VocabularyWord($0, added: added) }
}

struct VocabularyTests {
    private let day: TimeInterval = 24 * 60 * 60

    @Test func linesBecomeTermsTrimmedOnceEach() {
        let text = "  Claude Code \n\nQwen3-ASR\nclaude code\n阿里云\n  \n"
        #expect(Vocabulary.terms(from: text) == ["Claude Code", "Qwen3-ASR", "阿里云"])
    }

    @Test func longTermsAreCutAndOnlyRunawayListsAreCapped() {
        let long = String(repeating: "a", count: 100)
        #expect(Vocabulary.terms(from: long) == [String(repeating: "a", count: Vocabulary.maximumLength)])
        let many = (1...1_000).map { "term\($0)" }.joined(separator: "\n")
        #expect(Vocabulary.terms(from: many).count == 1_000)
        let runaway = (1...(Vocabulary.maximumCount + 10)).map { "term\($0)" }
        let terms = Vocabulary.terms(from: runaway)
        #expect(terms.count == Vocabulary.maximumCount)
        #expect(terms.first == "term1")
    }

    @Test func theModelGetsOneTermPerLineOrNothing() {
        #expect(Vocabulary.context([]) == nil)
        #expect(Vocabulary.context(["Orra", "通义千问"]) == "Orra\n通义千问")
    }

    @Test func addingAndRemovingKeepTheListClean() {
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(Vocabulary.adding("  Orra ", to: [], at: now) == [VocabularyWord("Orra", added: now)])
        let orra = vocabularyWords("Orra")
        #expect(Vocabulary.adding("orra", to: orra, at: now) == orra)
        #expect(Vocabulary.adding("   ", to: orra, at: now) == orra)
        let many = vocabularyWords((1...1_000).map { "term\($0)" })
        #expect(Vocabulary.adding("one more", to: many, at: now).count == 1_001)
        let full = vocabularyWords((1...Vocabulary.maximumCount).map { "term\($0)" })
        #expect(Vocabulary.adding("one more", to: full, at: now) == full)
        #expect(Vocabulary.removing(["orra"], from: vocabularyWords("Orra", "通义千问")) == vocabularyWords("通义千问"))
    }

    @Test func aShortListReachesTheModelWhole() {
        let words = vocabularyWords("Orra", "通义千问")
        #expect(Vocabulary.forModel(words) == ["Orra", "通义千问"])
    }

    @Test func theModelGetsTheWordsAddedOrUsedMostRecently() {
        let start = Date(timeIntervalSince1970: 0)
        // Added one day apart, so later words are more recent.
        var words = (0..<250).map { VocabularyWord("term\($0)", added: start.addingTimeInterval(Double($0) * day)) }
        // An early word used after every word was added counts as recent.
        words[3].lastUsed = start.addingTimeInterval(400 * day)
        // A use older than the word's own addition changes nothing.
        words[10].lastUsed = start
        let chosen = Vocabulary.forModel(words)
        #expect(chosen.count == Vocabulary.modelLimit)
        #expect(chosen.first == "term3")
        #expect(chosen.dropFirst() == ArraySlice((51..<250).map { "term\($0)" }))
        #expect(!chosen.contains("term10"))
        #expect(!chosen.contains("term50"))
    }

    @Test func amongEquallyRecentWordsTheOneAddedLaterIsChosen() {
        let same = Date(timeIntervalSince1970: 1_000)
        // As after the move from 0.1.0, when every word has the same date.
        let words = vocabularyWords((0..<5).map { "term\($0)" }, added: same)
        #expect(Vocabulary.forModel(words, limit: 3) == ["term2", "term3", "term4"])
        var used = words
        used[0].lastUsed = same.addingTimeInterval(1)
        #expect(Vocabulary.forModel(used, limit: 3) == ["term0", "term3", "term4"])
    }

    @Test func aPasteDatesTheWordsItHoldsIgnoringCase() {
        let then = Date(timeIntervalSince1970: 1_000)
        let now = Date(timeIntervalSince1970: 2_000)
        let words = vocabularyWords("Orra", "通义千问", "IRS", "Qwen3", added: then)
        let marked = Vocabulary.markingUsed(in: "ORRA 用了通义千问，firs 不算，qwen3。", words, at: now)
        #expect(marked.map(\.lastUsed) == [now, now, nil, now])
        #expect(marked.map(\.text) == words.map(\.text))
        #expect(marked.map(\.added) == words.map(\.added))
        // Inside a longer Latin word it is not the word.
        #expect(Vocabulary.markingUsed(in: "Orrange", words, at: now).allSatisfy { $0.lastUsed == nil })
        // A later match counts when an earlier one is inside a word.
        #expect(Vocabulary.markingUsed(in: "Orrange and Orra", words, at: now)[0].lastUsed == now)
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

    @Test func theVocabularyIsSavedOnThisMacWithItsDates() throws {
        let suite = "io.github.db-ol.OrraTests.vocabulary-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(VocabularyPreference.load(from: defaults).isEmpty)
        let words = [
            VocabularyWord("Orra", added: Date(timeIntervalSince1970: 1_000), lastUsed: Date(timeIntervalSince1970: 3_000)),
            VocabularyWord("通义千问", added: Date(timeIntervalSince1970: 2_000))
        ]
        VocabularyPreference.save(words, to: defaults)
        #expect(VocabularyPreference.load(from: defaults) == words)
    }

    @Test func theWordsOfOrra010AreTakenOverWithoutLosingAny() throws {
        let suite = "io.github.db-ol.OrraTests.vocabulary-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let old = (1...100).map { "term\($0)" } + ["Orra", "通义千问"]
        defaults.set(old, forKey: VocabularyPreference.legacyKey)
        let moved = Date(timeIntervalSince1970: 5_000)
        let words = VocabularyPreference.load(from: defaults, now: moved)
        #expect(words.map(\.text) == old)
        #expect(words.allSatisfy { $0.added == moved && $0.lastUsed == nil })
        // Once saved, the new list is what loads, and the old one stays for 0.1.0.
        let later = Vocabulary.adding("Qwen", to: words, at: moved.addingTimeInterval(1))
        VocabularyPreference.save(later, to: defaults)
        #expect(VocabularyPreference.load(from: defaults, now: .distantFuture) == later)
        #expect(defaults.stringArray(forKey: VocabularyPreference.legacyKey) == old)
    }

    @Test func anUnreadableSaveFallsBackToTheOlderList() throws {
        let suite = "io.github.db-ol.OrraTests.vocabulary-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["Orra"], forKey: VocabularyPreference.legacyKey)
        defaults.set(Data("not json".utf8), forKey: VocabularyPreference.defaultsKey)
        #expect(VocabularyPreference.load(from: defaults).map(\.text) == ["Orra"])
    }

    @MainActor
    @Test func tableRowsShowWhereAWordCameFromAndHowItWasMisheard() {
        var store = CorrectionStore()
        let date = Date(timeIntervalSince1970: 1_000)
        for heard in ["Aura", "Ora", "Aura"] {
            store.record(Correction(heard: heard, corrected: "Orra"), at: date)
        }
        _ = store.acceptSeen(of: "Orra")
        // Seen only, not learned.
        store.record(Correction(heard: "Quen", corrected: "Qwen"), at: date)
        let used = Date(timeIntervalSince1970: 9_000)
        let words = [VocabularyWord("orra", added: date), VocabularyWord("Qwen", added: date, lastUsed: used)]
        let rows = VocabularyList.rows(words, store: store)
        #expect(rows.map(\.isLearned) == [true, false])
        #expect(rows.map(\.heardAs) == ["Aura, Ora", ""])
        #expect(rows.map(\.lastUsed) == [nil, used])
        #expect(rows[1].lastActive == used)
    }

    @MainActor
    @Test func removingFromTheTableForgetsLearnedWords() {
        let controller = PushToTalkController(capture: FakeMicrophone().capture, transcription: FakeSpeech().transcription, insert: { _ in .pasted })
        let learning = CorrectionLearning(
            isOn: true,
            store: CorrectionStore(),
            watcher: CorrectionWatcher(),
            saveSetting: { _ in },
            saveStore: { _ in },
            addToVocabulary: { controller.addToVocabulary($0) },
            removeFromVocabulary: { controller.removeFromVocabulary([$0]) },
            isInVocabulary: { controller.vocabularyContains($0) }
        )
        var learned: [CorrectionLearning.Learned] = []
        learning.onLearned = { learned.append($0) }
        controller.addToVocabulary("Qwen")
        controller.addToVocabulary("通义千问")
        learning.record(Correction(heard: "Aura", corrected: "Orra"))
        #expect(controller.vocabulary.map(\.text) == ["Qwen", "通义千问", "Orra"])
        #expect(learning.store.acceptedWords == ["Orra"])
        VocabularyList.remove(["orra", "qwen"], pushToTalk: controller, learning: learning)
        #expect(controller.vocabulary.map(\.text) == ["通义千问"])
        #expect(learning.store.acceptedWords.isEmpty)
        // The next fix learns it again, with the notice.
        learning.record(Correction(heard: "Aura", corrected: "Orra"))
        #expect(learned.map(\.outcome) == [.added, .added])
        #expect(controller.vocabulary.map(\.text) == ["通义千问", "Orra"])
    }

    @MainActor
    @Test func theHeaderSaysHowManyWordsTheModelGets() {
        #expect(VocabularyList.summary(count: 1) == "1 word")
        #expect(VocabularyList.summary(count: 200) == "200 words")
        #expect(VocabularyList.summary(count: 236) == "236 words. Orra gives the 200 most recently added or used to the speech model.")
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

    @Test func traditionalCharactersMatchInMostlyEnglishText() {
        let terms = ["极速借呗", "IRS transcripts", "Pine Bluff", "Equifax reports", "Rafael Rosen"]
        #expect(VocabularyEcho.isOnlyTerms("Pine Bluff IRS transcripts Equifax reports Rafael Rosen 極速借唄", of: terms))
    }

    @Test func fullWidthLatinAndAccentsMatch() {
        #expect(VocabularyEcho.isOnlyTerms("ＯＲＲＡ", of: ["Orra"]))
        #expect(VocabularyEcho.isOnlyTerms("café", of: ["Cafe"]))
        #expect(VocabularyEcho.isOnlyTerms("Cafe", of: ["café"]))
    }

    @Test func emptyTextOrNoTermsIsNeverAnEcho() {
        #expect(!VocabularyEcho.isOnlyTerms("", of: ["Orra"]))
        #expect(!VocabularyEcho.isOnlyTerms("。，  ", of: ["Orra"]))
        #expect(!VocabularyEcho.isOnlyTerms("Orra", of: []))
        #expect(!VocabularyEcho.isOnlyTerms("Orra", of: ["。", "  "]))
    }
}
