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
    private func watch(_ field: ScriptedField, pasted: String) async -> Correction? {
        let watcher = CorrectionWatcher(environment: field.environment)
        var found: Correction?
        watcher.watch(pasted: pasted, in: 42) { found = $0 }
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
        watcher.watch(pasted: "我在用克劳德写代码", in: 42) { found.append($0) }
        for _ in 0..<20 { try? await Task.sleep(for: .milliseconds(5)) }
        for _ in 1...CorrectionWatcher.maximumWatches {
            watcher.watch(pasted: "不在这里", in: 42) { found.append($0) }
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

    @Test func aFieldWithoutThePastedTextIsLeftAlone() async {
        let field = ScriptedField(["别的内容", "别的内容改了"])
        #expect(await watch(field, pasted: "我在用克劳德写代码") == nil)
        #expect(field.reads == 1)
    }
}

@MainActor
struct CorrectionLearningTests {
    private let pair = Correction(heard: "克劳德", corrected: "Claude")

    private func makeLearning(isOn: Bool, field: ScriptedField, added: @escaping (String) -> Void = { _ in }) -> CorrectionLearning {
        CorrectionLearning(
            isOn: isOn,
            store: CorrectionStore(),
            watcher: CorrectionWatcher(environment: field.environment),
            saveSetting: { _ in },
            saveStore: { _ in },
            addToVocabulary: added
        )
    }

    @Test func whileOffNothingIsRead() async {
        let field = ScriptedField(["我在用克劳德写代码", "我在用Claude写代码"])
        let learning = makeLearning(isOn: false, field: field)
        learning.pasted("我在用克劳德写代码", in: 42)
        for _ in 0..<200 { await Task.yield() }
        #expect(field.reads == 0)
        #expect(learning.store.entries.isEmpty)
    }

    @Test func anAcceptedSuggestionJoinsTheVocabularyAndIsApplied() {
        var added: [String] = []
        let learning = makeLearning(isOn: true, field: ScriptedField([""])) { added.append($0) }
        learning.record(pair)
        #expect(learning.suggestions.isEmpty)
        learning.record(pair)
        #expect(learning.suggestions == [pair])
        learning.accept(pair)
        #expect(added == ["Claude"])
        #expect(learning.suggestions.isEmpty)
        #expect(learning.apply(to: "我在用克劳德") == "我在用Claude")
        learning.removeAll()
        #expect(learning.apply(to: "我在用克劳德") == "我在用克劳德")
    }

    @Test func turningLearningOffDuringAWatchRecordsNothing() async {
        let field = ScriptedField(["我在用克劳德写代码", "我在用克劳德写代码", "我在用Claude写代码"])
        let learning = makeLearning(isOn: true, field: field)
        learning.pasted("我在用克劳德写代码", in: 42)
        learning.isOn = false
        for _ in 0..<300 { await Task.yield() }
        #expect(learning.store.entries.isEmpty)
    }

    @Test func aRemovedPairIsNoLongerApplied() {
        let learning = makeLearning(isOn: true, field: ScriptedField([""]))
        learning.record(pair)
        learning.record(pair)
        learning.accept(pair)
        learning.remove(pair)
        #expect(learning.apply(to: "我在用克劳德") == "我在用克劳德")
        #expect(learning.store.accepted.isEmpty)
    }

    @Test func anIgnoredSuggestionStaysAway() {
        let learning = makeLearning(isOn: true, field: ScriptedField([""]))
        learning.record(pair)
        learning.record(pair)
        learning.dismiss(pair)
        learning.record(pair)
        #expect(learning.suggestions.isEmpty)
        #expect(learning.apply(to: "克劳德") == "克劳德")
    }
}
