import Foundation
import Testing
@testable import Orra

/// A field whose text changes on a script, read by a watcher that never waits. Reads no
/// real app.
@MainActor
final class ScriptedField {
    var texts: [String?]
    var frontmost: pid_t? = 42
    var secureInputHolder: pid_t?
    /// While the read count is in this range, another app is in front.
    var away: Range<Int>?
    /// While the number of front app checks is in this range, another app is in front.
    var awayChecks: Range<Int>?
    private(set) var checks = 0
    var opens = true
    private(set) var reads = 0

    init(_ texts: [String?]) {
        self.texts = texts
    }

    var environment: CorrectionWatcher.Environment {
        CorrectionWatcher.Environment(
            open: { [self] _ in
                guard opens else { return nil }
                return { [self] in
                    defer { reads += 1 }
                    return texts[min(reads, texts.count - 1)]
                }
            },
            frontmost: { [self] in
                defer { checks += 1 }
                if let away, away.contains(reads) { return 7 }
                if let awayChecks, awayChecks.contains(checks) { return 7 }
                return frontmost
            },
            secureInputHolder: { [self] in secureInputHolder },
            sleep: { _ in await Task.yield() }
        )
    }
}

@MainActor
struct CorrectionWatcherTests {
    /// The word the watch reported to learn, nil when it reported none or a word to offer.
    private func watch(_ field: ScriptedField, pasted: String) async -> Correction? {
        if case .word(let correction) = await finding(field, pasted: pasted) { return correction }
        return nil
    }

    private func finding(_ field: ScriptedField, pasted: String) async -> Finding? {
        let watcher = CorrectionWatcher(environment: field.environment)
        var found: Finding?
        watcher.watch(pasted: pasted, in: 42) { found = $0; _ = $1 }
        // Waits until a correction comes, or the reads have stopped for a while, since the
        // comparison runs off the main actor.
        var lastReads = -1
        var quiet = 0
        for _ in 0..<1_000 where found == nil && quiet < 40 {
            try? await Task.sleep(for: .milliseconds(5))
            quiet = field.reads == lastReads ? quiet + 1 : 0
            lastReads = field.reads
        }
        return found
    }

    @Test func aFixedWordIsReported() async {
        let field = ScriptedField(["我在用克劳德写代码", "我在用克劳德写代码", "我在用Claude写代码"])
        #expect(await watch(field, pasted: "我在用克劳德写代码") == Correction(heard: "克劳德", corrected: "Claude"))
    }

    @Test func leavingTheAppEndsTheWatch() async {
        let field = ScriptedField(["我在用克劳德写代码", "我在用克劳德写代码", "我在用Claude写代码"])
        field.frontmost = 7
        #expect(await watch(field, pasted: "我在用克劳德写代码") == nil)
        #expect(field.reads == 0)
    }

    @Test func secureInputInTheAppEndsTheWatch() async {
        let field = ScriptedField(["我在用克劳德写代码", "我在用Claude写代码"])
        field.secureInputHolder = 42
        #expect(await watch(field, pasted: "我在用克劳德写代码") == nil)
        #expect(field.reads == 0)
    }

    @Test func sendingAChatMessageKeepsTheFixMadeBefore() async {
        let field = ScriptedField(["我在用克劳德写代码", "我在用克劳德写代码", "我在用Claude写代码", ""])
        #expect(await watch(field, pasted: "我在用克劳德写代码") == Correction(heard: "克劳德", corrected: "Claude"))
    }

    @Test func awayFromTheAppNothingIsRead() async {
        let field = ScriptedField(["我在用克劳德写代码", "我在用克劳德写代码", "我在用克劳德写代码", "我在用Claude写代码"])
        field.away = 2..<Int.max
        #expect(await watch(field, pasted: "我在用克劳德写代码") == nil)
        #expect(field.reads == 2)
    }

    @Test func aFixMadeAfterComingBackIsLearned() async {
        // Another app is in front for five checks after the first reading, then the user
        // comes back and fixes the word.
        let field = ScriptedField(["我在用克劳德写代码", "我在用克劳德写代码", "我在用Claude写代码"])
        field.awayChecks = 2..<7
        #expect(await watch(field, pasted: "我在用克劳德写代码") == Correction(heard: "克劳德", corrected: "Claude"))
        #expect(field.checks > 7)
    }

    @Test func aFieldThatLostTheFocusIsReadAgainWhenItHasItBack() async {
        // The reader gives nil while the pasted field does not have the focus.
        let field = ScriptedField(["我在用克劳德写代码", "我在用克劳德写代码", nil, "我在用Claude写代码"])
        #expect(await watch(field, pasted: "我在用克劳德写代码") == Correction(heard: "克劳德", corrected: "Claude"))
    }

    @Test func aWatchPushedOutByANewPasteReportsWhatItFound() async {
        let first = ScriptedField(["我在用克劳德写代码", "我在用Claude写代码"])
        let watcher = CorrectionWatcher(environment: first.environment)
        var found: [Correction] = []
        watcher.watch(pasted: "我在用克劳德写代码", in: 42) { found.append($0.correction); _ = $1 }
        for _ in 0..<20 { try? await Task.sleep(for: .milliseconds(5)) }
        for _ in 1...CorrectionWatcher.maximumWatches {
            watcher.watch(pasted: "不在这里", in: 42) { found.append($0.correction); _ = $1 }
        }
        for _ in 0..<200 where found.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(found == [Correction(heard: "克劳德", corrected: "Claude")])
        watcher.stop()
    }

    @Test func fixingAnEarlierLineAfterMoreDictationsIsLearned() async {
        // Three dictations of the same words, then the first line is fixed.
        let field = ScriptedField([
            "同意千万。",
            "同意千万。\n同意千万。",
            "同意千万。\n同意千万。\n同意千万。",
            "通义千问。\n同意千万。\n同意千万。",
        ])
        #expect(await watch(field, pasted: "同意千万。") == Correction(heard: "同意千万", corrected: "通义千问"))
    }

    @Test func theWatchEndsAfterThreeMinutesOfReadings() async {
        let field = ScriptedField((0...200).map { "你好世界" + String(repeating: "啊", count: $0) })
        _ = await watch(field, pasted: "你好世界")
        #expect(field.reads == 1 + CorrectionWatcher.readings)
    }

    @Test func aFieldThatIsNotPlainTextIsNeverRead() async {
        let field = ScriptedField(["我在用克劳德写代码"])
        field.opens = false
        #expect(await watch(field, pasted: "我在用克劳德写代码") == nil)
        #expect(field.reads == 0)
    }

    @Test func aFixIsReportedOnceSoonAfterTheFieldIsQuiet() async {
        let field = ScriptedField(["我在用克劳德写代码", "我在用克劳德写代码", "我在用Claude写代码"])
        let watcher = CorrectionWatcher(environment: field.environment)
        var found: [Correction] = []
        var readsWhenFound: Int?
        watcher.watch(pasted: "我在用克劳德写代码", in: 42) { correction, _ in
            found.append(correction.correction)
            readsWhenFound = readsWhenFound ?? field.reads
        }
        var lastReads = -1
        var quiet = 0
        for _ in 0..<1_000 where quiet < 40 {
            try? await Task.sleep(for: .milliseconds(5))
            quiet = field.reads == lastReads ? quiet + 1 : 0
            lastReads = field.reads
        }
        #expect(found == [Correction(heard: "克劳德", corrected: "Claude")])
        // The fix is the third read, reported after three quiet readings, not after 180.
        #expect(readsWhenFound == 3 + CorrectionWatcher.quietReadings)
    }

    @Test func goingBackAndForthOverAWordLeavesTheLastPair() async {
        // Fixed, then a different spelling, then the first one again, each left for a while.
        let fixed = "我在用Claude写代码", other = "我在用Claud写代码"
        let field = ScriptedField(["我在用克劳德写代码", fixed, fixed, fixed, fixed, other, other, other, other, fixed])
        let watcher = CorrectionWatcher(environment: field.environment)
        let vocabulary = CorrectionLearningTests.VocabularyBox()
        let learning = CorrectionLearning(
            isOn: true, store: CorrectionStore(), watcher: watcher,
            saveSetting: { _ in }, saveStore: { _ in },
            addToVocabulary: { vocabulary.words.append($0); return .added },
            removeFromVocabulary: { word in vocabulary.words.removeAll { $0 == word } }
        )
        learning.pasted("我在用克劳德写代码", in: 42)
        var lastReads = -1
        var quiet = 0
        for _ in 0..<1_000 where quiet < 40 {
            try? await Task.sleep(for: .milliseconds(5))
            quiet = field.reads == lastReads ? quiet + 1 : 0
            lastReads = field.reads
        }
        #expect(learning.store.entries.map(\.correction) == [Correction(heard: "克劳德", corrected: "Claude")])
        #expect(vocabulary.words == ["Claude"])
    }

    @Test func finishingAHalfTypedWordReportsItAsReplacingTheHalf() async {
        let half = "我在用Claud写代码", done = "我在用Claude写代码"
        let field = ScriptedField(["我在用克劳德写代码", half, half, half, half, done])
        let watcher = CorrectionWatcher(environment: field.environment)
        var reports: [(Correction, Correction?)] = []
        watcher.watch(pasted: "我在用克劳德写代码", in: 42) { reports.append(($0.correction, $1?.correction)) }
        var lastReads = -1
        var quiet = 0
        for _ in 0..<1_000 where quiet < 40 {
            try? await Task.sleep(for: .milliseconds(5))
            quiet = field.reads == lastReads ? quiet + 1 : 0
            lastReads = field.reads
        }
        let first = Correction(heard: "克劳德", corrected: "Claud")
        #expect(reports.map(\.0) == [first, Correction(heard: "克劳德", corrected: "Claude")])
        #expect(reports.map(\.1) == [nil, first])
    }

    @Test func twoFixesInOnePasteAreReportedApartWithTheLearnedWordLast() async {
        let pasted = "克劳德觉得陈阳很好"
        let field = ScriptedField([pasted, pasted, "Claude觉得陈阳很好", "Claude觉得陈阳很好", "Claude觉得晨阳很好"])
        let watcher = CorrectionWatcher(environment: field.environment)
        var reports: [(Finding, Finding?)] = []
        watcher.watch(pasted: pasted, in: 42) { reports.append(($0, $1)) }
        var lastReads = -1
        var quiet = 0
        for _ in 0..<1_000 where quiet < 40 {
            try? await Task.sleep(for: .milliseconds(5))
            quiet = field.reads == lastReads ? quiet + 1 : 0
            lastReads = field.reads
        }
        // The word first, once the field was quiet, then the offered name on its own.
        #expect(reports.map(\.0.correction) == [
            Correction(heard: "克劳德", corrected: "Claude"),
            Correction(heard: "陈阳", corrected: "晨阳"),
        ])
        #expect(reports.allSatisfy { $0.1 == nil })
    }

    @Test func twoFixesFoundTogetherReportTheOfferBeforeTheWord() async {
        let pasted = "克劳德觉得陈阳很好"
        let field = ScriptedField([pasted, pasted, "Claude觉得晨阳很好"])
        let watcher = CorrectionWatcher(environment: field.environment)
        var reports: [Finding] = []
        watcher.watch(pasted: pasted, in: 42) { reports.append($0); _ = $1 }
        var lastReads = -1
        var quiet = 0
        for _ in 0..<1_000 where quiet < 40 {
            try? await Task.sleep(for: .milliseconds(5))
            quiet = field.reads == lastReads ? quiet + 1 : 0
            lastReads = field.reads
        }
        #expect(reports.map(\.isWord) == [false, true])
    }

    @Test func aFieldWithoutThePastedTextIsLeftAlone() async {
        let field = ScriptedField(["别的内容", "别的内容改了"])
        #expect(await watch(field, pasted: "我在用克劳德写代码") == nil)
        #expect(field.reads == 1)
    }
}

@MainActor
struct CorrectionLearningTests {
    private let pair = Correction(heard: "克劳德", corrected: "Claude")

    private func makeLearning(isOn: Bool, field: ScriptedField, vocabulary: VocabularyBox = VocabularyBox()) -> CorrectionLearning {
        CorrectionLearning(
            isOn: isOn,
            store: CorrectionStore(),
            watcher: CorrectionWatcher(environment: field.environment),
            saveSetting: { _ in },
            saveStore: { _ in },
            addToVocabulary: { word in
                guard !vocabulary.words.contains(word) else { return .alreadyThere }
                guard vocabulary.words.count < vocabulary.limit else { return .full }
                vocabulary.words.append(word)
                return .added
            },
            removeFromVocabulary: { word in vocabulary.words.removeAll { $0 == word } }
        )
    }

    final class VocabularyBox {
        var words: [String] = []
        var limit = 100
    }

    @Test func whileOffNothingIsRead() async {
        let field = ScriptedField(["我在用克劳德写代码", "我在用Claude写代码"])
        let learning = makeLearning(isOn: false, field: field)
        learning.pasted("我在用克劳德写代码", in: 42)
        for _ in 0..<200 { await Task.yield() }
        #expect(field.reads == 0)
        #expect(learning.store.entries.isEmpty)
    }

    private var accepted: (CorrectionLearning) -> [Correction] {
        { $0.store.entries.filter { $0.state == .accepted }.map(\.correction) }
    }

    @Test func theFirstFixAddsTheWordAndTellsTheUser() {
        let vocabulary = VocabularyBox()
        let learning = makeLearning(isOn: true, field: ScriptedField([""]), vocabulary: vocabulary)
        var learned: [CorrectionLearning.Learned] = []
        learning.onLearned = { learned.append($0) }
        learning.record(pair)
        #expect(learned == [CorrectionLearning.Learned(correction: pair, pairs: [pair], outcome: .added)])
        #expect(vocabulary.words == ["Claude"])
        learning.removeAll()
        #expect(learning.store.entries.isEmpty)
        #expect(vocabulary.words == ["Claude"])
    }

    @Test func turningLearningOffDuringAWatchRecordsNothing() async {
        let field = ScriptedField(["我在用克劳德写代码", "我在用克劳德写代码", "我在用Claude写代码"])
        let learning = makeLearning(isOn: true, field: field)
        learning.pasted("我在用克劳德写代码", in: 42)
        learning.isOn = false
        for _ in 0..<300 { await Task.yield() }
        #expect(learning.store.entries.isEmpty)
    }

    @Test func undoTakesTheWordOutAndItStaysAway() {
        let vocabulary = VocabularyBox()
        let learning = makeLearning(isOn: true, field: ScriptedField([""]), vocabulary: vocabulary)
        var learned: [CorrectionLearning.Learned] = []
        learning.onLearned = { learned.append($0) }
        learning.record(pair)
        learning.undo(learned[0])
        #expect(vocabulary.words.isEmpty)
        learning.record(pair)
        learning.record(Correction(heard: "可劳德", corrected: "Claude"))
        #expect(learned.count == 1)
        #expect(vocabulary.words.isEmpty)
        #expect(accepted(learning).isEmpty)
    }

    @Test func aNewMishearingOfALearnedWordIsTakenQuietly() {
        let vocabulary = VocabularyBox()
        let learning = makeLearning(isOn: true, field: ScriptedField([""]), vocabulary: vocabulary)
        var learned: [CorrectionLearning.Learned] = []
        learning.onLearned = { learned.append($0) }
        learning.record(pair)
        let other = Correction(heard: "可劳德", corrected: "Claude")
        learning.record(other)
        #expect(learned.count == 1)
        #expect(Set(accepted(learning)) == [pair, other])
    }

    @Test func aLearnedWordTheUserRemovesIsLearnedAgainWithTheNotice() {
        let vocabulary = VocabularyBox()
        let learning = makeLearning(isOn: true, field: ScriptedField([""]), vocabulary: vocabulary)
        var learned: [CorrectionLearning.Learned] = []
        learning.onLearned = { learned.append($0) }
        learning.record(pair)
        learning.record(Correction(heard: "可劳德", corrected: "Claude"))
        // Removed in Settings, in another case than learned.
        vocabulary.words = []
        learning.removedFromVocabulary("claude")
        #expect(accepted(learning).isEmpty)
        learning.record(pair)
        #expect(vocabulary.words == ["Claude"])
        #expect(learned.map(\.correction) == [pair, pair])
        #expect(learned.last?.pairs == [pair])
        // Undo after that is still for good.
        learning.undo(learned[1])
        learning.removedFromVocabulary("Claude")
        learning.record(pair)
        #expect(vocabulary.words.isEmpty)
        #expect(learned.count == 2)
    }

    @Test func removingAWordThatWasNeverLearnedChangesNothing() {
        let vocabulary = VocabularyBox()
        let learning = makeLearning(isOn: true, field: ScriptedField([""]), vocabulary: vocabulary)
        var learned: [CorrectionLearning.Learned] = []
        learning.onLearned = { learned.append($0) }
        learning.record(pair)
        learning.undo(learned[0])
        let before = learning.store
        learning.removedFromVocabulary("Claude")
        learning.removedFromVocabulary("Orra")
        #expect(learning.store == before)
    }

    @Test func learnedWordsRemovedBeforeAreForgottenAtLaunch() {
        // A store from before removal forgot words: Claude was taken out of the vocabulary,
        // Orra is still there.
        var store = CorrectionStore()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let orra = Correction(heard: "Ora", corrected: "Orra")
        store.record(pair, at: now)
        store.record(orra, at: now)
        _ = store.acceptSeen(of: "Claude")
        _ = store.acceptSeen(of: "Orra")
        var saved: [CorrectionStore] = []
        let learning = CorrectionLearning(
            isOn: true, store: store, watcher: CorrectionWatcher(environment: ScriptedField([""]).environment),
            saveSetting: { _ in }, saveStore: { saved.append($0) },
            addToVocabulary: { _ in .added }, removeFromVocabulary: { _ in },
            isInVocabulary: { $0.lowercased() == "orra" }
        )
        learning.forgetRemovedWords()
        #expect(learning.store.entries.map(\.correction) == [orra])
        #expect(saved.count == 1)
        learning.forgetRemovedWords()
        #expect(saved.count == 1)
    }

    @Test func separateFixesInOnePasteAreEachKept() async {
        // 克劳德 to Claude is learned, and 嘛 to 吗 is grammar.
        let pasted = "我在用克劳德写代码嘛"
        let field = ScriptedField([pasted, pasted, "我在用Claude写代码吗"])
        let vocabulary = VocabularyBox()
        let learning = makeLearning(isOn: true, field: field, vocabulary: vocabulary)
        var learned: [CorrectionLearning.Learned] = []
        var offered: [WordSuggestion] = []
        learning.onLearned = { learned.append($0) }
        learning.onSuggest = { offered.append($0) }
        learning.pasted(pasted, in: 42)
        var lastReads = -1
        var quiet = 0
        for _ in 0..<1_000 where quiet < 40 {
            try? await Task.sleep(for: .milliseconds(5))
            quiet = field.reads == lastReads ? quiet + 1 : 0
            lastReads = field.reads
        }
        learning.isOn = false
        #expect(learned.map(\.correction) == [pair])
        #expect(offered.isEmpty)
        #expect(vocabulary.words == ["Claude"])
    }

    @Test func undoKeepsAWordTheUserHadAddedBefore() {
        let vocabulary = VocabularyBox()
        vocabulary.words = ["Claude"]
        let learning = makeLearning(isOn: true, field: ScriptedField([""]), vocabulary: vocabulary)
        var learned: [CorrectionLearning.Learned] = []
        learning.onLearned = { learned.append($0) }
        learning.record(pair)
        #expect(learned.isEmpty)
        #expect(vocabulary.words == ["Claude"])
    }

    @Test func aFullVocabularyIsReportedAndTheWordIsAddedLater() {
        let vocabulary = VocabularyBox()
        vocabulary.limit = 0
        let learning = makeLearning(isOn: true, field: ScriptedField([""]), vocabulary: vocabulary)
        var learned: [CorrectionLearning.Learned] = []
        learning.onLearned = { learned.append($0) }
        learning.record(pair)
        #expect(learned.map(\.outcome) == [.vocabularyFull])
        #expect(accepted(learning).isEmpty)
        vocabulary.limit = 100
        learning.record(pair)
        #expect(learned.map(\.outcome) == [.vocabularyFull, .added])
        #expect(vocabulary.words == ["Claude"])
    }

    @Test func aHalfTypedFixIsReplacedByTheFinishedOne() {
        let vocabulary = VocabularyBox()
        let learning = makeLearning(isOn: true, field: ScriptedField([""]), vocabulary: vocabulary)
        var learned: [CorrectionLearning.Learned] = []
        learning.onLearned = { learned.append($0) }
        let half = Correction(heard: "克劳德", corrected: "Claud")
        learning.record(half)
        learning.record(pair, replacing: half)
        #expect(vocabulary.words == ["Claude"])
        #expect(accepted(learning) == [pair])
        #expect(learning.store.entries.map(\.correction) == [pair])
        #expect(learned.map(\.correction) == [half, pair])
    }
}
