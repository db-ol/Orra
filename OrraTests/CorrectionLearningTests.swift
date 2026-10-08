import Foundation
import Testing
@testable import Orra

/// A field whose text changes on a script, read by a watcher that never waits. Reads no
/// real app.
@MainActor
final class ScriptedField {
    var texts: [String]
    var frontmost: pid_t? = 42
    var secureInputHolder: pid_t?
    private(set) var reads = 0

    init(_ texts: [String]) {
        self.texts = texts
    }

    var environment: CorrectionWatcher.Environment {
        CorrectionWatcher.Environment(
            read: { [self] _ in
                defer { reads += 1 }
                return texts[min(reads, texts.count - 1)]
            },
            frontmost: { [self] in frontmost },
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
        for _ in 0..<500 where found == nil && field.reads < CorrectionWatcher.readings + 1 {
            await Task.yield()
        }
        for _ in 0..<50 { await Task.yield() }
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
