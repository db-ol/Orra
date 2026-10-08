import Foundation
import Testing
@testable import Orra

struct CorrectionFinderTests {
    private func find(_ pasted: String, _ before: String, _ after: String) -> Correction? {
        CorrectionFinder.correction(pasted: pasted, before: before, after: after)
    }

    @Test func aMisheardChineseWordIsFound() {
        let pasted = "我用通一千问写代码"
        #expect(find(pasted, "备注：" + pasted, "备注：我用通义千问写代码") == Correction(heard: "一", corrected: "义"))
    }

    @Test func aMisheardNameAcrossScriptsIsFound() {
        #expect(find("我在用克劳德写代码", "我在用克劳德写代码", "我在用Claude写代码") == Correction(heard: "克劳德", corrected: "Claude"))
    }

    @Test func aLatinWordIsTakenWhole() {
        #expect(find("open cloud code now", "open cloud code now", "open Claude code now") == Correction(heard: "cloud", corrected: "Claude"))
    }

    @Test func aChangeOfMeaningIsNotACorrection() {
        #expect(find("我明天去北京", "我明天去北京", "我后天去北京") == nil)
        #expect(find("send it on Monday", "send it on Monday", "send it on Friday") == nil)
    }

    @Test func deletionsAdditionsAndEditsOutsideThePasteAreIgnored() {
        #expect(find("今天天气很好", "今天天气很好", "今天天气好") == nil)
        #expect(find("今天天气很好", "今天天气很好", "今天天气很好啊") == nil)
        #expect(find("天气很好", "张三说：天气很好", "李四说：天气很好") == nil)
        #expect(find("天气很好", "天气很好", "天气很好") == nil)
    }

    @Test func aRewriteIsNotACorrection() {
        #expect(find("this is a test of the whole thing", "this is a test of the whole thing", "completely different words here now") == nil)
    }

    @Test func textThatIsNoLongerThereFindsNothing() {
        #expect(find("你好", "", "你好") == nil)
    }
}

struct SoundAlikeTests {
    @Test func chineseIsComparedByPinyin() {
        #expect(SoundAlike.sound("通义千问") == "tongyiqianwen")
        #expect(SoundAlike.soundsAlike("通一千问", "通义千问"))
        #expect(SoundAlike.soundsAlike("克劳德", "Claude"))
        #expect(!SoundAlike.soundsAlike("明天", "后天"))
        #expect(SoundAlike.soundsAlike("cloud", "Claude"))
        #expect(!SoundAlike.soundsAlike("Monday", "Friday"))
    }
}

struct CorrectionStoreTests {
    private let pair = Correction(heard: "克劳德", corrected: "Claude")
    private let day: TimeInterval = 24 * 60 * 60

    @Test func aCorrectionIsSuggestedTheSecondTimeWithinAWeek() {
        var store = CorrectionStore()
        let start = Date(timeIntervalSince1970: 1_000_000)
        store.record(pair, at: start)
        #expect(store.suggestions.isEmpty)
        store.record(pair, at: start.addingTimeInterval(3 * day))
        #expect(store.suggestions == [pair])
    }

    @Test func aCountOlderThanAWeekStartsOver() {
        var store = CorrectionStore()
        let start = Date(timeIntervalSince1970: 1_000_000)
        store.record(pair, at: start)
        store.record(pair, at: start.addingTimeInterval(8 * day))
        #expect(store.suggestions.isEmpty)
    }

    @Test func aDecisionEndsTheSuggestion() {
        var store = CorrectionStore()
        let now = Date(timeIntervalSince1970: 1_000_000)
        store.record(pair, at: now)
        store.record(pair, at: now)
        store.decide(pair, .accepted)
        #expect(store.suggestions.isEmpty)
        #expect(store.accepted == [pair])
        store.decide(pair, .dismissed)
        store.record(pair, at: now)
        #expect(store.suggestions.isEmpty)
        #expect(store.accepted.isEmpty)
    }

    @Test func theStoreRoundTripsThroughItsFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("io.github.db-ol.OrraTests.corrections-\(UUID().uuidString)/corrections.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var store = CorrectionStore()
        store.record(pair, at: Date(timeIntervalSince1970: 1_000_000))
        try store.save(to: url)
        #expect(CorrectionStore.load(from: url) == store)
        #expect(CorrectionStore.load(from: url.appendingPathExtension("missing")) == CorrectionStore())
    }
}

struct ReplacementsTests {
    @Test func acceptedCorrectionsAreAppliedBeforeThePaste() {
        let corrections = [Correction(heard: "克劳德", corrected: "Claude"), Correction(heard: "cloud", corrected: "Claude")]
        #expect(Replacements.apply(corrections, to: "我在用克劳德") == "我在用Claude")
        #expect(Replacements.apply(corrections, to: "open cloud code") == "open Claude code")
        #expect(Replacements.apply(corrections, to: "clouds in the sky") == "clouds in the sky")
        #expect(Replacements.apply([Correction(heard: "他", corrected: "她")], to: "他说") == "他说")
    }
}
