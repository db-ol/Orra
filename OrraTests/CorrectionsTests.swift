import Foundation
import Testing
@testable import Orra

struct CorrectionFinderTests {
    /// The one word learned from the edit, nil when there is none. An edit that gives
    /// more than one finding fails the test.
    private func find(_ pasted: String, _ before: String, _ after: String,
                      sourceLocation: SourceLocation = #_sourceLocation) -> Correction? {
        let findings = CorrectionFinder.findings(pasted: pasted, before: before, after: after)
        #expect(findings.count <= 1, "\(findings)", sourceLocation: sourceLocation)
        guard findings.count == 1, case .word(let correction) = findings[0] else { return nil }
        return correction
    }

    private func findings(_ pasted: String, _ edited: String) -> [Finding] {
        CorrectionFinder.findings(pasted: pasted, edited: edited)
    }

    @Test func aMisheardChineseNameIsFoundWhole() {
        // 迪 did not change, and it is part of the name.
        let pasted = "我约了迪力热吧见面"
        #expect(find(pasted, "备注：" + pasted, "备注：我约了迪丽热巴见面") == Correction(heard: "迪力热吧", corrected: "迪丽热巴"))
    }

    @Test func aNameWithItsFirstCharacterRightIsLearnedWhole() {
        // Real case: 义千问 was learned, since 通 had not changed.
        #expect(findings("通一千万", "通义千问") == [.word(Correction(heard: "通一千万", corrected: "通义千问"))])
        #expect(findings("我在用通一千万写代码", "我在用通义千问写代码") == [.word(Correction(heard: "通一千万", corrected: "通义千问"))])
    }

    @Test func separateFixesInOneSentenceAreJudgedApart() {
        // Real case: the whole sentence was learned. 陈 to 晨 offers the name, and 嘛 to 吗
        // is grammar.
        let found = findings("陈阳写的那些文档一样嘛", "晨阳写的那些文档一样吗")
        #expect(found.count == 1)
        guard case .suggestion(let suggestion) = found.first else {
            Issue.record("expected the name to be offered: \(found)")
            return
        }
        #expect(suggestion.change == Correction(heard: "陈", corrected: "晨"))
        #expect(suggestion.pair == Correction(heard: "陈阳", corrected: "晨阳"))
    }

    @Test func aLatinNameAndAChineseFixApartAreJudgedApart() {
        // Real case: "PR 今天merge" was learned as one word.
        let found = findings("P.R. 今天没雨", "PR 今天merge")
        #expect(!found.contains { $0.correction.corrected.contains(" ") })
        #expect(found.contains(.word(Correction(heard: "P.R.", corrected: "PR"))))
        #expect(found.allSatisfy { $0.correction.corrected.count <= CorrectionFinder.maximumLength })
    }

    @Test func aChineseSpanLongerThanEightCharactersIsNeverLearned() {
        // Nine characters that sound the same, with no two unchanged characters in a row.
        #expect(findings("北京天安门广场人民英", "背京甜安们广厂人敏英").isEmpty)
        #expect(SoundAlike.soundsAlike("北京天安门广场人民", "背京甜安们广厂人敏"))
        // A shorter span is learned.
        #expect(findings("北京天安门广场人英", "背京甜安们广厂人英") == [.word(Correction(heard: "北京天安门广场", corrected: "背京甜安们广厂"))])
    }

    @Test func grammarSwapsOneCharacterApartAreNotLearnedAsAWord() {
        // Each swap is grammar, and together they sound almost the same.
        #expect(findings("他说得对吗", "他说的对嘛").isEmpty)
        #expect(findings("你在干嘛呢", "你在干吗哪").isEmpty)
        // A grammar swap next to a name stays out of it.
        #expect(findings("陈阳得书", "晨阳的书").map(\.correction) == [Correction(heard: "陈阳", corrected: "晨阳")])
    }

    @Test func aWordTheTokenizerKnowsDoesNotTakeInTheVerbAfterIt() {
        #expect(findings("我们去洛山鸡玩", "我们去洛杉矶玩") == [.word(Correction(heard: "洛山鸡", corrected: "洛杉矶"))])
        #expect(findings("我们去洛山鸡玩了一天", "我们去洛杉矶玩了一天") == [.word(Correction(heard: "洛山鸡", corrected: "洛杉矶"))])
        // An unknown name, which the tokenizer splits into single characters, is still
        // taken whole.
        #expect(findings("我约了迪力热吧见面", "我约了迪丽热巴见面") == [.word(Correction(heard: "迪力热吧", corrected: "迪丽热巴"))])
    }

    @Test func wideningNeverMakesASpanTooLongToLearn() {
        // Eight heard characters and five corrected ones. Taking in 迪 would make nine.
        #expect(findings("迪鑫淼焱垚犇阿一乌", "迪心秒燕摇奔") == [.word(Correction(heard: "鑫淼焱垚犇阿一乌", corrected: "心秒燕摇奔"))])
    }

    @Test func aNameOfTwoWordsWhereOneOnlyChangedCaseIsLearnedWhole() {
        #expect(findings("I use cloud code daily", "I use Claude Code daily") == [.word(Correction(heard: "cloud code", corrected: "Claude Code"))])
        #expect(findings("用 vs code 写", "用 VS Code 写") == [.word(Correction(heard: "vs code", corrected: "VS Code"))])
        // A case change alone is still the start of a sentence, not a name.
        #expect(findings("VS code is", "VS Code is").isEmpty)
        // Two real fixes apart are still two words.
        #expect(findings("ask cloud about pithon", "ask Claude about Python").count == 2)
    }

    @Test func eachFindingHasTheSpanOfThePastedTextItCovers() {
        let located = CorrectionFinder.locatedFindings(pasted: "我在用通一千万写", edited: "我在用通义千问写")
        #expect(located.map(\.span) == [3..<7])
        let offered = CorrectionFinder.locatedFindings(pasted: "我在用通一千万写", edited: "我在用通义千万写")
        #expect(offered.map(\.span) == [3..<5])
    }

    @Test func aLatinWordKeepsItsTwelveCharacters() {
        #expect(find("I use kubernetis", "I use kubernetis", "I use Kubernetesx") == Correction(heard: "kubernetis", corrected: "Kubernetesx"))
        #expect(find("I use kubernetisab", "I use kubernetisab", "I use Kubernetesabc") == nil)
    }

    @Test func chineseNumeralsAreLettersNotDigits() {
        #expect(find("同意千万。", "同意千万。", "通义千问。") == Correction(heard: "同意千万", corrected: "通义千问"))
        #expect(find("code ４８２１ now", "code ４８２１ now", "code ４８１２ now") == nil)
    }

    @Test func oneChangedChineseCharacterIsLeftForTheUser() {
        #expect(find("我用通一千问写代码", "我用通一千问写代码", "我用通义千问写代码") == nil)
    }

    @Test func oneChineseCharacterIsGrammarNotAName() {
        #expect(find("我觉得他的很好", "我觉得他的很好", "我觉得他得很好") == nil)
    }

    @Test func aLetterTypedIntoANameIsFound() {
        #expect(find("Ora，你觉得好用吗？", "Ora，你觉得好用吗？", "Orra，你觉得好用吗？") == Correction(heard: "Ora", corrected: "Orra"))
        #expect(find("I use Kubernettes daily", "I use Kubernettes daily", "I use Kubernetes daily") == Correction(heard: "Kubernettes", corrected: "Kubernetes"))
    }

    @Test func aWordTypedBetweenWordsIsNotACorrection() {
        #expect(find("I like apples", "I like apples", "I really like apples") == nil)
        #expect(find("我喜欢苹果", "我喜欢苹果", "我很喜欢苹果") == nil)
    }

    @Test func punctuationTypedAfterTheFixIsLeftOut() {
        #expect(find("use cloud", "use cloud", "use Claude.") == Correction(heard: "cloud", corrected: "Claude"))
        #expect(find("我在用克劳德", "我在用克劳德", "我在用Claude。") == Correction(heard: "克劳德", corrected: "Claude"))
    }

    @Test func textTypedAroundThePasteIsNotPartOfIt() {
        #expect(find("open cloud", "open cloud", "open Claude and then more words") == nil)
    }

    @Test func aNameWithJoiningMarksAndSpelledLettersIsTakenWhole() {
        #expect(find("S J L Omni的听写能力怎么样？", "S J L Omni的听写能力怎么样？", "SGLang-Omni的听写能力怎么样？") == Correction(heard: "S J L Omni", corrected: "SGLang-Omni"))
        #expect(find("SGlang-omni的语言能力", "SGlang-omni的语言能力", "SGLang-Omni的语言能力") == Correction(heard: "SGlang-omni", corrected: "SGLang-Omni"))
        #expect(find("I use quen 3 now", "I use quen 3 now", "I use Qwen3 now") == Correction(heard: "quen 3", corrected: "Qwen3"))
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

struct PasteTrackerTests {
    private func tracker(_ pasted: String, _ field: String) -> PasteTracker {
        PasteTracker(pasted: pasted, field: field)!
    }

    @Test func anEditBeforeThePasteMovesIt() {
        var paste = tracker("同意千万。", "第一行\n同意千万。")
        paste.update(to: "第一行改过了\n同意千万。")
        #expect(paste.pasteNow == "同意千万。")
        paste.update(to: "\n同意千万。")
        #expect(paste.pasteNow == "同意千万。")
    }

    @Test func anEditInsideThePasteChangesIt() {
        var paste = tracker("同意千万。", "第一行\n同意千万。\n第三行")
        paste.update(to: "第一行\n通义千问。\n第三行")
        #expect(paste.pasteNow == "通义千问。")
    }

    @Test func textTypedAfterThePasteIsNotPartOfIt() {
        var paste = tracker("同意千万。", "同意千万。")
        paste.update(to: "同意千万。再打几个字")
        #expect(paste.pasteNow == "同意千万。")
    }

    @Test func aFieldWithoutThePasteHasNoTracker() {
        #expect(PasteTracker(pasted: "你好", field: "再见") == nil)
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

    @Test func acceptingTakesOnlyThePairsNotUndone() {
        var store = CorrectionStore()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let other = Correction(heard: "可劳德", corrected: "Claude")
        store.record(pair, at: now)
        #expect(store.acceptSeen(of: "Claude") == [pair])
        store.dismiss([pair])
        store.record(other, at: now)
        #expect(store.acceptSeen(of: "Claude") == [other])
        #expect(store.has(.dismissed, for: "Claude"))
        #expect(store.has(.accepted, for: "Claude"))
        #expect(!store.has(.accepted, for: "Orra"))
    }

    @Test func undoingAPairNoLongerKeptKeepsItAsUndone() {
        var store = CorrectionStore()
        store.dismiss([pair], at: Date(timeIntervalSince1970: 1_000_000))
        #expect(store.state(of: pair) == .dismissed)
        #expect(store.has(.dismissed, for: "Claude"))
    }

    @Test func aCountOlderThanAWeekStartsOver() {
        var store = CorrectionStore()
        let start = Date(timeIntervalSince1970: 1_000_000)
        store.record(pair, at: start)
        store.record(pair, at: start.addingTimeInterval(8 * day))
        #expect(store.entries.map(\.count) == [1])
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
