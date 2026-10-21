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
    /// Which field of the app has the focus. A reader gives nil while the field it opened
    /// does not have it, as FieldReader.text does.
    var focus = 1
    /// The field that gets the focus while the paste lands, as when the user presses Tab
    /// right after the release.
    var focusAfterPaste: Int?
    /// A stand in for Orra's own process.
    let ownProcess: pid_t = 9

    init(_ texts: [String?]) {
        self.texts = texts
    }

    var environment: CorrectionWatcher.Environment {
        CorrectionWatcher.Environment(
            ownProcess: ownProcess,
            open: { [self] _ in
                guard opens else { return nil }
                let opened = focus
                return { [self] in
                    guard focus == opened else { return nil }
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
            sleep: { [self] duration in
                // The wait for the paste to land.
                if duration == .milliseconds(900), let focusAfterPaste {
                    focus = focusAfterPaste
                }
                await Task.yield()
            }
        )
    }
}

@MainActor
struct CorrectionWatcherTests {
    /// The word the watch reported to learn, nil when it reported none or a word to offer.
    private func watch(_ field: ScriptedField, pasted: String, in pid: pid_t = 42) async -> Correction? {
        if case .word(let correction) = await finding(field, pasted: pasted, in: pid) { return correction }
        return nil
    }

    private func finding(_ field: ScriptedField, pasted: String, in pid: pid_t = 42) async -> Finding? {
        let watcher = CorrectionWatcher(environment: field.environment)
        var found: Finding?
        watcher.watch(pasted: pasted, in: pid) { found = $0; _ = $1 }
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

    @Test func aPasteIntoOrrasOwnWindowStartsNoWatch() async {
        // Orra's own window is in front, so only the check of its process keeps the fix out.
        let field = ScriptedField(["我在用克劳德写代码", "我在用克劳德写代码", "我在用Claude写代码"])
        field.frontmost = field.ownProcess
        #expect(await watch(field, pasted: "我在用克劳德写代码", in: field.ownProcess) == nil)
        #expect(field.checks == 0)
        #expect(field.reads == 0)
    }

    @Test func aPasteIntoOrraPushesOutNoWatch() async {
        // Five watches in another app, then a paste into Orra before any of them starts.
        // The first watch still runs all its readings. The four others each read once,
        // since their text is not in the field.
        let field = ScriptedField(["我在用克劳德写代码"])
        let watcher = CorrectionWatcher(environment: field.environment)
        watcher.watch(pasted: "我在用克劳德写代码", in: 42) { _, _ in }
        for _ in 1..<CorrectionWatcher.maximumWatches {
            watcher.watch(pasted: "不在这里", in: 42) { _, _ in }
        }
        watcher.watch(pasted: "我在用克劳德写代码", in: field.ownProcess) { _, _ in }
        var lastReads = -1
        var quiet = 0
        for _ in 0..<1_000 where quiet < 40 {
            try? await Task.sleep(for: .milliseconds(5))
            quiet = field.reads == lastReads ? quiet + 1 : 0
            lastReads = field.reads
        }
        #expect(field.reads == 1 + CorrectionWatcher.readings + CorrectionWatcher.maximumWatches - 1)
        watcher.stop()
    }

    @Test func theLiveEnvironmentNamesOrrasOwnProcess() {
        #expect(CorrectionWatcher.Environment.live().ownProcess == getpid())
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
        let pasted = "克劳德觉得林悦很好"
        let field = ScriptedField([pasted, pasted, "Claude觉得林悦很好", "Claude觉得林悦很好", "Claude觉得霖悦很好"])
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
            Correction(heard: "林悦", corrected: "霖悦"),
        ])
        #expect(reports.allSatisfy { $0.1 == nil })
    }

    @Test func twoFixesFoundTogetherReportTheOfferBeforeTheWord() async {
        let pasted = "克劳德觉得林悦很好"
        let field = ScriptedField([pasted, pasted, "Claude觉得霖悦很好"])
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

    /// Every report of a watch over the field, with the finding it replaces.
    private func reports(_ field: ScriptedField, pasted: String) async -> [(Finding, Finding?)] {
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
        return reports
    }

    @Test func aWordTypedPastWithoutAPauseIsNeverReported() async {
        let pasted = "用 quen 3 跑"
        let field = ScriptedField([pasted, "用 Qwen 3 跑", "用 Qwen3 跑"])
        let found = await reports(field, pasted: pasted)
        #expect(found.map(\.0) == [.word(Correction(heard: "quen 3", corrected: "Qwen3"))])
        #expect(found.allSatisfy { $0.1 == nil })
    }

    @Test func aFixOverTheSameTextReplacesTheOneReported() async {
        let pasted = "用 quen 3 跑"
        let field = ScriptedField([pasted, "用 Qwen 3 跑", "用 Qwen 3 跑", "用 Qwen3 跑"])
        let found = await reports(field, pasted: pasted)
        let half = Finding.word(Correction(heard: "quen", corrected: "Qwen"))
        #expect(found.map(\.0) == [half, .word(Correction(heard: "quen 3", corrected: "Qwen3"))])
        #expect(found.map(\.1) == [nil, half])
    }

    @Test func aWordFoundAfterAnOfferOverTheSameTextReplacesTheOffer() async {
        let pasted = "通一千万"
        let field = ScriptedField([pasted, "通义千万", "通义千万", "通义千问"])
        let found = await reports(field, pasted: pasted)
        #expect(found.map(\.0.correction) == [
            Correction(heard: "通一", corrected: "通义"),
            Correction(heard: "通一千万", corrected: "通义千问"),
        ])
        #expect(found.map(\.0.isWord) == [false, true])
        #expect(found[1].1?.correction == Correction(heard: "通一", corrected: "通义"))
    }

    @Test func aFieldWithoutThePastedTextIsLeftAlone() async {
        let field = ScriptedField(["别的内容", "别的内容改了"])
        #expect(await watch(field, pasted: "我在用克劳德写代码") == nil)
        #expect(field.reads == 1)
    }

    @Test func aFieldFocusedWhileThePasteLandsIsNeverRead() async {
        // The user moves to another field of the same app before the paste lands. That field
        // holds the pasted words too.
        let field = ScriptedField(["我在用克劳德写代码", "我在用克劳德写代码", "我在用Claude写代码"])
        field.focusAfterPaste = 2
        #expect(await watch(field, pasted: "我在用克劳德写代码") == nil)
        #expect(field.reads == 0)
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

    @Test func undoOnANoticeStillShownAfterTheWordWasRemovedIsForGood() {
        let vocabulary = VocabularyBox()
        let learning = makeLearning(isOn: true, field: ScriptedField([""]), vocabulary: vocabulary)
        var learned: [CorrectionLearning.Learned] = []
        learning.onLearned = { learned.append($0) }
        learning.record(pair)
        // Removed in Settings while the notice with Undo is still on screen.
        vocabulary.words = []
        learning.removedFromVocabulary("Claude")
        learning.undo(learned[0])
        learning.record(pair)
        #expect(vocabulary.words.isEmpty)
        #expect(learned.count == 1)
        #expect(learning.store.state(of: pair) == .dismissed)
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

    /// Waits until the field's reads have stopped for a while.
    private func waitForReads(_ field: ScriptedField) async {
        var lastReads = -1
        var quiet = 0
        for _ in 0..<1_000 where quiet < 40 {
            try? await Task.sleep(for: .milliseconds(5))
            quiet = field.reads == lastReads ? quiet + 1 : 0
            lastReads = field.reads
        }
    }

    /// After a cleanup, a fix of a word the speech model wrote is learned, and a fix of a
    /// word only the cleanup model wrote is not.
    @Test func afterACleanupOnlyFixesOfDictatedWordsAreLearned() async {
        let cleaned = "我在用克劳德写代码"
        let field = ScriptedField([cleaned, cleaned, "我在用Claude写代码"])
        let learning = makeLearning(isOn: true, field: field)
        learning.pasted(cleaned, in: 42, beforeCleanup: "我在用那个克劳德写代码")
        await waitForReads(field)
        #expect(accepted(learning) == [pair])

        // Here the cleanup model wrote 克劳德, so fixing it teaches nothing about the speech.
        let other = ScriptedField([cleaned, cleaned, "我在用Claude写代码"])
        let vocabulary = VocabularyBox()
        let second = makeLearning(isOn: true, field: other, vocabulary: vocabulary)
        second.pasted(cleaned, in: 42, beforeCleanup: "我在用 cloud 写代码")
        await waitForReads(other)
        #expect(second.store.entries.isEmpty)
        #expect(vocabulary.words.isEmpty)
    }

    /// Paste Original Text over a cleaned paste ends that paste's watch, so the text it
    /// puts back is not learned as a correction.
    @Test func pastingTheOriginalEndsTheWatchOfTheCleanedPaste() async {
        let cleaned = "我在用克劳德写代码"
        let field = ScriptedField([cleaned, cleaned, cleaned, "我在用Claude写代码"])
        let learning = makeLearning(isOn: true, field: field)
        learning.pasted(cleaned, in: 42, beforeCleanup: "我在用那个克劳德写代码")
        for _ in 0..<1_000 where field.reads < 1 {
            await Task.yield()
        }
        learning.pastedOriginal(replacing: cleaned)
        await waitForReads(field)
        #expect(field.reads < 3)
        #expect(learning.store.entries.isEmpty)
    }

    // MARK: Replacements

    /// Only pairs the user kept replace words, and only while learning is on.
    @Test func replacementPairsAreTheKeptPairsWhileLearningIsOn() {
        let vocabulary = VocabularyBox()
        let learning = makeLearning(isOn: true, field: ScriptedField([""]), vocabulary: vocabulary)
        var learned: [CorrectionLearning.Learned] = []
        learning.onLearned = { learned.append($0) }
        learning.record(pair)
        let orra = Correction(heard: "Ora", corrected: "Orra")
        learning.record(orra)
        let suggestion = WordSuggestion(change: Correction(heard: "一", corrected: "义"), pair: Correction(heard: "通一千问", corrected: "通义千问"))
        learning.decline(suggestion)
        #expect(Set(learning.replacementPairs) == [pair, orra])
        // Undone.
        learning.undo(learned[1])
        #expect(learning.replacementPairs == [pair])
        // Taken out of the vocabulary.
        vocabulary.words.removeAll { $0 == "Claude" }
        learning.removedFromVocabulary("Claude")
        #expect(learning.replacementPairs.isEmpty)
        learning.record(pair)
        #expect(learning.replacementPairs == [pair])
        learning.isOn = false
        #expect(learning.replacementPairs.isEmpty)
    }

    private let replacedClaude = Replacement(span: 3..<9, heard: "克劳德", corrected: "Claude", pair: Correction(heard: "克劳德", corrected: "Claude"))

    /// The user puts back what the model wrote: the pair stops replacing, the word stays,
    /// and Orra's word is not taken for a mishearing of the model's.
    @Test func puttingBackAReplacedWordForgetsItsPair() async {
        let pasted = "我在用Claude写代码"
        let field = ScriptedField([pasted, pasted, "我在用克劳德写代码"])
        let vocabulary = VocabularyBox()
        let learning = makeLearning(isOn: true, field: field, vocabulary: vocabulary)
        learning.record(pair)
        learning.pasted(pasted, in: 42, replacements: [replacedClaude])
        await waitForReads(field)
        #expect(learning.store.entries.isEmpty)
        #expect(learning.replacementPairs.isEmpty)
        #expect(vocabulary.words == ["Claude"])
    }

    /// A fix of a replaced word is learned with what the model wrote. The two pairs for 克劳德
    /// then disagree, so neither replaces it any more.
    @Test func aFixOfAReplacedWordIsLearnedWithTheHeardSpelling() async {
        let pasted = "我在用Claude写代码"
        let field = ScriptedField([pasted, pasted, "我在用Clyde写代码"])
        let vocabulary = VocabularyBox()
        let learning = makeLearning(isOn: true, field: field, vocabulary: vocabulary)
        learning.record(pair)
        learning.pasted(pasted, in: 42, replacements: [replacedClaude])
        await waitForReads(field)
        let clyde = Correction(heard: "克劳德", corrected: "Clyde")
        #expect(Set(accepted(learning)) == [pair, clyde])
        #expect(vocabulary.words == ["Claude", "Clyde"])
        #expect(WordReplacement.usablePairs(learning.replacementPairs, vocabulary: vocabulary.words, ordinary: OrdinaryWords([])).isEmpty)
    }

    /// After a cleanup the replaced words cannot be placed in the paste, so a fix that
    /// touches one is not learned.
    @Test func afterACleanupAFixOfAReplacedWordIsNotLearned() async {
        let cleaned = "我们在用Claude写代码"
        let field = ScriptedField([cleaned, cleaned, "我们在用Clyde写代码"])
        let vocabulary = VocabularyBox()
        let learning = makeLearning(isOn: true, field: field, vocabulary: vocabulary)
        learning.record(pair)
        learning.pasted(cleaned, in: 42, beforeCleanup: "我在用Claude写代码", replacements: [replacedClaude])
        await waitForReads(field)
        #expect(accepted(learning) == [pair])
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
