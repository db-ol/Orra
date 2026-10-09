import Foundation
import Testing
@testable import Orra

struct CorrectionFinderTests {
    private func find(_ pasted: String, _ before: String, _ after: String) -> Correction? {
        CorrectionFinder.correction(pasted: pasted, before: before, after: after)
    }

    @Test func aMisheardChineseNameIsFound() {
        let pasted = "我约了迪力热吧见面"
        #expect(find(pasted, "备注：" + pasted, "备注：我约了迪丽热巴见面") == Correction(heard: "力热吧", corrected: "丽热巴"))
    }

    @Test func oneChangedChineseCharacterIsLeftForTheUser() {
        #expect(find("我用通一千问写代码", "我用通一千问写代码", "我用通义千问写代码") == nil)
    }

    @Test func oneChineseCharacterIsGrammarNotAName() {
        #expect(find("我觉得他的很好", "我觉得他的很好", "我觉得他得很好") == nil)
    }

    @Test func punctuationTypedAfterTheFixIsLeftOut() {
        #expect(find("use cloud", "use cloud", "use Claude.") == Correction(heard: "cloud", corrected: "Claude"))
        #expect(find("我在用克劳德", "我在用克劳德", "我在用Claude。") == Correction(heard: "克劳德", corrected: "Claude"))
    }

    @Test func textTypedAroundThePasteIsNotPartOfIt() {
        #expect(find("open cloud", "open cloud", "open Claude and then more words") == nil)
    }

    @Test func caseEndingsAndDigitsAreNotCorrections() {
        #expect(find("i like apple", "i like apple", "i like Apple") == nil)
        #expect(find("the cloud is here", "the cloud is here", "the clouds is here") == nil)
        #expect(find("code 4821 now", "code 4821 now", "code 4812 now") == nil)
        #expect(find("in 2025 we", "in 2025 we", "in 2026 we") == nil)
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
        #expect(find("我明天去北京", "我明天去北京", "我今天去北京") == nil)
        #expect(find("send it on Monday", "send it on Monday", "send it on Sunday") == nil)
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
        #expect(!SoundAlike.soundsAlike("Monday", "Sunday"))
        #expect(!SoundAlike.soundsAlike("明天", "今天"))
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

    @Test func pairsSeenOnceLongAgoAreForgotten() {
        var store = CorrectionStore()
        let start = Date(timeIntervalSince1970: 1_000_000)
        store.record(pair, at: start)
        store.record(Correction(heard: "cloud", corrected: "Claude"), at: start.addingTimeInterval(8 * day))
        #expect(store.entries.map(\.correction) == [Correction(heard: "cloud", corrected: "Claude")])
    }

    @Test func aDamagedFileIsKeptAside() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("io.github.db-ol.OrraTests.corrections-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("corrections.json")
        try Data("not json".utf8).write(to: url)
        #expect(CorrectionStore.load(from: url) == CorrectionStore())
        #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("bad").path))
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
