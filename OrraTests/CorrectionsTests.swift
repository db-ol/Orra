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
        // Real case: the whole sentence was learned. 林 to 霖 offers the name, and 嘛 to 吗
        // is grammar.
        let found = findings("林悦写的那些文档一样嘛", "霖悦写的那些文档一样吗")
        #expect(found.count == 1)
        guard case .suggestion(let suggestion) = found.first else {
            Issue.record("expected the name to be offered: \(found)")
            return
        }
        #expect(suggestion.change == Correction(heard: "林", corrected: "霖"))
        #expect(suggestion.pair == Correction(heard: "林悦", corrected: "霖悦"))
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
        #expect(findings("林悦得书", "霖悦的书").map(\.correction) == [Correction(heard: "林悦", corrected: "霖悦")])
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

    @Test func aNameWhoseFirstVowelWasMisheardIsFound() {
        #expect(find("你觉得 Aura 的语音听写好用吗？", "你觉得 Aura 的语音听写好用吗？", "你觉得 Orra 的语音听写好用吗？") == Correction(heard: "Aura", corrected: "Orra"))
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
        #expect(find("K B L Nova的听写能力怎么样？", "K B L Nova的听写能力怎么样？", "KVLite-Nova的听写能力怎么样？") == Correction(heard: "K B L Nova", corrected: "KVLite-Nova"))
        #expect(find("KVlite-nova的语言能力", "KVlite-nova的语言能力", "KVLite-Nova的语言能力") == Correction(heard: "KVlite-nova", corrected: "KVLite-Nova"))
        #expect(find("I use quen 3 now", "I use quen 3 now", "I use Qwen3 now") == Correction(heard: "quen 3", corrected: "Qwen3"))
    }

    @Test func joiningOrSplittingWordsTakesInBothWords() {
        // Real case: read me was fixed to readme by taking out the space.
        #expect(find("Update the read me file", "Update the read me file", "Update the readme file") == Correction(heard: "read me", corrected: "readme"))
        #expect(find("更新 read me 文件", "更新 read me 文件", "更新 readme 文件") == Correction(heard: "read me", corrected: "readme"))
        #expect(find("I use Qwen 3 now", "I use Qwen 3 now", "I use Qwen3 now") == Correction(heard: "Qwen 3", corrected: "Qwen3"))
        #expect(find("open the airpodspro case", "open the airpodspro case", "open the airpods pro case") == Correction(heard: "airpodspro", corrected: "airpods pro"))
    }

    @Test func spacesOutsideAWordAreNotCorrections() {
        // Only a space taken out after a period, or a line break put in, is no word.
        #expect(find("It is done. Then we go", "It is done. Then we go", "It is done.Then we go") == nil)
        #expect(find("first line second line", "first line second line", "first line\nsecond line") == nil)
        #expect(find("我们  走吧", "我们  走吧", "我们 走吧") == nil)
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

    @Test func aChangeToWordsWithChineseNumeralsIsNotACorrection() {
        // These were learned while 十, 万 and 一 counted as digits of a name.
        #expect(find("明天开会", "明天开会", "明天十点") == nil)
        #expect(find("这个项目不错", "这个项目不错", "这个万科不错") == nil)
        #expect(find("我们明天去", "我们明天去", "我们一起去") == nil)
        // A single letter has no English key either.
        #expect(find("go with plan A", "go with plan A", "go with plan B") == nil)
        // An ASCII digit makes 10点钟 look like a name, but it has no key either.
        #expect(find("明天开会", "明天开会", "明天10点钟") == nil)
        // A misheard name with a numeral in it is still learned.
        #expect(find("我们去完克看房", "我们去完克看房", "我们去万科看房") == Correction(heard: "完克", corrected: "万科"))
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

    @Test func theLastOverlappingMatchIsChosen() {
        #expect(PasteTracker(pasted: "aba", field: "ababa")?.range == 2..<5)
        #expect(PasteTracker(pasted: "🙂🙂", field: "🙂🙂🙂")?.range == 1..<3)
        #expect(PasteTracker(pasted: "a", field: "baaa")?.range == 3..<4)
        #expect(PasteTracker(pasted: "é", field: "e\u{301}")?.range == 0..<1)
    }

    @Test func repeatedPrefixesMatchTheLastOccurrence() {
        let field = String(repeating: "a", count: 20_000)
        let paste = String(repeating: "a", count: 1_999) + "b"
        #expect(PasteTracker(pasted: paste, field: field) == nil)
        let withTwo = paste + "a" + paste
        #expect(PasteTracker(pasted: paste, field: withTwo)?.range == 2_001..<4_001)
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
        #expect(SoundAlike.soundsAlike("Aura", "Orra"))
        #expect(SoundAlike.soundsAlike("aura", "Orra"))
        #expect(!SoundAlike.soundsAlike("form", "from"))
        #expect(!SoundAlike.soundsAlike("Anna", "Emma"))
        #expect(!SoundAlike.soundsAlike("明天", "今天"))
    }

    @Test func wordsWithoutAnEnglishKeyNeverMatchOnIt() {
        // No Latin letters, so neither word has a key. 十, 万, 三 and 一 count as numbers in
        // Swift, which made each second word look like a name.
        #expect(!SoundAlike.soundsAlike("开会", "十点"))
        #expect(!SoundAlike.soundsAlike("项目", "万科"))
        #expect(!SoundAlike.soundsAlike("明天", "三天"))
        #expect(!SoundAlike.soundsAlike("我们", "一起"))
        // One letter is too short for a key.
        #expect(!SoundAlike.soundsAlike("A", "B"))
        #expect(!SoundAlike.soundsAlike("I", "We"))
        // An ASCII digit makes 10点钟 look like a name, but it has no key either.
        #expect(!SoundAlike.soundsAlike("开会", "10点钟"))
    }

    @Test func onlyACapitalOrAnASCIIDigitMakesAName() {
        #expect(SoundAlike.soundsAlike("aura 3", "orra3"))
        #expect(SoundAlike.soundsAlike("aura三号", "Orra三号"))
        // 三 is a Chinese word here, not a digit of a name.
        #expect(!SoundAlike.soundsAlike("aura三号", "orra三号"))
    }

    @Test func misheardNamesStillSoundAlike() {
        #expect(SoundAlike.soundsAlike("Ora", "Orra"))
        #expect(SoundAlike.soundsAlike("Kubernettes", "Kubernetes"))
        // Names with digits.
        #expect(SoundAlike.soundsAlike("quen 3", "Qwen3"))
        #expect(SoundAlike.soundsAlike("gpt 4o", "GPT-4o"))
        // Chinese names with one wrong character, some with a numeral.
        #expect(SoundAlike.soundsAlike("王亦博", "王一博"))
        #expect(SoundAlike.soundsAlike("万克", "万科"))
        #expect(SoundAlike.soundsAlike("三醒", "三星"))
        #expect(SoundAlike.soundsAlike("迪力热吧", "迪丽热巴"))
        #expect(SoundAlike.soundsAlike("亦", "一"))
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

/// A fix that changes only numbers, digits or Chinese numerals, is never a misheard word,
/// so it is neither learned nor offered, even when the two sides sound alike.
struct NumbersOnlyTests {
    private func findings(_ pasted: String, _ edited: String) -> [Finding] {
        CorrectionFinder.findings(pasted: pasted, edited: edited)
    }

    @Test func theTwoSidesAreComparedWithoutTheirNumbers() {
        #expect(CorrectionFinder.changesOnlyNumbers("Qwen2", "Qwen3"))
        #expect(CorrectionFinder.changesOnlyNumbers("GPT-4", "GPT-5"))
        #expect(CorrectionFinder.changesOnlyNumbers("四点", "十点"))
        #expect(CorrectionFinder.changesOnlyNumbers("十四", "四十"))
        #expect(!CorrectionFinder.changesOnlyNumbers("完克", "万科"))
        #expect(!CorrectionFinder.changesOnlyNumbers("通一千问", "通义千问"))
        #expect(!CorrectionFinder.changesOnlyNumbers("quen 3", "Qwen3"))
        // The known cost: a name that differs only in a numeral.
        #expect(CorrectionFinder.changesOnlyNumbers("一郎", "二郎"))
        // Full width digits and the formal numerals count.
        #expect(CorrectionFinder.changesOnlyNumbers("Qwen３", "Qwen3"))
        #expect(CorrectionFinder.changesOnlyNumbers("三点", "叁点"))
        #expect(CorrectionFinder.changesOnlyNumbers("壹佰", "一百"))
        // The same word is no change.
        #expect(!CorrectionFinder.changesOnlyNumbers("Qwen3", "Qwen3"))
    }

    @Test func aChangeOfOnlyANumberIsNeverLearned() {
        // Each of these sounds alike, and each was learned.
        #expect(findings("I use Qwen2 now", "I use Qwen3 now").isEmpty)
        #expect(findings("我在用Qwen2写代码", "我在用Qwen3写代码").isEmpty)
        #expect(findings("I asked GPT-4 about it", "I asked GPT-5 about it").isEmpty)
        #expect(findings("I asked GPT-4o about it", "I asked GPT-5o about it").isEmpty)
        #expect(findings("buy an iPhone15 today", "buy an iPhone16 today").isEmpty)
        #expect(findings("我今年十四岁", "我今年四十岁").isEmpty)
        // An added version number, and full width digits made ASCII.
        #expect(findings("I use Qwen now", "I use Qwen3 now").isEmpty)
        #expect(findings("I use Qwen３ now", "I use Qwen3 now").isEmpty)
    }

    @Test func aChangeOfOneNumeralIsNeverOffered() {
        // 四 and 十 sound alike, si and shi, so 四点 to 十点 offered a word.
        #expect(findings("明天四点开会", "明天十点开会").isEmpty)
        #expect(findings("今天三点见", "今天叁点见").isEmpty)
        // The known cost: a name that differs only in a numeral is not offered either.
        #expect(findings("我叫十郎", "我叫四郎").isEmpty)
        #expect(findings("我叫一郎", "我叫二郎").isEmpty)
    }

    @Test func misheardWordsWithNumbersAreStillLearned() {
        #expect(findings("我们去完克看房", "我们去万科看房") == [.word(Correction(heard: "完克", corrected: "万科"))])
        #expect(findings("I use quen 3 now", "I use Qwen3 now") == [.word(Correction(heard: "quen 3", corrected: "Qwen3"))])
        #expect(findings("I use Qwen 3 now", "I use Qwen3 now") == [.word(Correction(heard: "Qwen 3", corrected: "Qwen3"))])
        // A numeral fixed to a character that is none is still offered.
        #expect(findings("我用通一千问写代码", "我用通义千问写代码") == [.suggestion(WordSuggestion(
            change: Correction(heard: "一", corrected: "义"),
            pair: Correction(heard: "通一千问", corrected: "通义千问")
        ))])
    }

    @Test func aFixOfLettersAndDigitsIsLeftToTheSoundCheck() {
        // The letters changed too, so the fix is judged by its sound, as before.
        #expect(!CorrectionFinder.changesOnlyNumbers("Quen2", "Qwen3"))
        #expect(findings("I use Quen2 now", "I use Qwen3 now") == [.word(Correction(heard: "Quen2", corrected: "Qwen3"))])
    }

    @Test func aNumberWrittenAnotherWayIsNoMisheardWord() {
        // 第3版 to 第三版 changes how the number is written.
        #expect(CorrectionFinder.changesOnlyNumbers("第3版", "第三版"))
        #expect(findings("这是第3版", "这是第三版").isEmpty)
        #expect(findings("这是第三版", "这是第3版").isEmpty)
        // Number words of other languages do not count, so 2 to two is no change of numbers
        // only. It is still not learned, since 2 is no word.
        #expect(!CorrectionFinder.changesOnlyNumbers("2", "two"))
        #expect(findings("I have 2 cats", "I have two cats").isEmpty)
        #expect(findings("I have two cats", "I have 2 cats").isEmpty)
    }

    @Test func sidesWithNothingButNumbers() {
        // Both sides are empty without their numbers.
        #expect(CorrectionFinder.changesOnlyNumbers("十四", "四十"))
        #expect(CorrectionFinder.changesOnlyNumbers("3", "三"))
        #expect(CorrectionFinder.changesOnlyNumbers("１２", "12"))
        // Only one side is: numerals heard for a name are still a misheard word.
        #expect(!CorrectionFinder.changesOnlyNumbers("一一", "依依"))
        #expect(findings("我叫一一", "我叫依依") == [.word(Correction(heard: "一一", corrected: "依依"))])
    }

    @Test func aVersionWithADecimalPointCountsAsANumber() {
        #expect(CorrectionFinder.changesOnlyNumbers("Qwen2.5", "Qwen3"))
        #expect(CorrectionFinder.changesOnlyNumbers("Qwen2.5-VL", "Qwen3-VL"))
        #expect(findings("I use Qwen2.5 now", "I use Qwen3 now").isEmpty)
        #expect(findings("我在用Qwen3写代码", "我在用Qwen3.5写代码").isEmpty)
        #expect(findings("I asked GPT-4.5 about it", "I asked GPT-5 about it").isEmpty)
        #expect(findings("I wrote it in Python3.11", "I wrote it in Python3.12").isEmpty)
        // A period after the number ends the word, and stays out of the number.
        #expect(CorrectionFinder.changesOnlyNumbers("Qwen2.", "Qwen3."))
        // Only the point tells these apart: without it both hold the digits 25, and the
        // fix would go to the sound check, which reads letters only, and be learned.
        #expect(CorrectionFinder.changesOnlyNumbers("Qwen25", "Qwen2.5"))
        #expect(CorrectionFinder.changesOnlyNumberValues("Qwen25", "Qwen2.5"))
        #expect(findings("I use Qwen25 now", "I use Qwen2.5 now").isEmpty)
    }

    @Test func aChangeOfNumberWithASpaceAMarkOrACaseBesideItIsNeverLearned() {
        // Each of these sounds alike, and each was learned.
        #expect(findings("I use Qwen 2 now", "I use Qwen3 now").isEmpty)
        #expect(findings("I use Qwen2 now", "I use Qwen 3 now").isEmpty)
        #expect(findings("I asked GPT4 about it", "I asked GPT-5 about it").isEmpty)
        #expect(findings("I asked GPT 4 about it", "I asked GPT-5 about it").isEmpty)
        #expect(findings("I asked GPT-4 about it", "I asked GPT 5 about it").isEmpty)
        #expect(findings("I use qwen2 now", "I use Qwen3 now").isEmpty)
        #expect(findings("I asked gpt4 about it", "I asked GPT5 about it").isEmpty)
        #expect(findings("升级到 iOS 17 了", "升级到 iOS18 了").isEmpty)
        #expect(CorrectionFinder.changesOnlyNumbers("第 3 版", "第三版"))
    }

    @Test func theSameNumberInAnotherWritingIsStillJudgedByItsSound() {
        #expect(!CorrectionFinder.changesOnlyNumbers("Qwen 3", "Qwen3"))
        #expect(!CorrectionFinder.changesOnlyNumbers("COVID 19", "COVID-19"))
        #expect(findings("COVID 19 is gone", "COVID-19 is gone") == [.word(Correction(heard: "COVID 19", corrected: "COVID-19"))])
        #expect(findings("I use Qwen 2.5 now", "I use Qwen2.5 now") == [.word(Correction(heard: "Qwen 2.5", corrected: "Qwen2.5"))])
    }

    /// For the pairs an earlier version kept: another number changes what was said, while
    /// the same number in another writing does not. A formal numeral counts as written.
    @Test func anotherValueIsToldFromAnotherWritingOfTheSameNumber() {
        #expect(CorrectionFinder.changesOnlyNumberValues("Qwen2", "Qwen3"))
        #expect(CorrectionFinder.changesOnlyNumberValues("Qwen 2", "Qwen3"))
        #expect(CorrectionFinder.changesOnlyNumberValues("Qwen2.5", "Qwen3"))
        #expect(CorrectionFinder.changesOnlyNumberValues("Qwen2-7B", "Qwen3-7B"))
        #expect(CorrectionFinder.changesOnlyNumberValues("十四", "四十"))
        #expect(CorrectionFinder.changesOnlyNumberValues("三百五", "305"))
        #expect(!CorrectionFinder.changesOnlyNumberValues("Windows十一", "Windows11"))
        #expect(!CorrectionFinder.changesOnlyNumberValues("iPhone十五", "iPhone 15"))
        #expect(!CorrectionFinder.changesOnlyNumberValues("Qwen３", "Qwen3"))
        #expect(!CorrectionFinder.changesOnlyNumberValues("Office二零一九", "Office2019"))
        #expect(!CorrectionFinder.changesOnlyNumberValues("三百五", "350"))
        #expect(!CorrectionFinder.changesOnlyNumberValues("一千", "1,000"))
        // A formal numeral is a word or a surname too.
        #expect(CorrectionFinder.changesOnlyNumberValues("大六", "大陆"))
        #expect(CorrectionFinder.changesOnlyNumberValues("五先生", "伍先生"))
        // No change of numbers only.
        #expect(!CorrectionFinder.changesOnlyNumberValues("quen 3", "Qwen3"))
        #expect(!CorrectionFinder.changesOnlyNumberValues("Quen2", "Qwen3"))
        #expect(!CorrectionFinder.changesOnlyNumberValues("Qwen3", "Qwen3"))
    }

    @Test func datesTimesAndAmountsAreNeverLearned() {
        #expect(findings("三月四号开会", "三月五号开会").isEmpty)
        #expect(findings("十月一号放假", "四月一号放假").isEmpty)
        #expect(findings("3月4号开会", "3月5号开会").isEmpty)
        #expect(findings("明天四点半开会", "明天十点半开会").isEmpty)
        #expect(findings("下周四见", "下周三见").isEmpty)
        #expect(findings("一百块钱", "两百块钱").isEmpty)
        #expect(findings("花了一千块", "花了一万块").isEmpty)
        #expect(findings("花了三百元", "花了叁佰元").isEmpty)
        #expect(findings("付了$100", "付了$200").isEmpty)
        #expect(findings("新的M4芯片", "新的M5芯片").isEmpty)
    }

    @Test func chineseNamesWithNumerals() {
        // The known cost: a name that differs only in a numeral, also a surname written
        // with a formal numeral, as 伍 and 陆 are.
        #expect(findings("我叫陈十一", "我叫陈四一").isEmpty)
        #expect(findings("我是五先生", "我是伍先生").isEmpty)
        #expect(findings("我是六先生", "我是陆先生").isEmpty)
        // A numeral fixed to a character that is none, or the other way, is still offered.
        let changes = [
            ("找王亦博签名", "找王一博签名", Correction(heard: "亦", corrected: "一")),
            ("我叫张三", "我叫张山", Correction(heard: "三", corrected: "山")),
            ("我叫李四", "我叫李斯", Correction(heard: "四", corrected: "斯")),
        ]
        for (pasted, edited, change) in changes {
            let found = findings(pasted, edited)
            guard found.count == 1, case .suggestion(let suggestion) = found[0] else {
                Issue.record("\(pasted) to \(edited) offered nothing: \(found)")
                continue
            }
            #expect(suggestion.change == change)
        }
    }

    // MARK: A word Orra replaced

    private func translated(pasted: String, edited: String, _ replacements: [Replacement]) -> [CorrectionFinder.Translation] {
        CorrectionFinder.locatedFindings(pasted: pasted, edited: edited, replaced: replacements.map(\.span)).map {
            CorrectionFinder.translate($0, pasted: Array(pasted), replacements: replacements)
        }
    }

    /// A pair an earlier version learned from a change of number still stops replacing when
    /// the user puts back the number the model wrote.
    @Test func puttingBackANumberTheModelWroteForgetsTheOldPair() {
        let pair = Correction(heard: "Qwen2", corrected: "Qwen3")
        let replacement = Replacement(span: 3..<8, heard: "Qwen2", corrected: "Qwen3", pair: pair)
        #expect(translated(pasted: "我在用Qwen3写代码", edited: "我在用Qwen2写代码", [replacement]) == [.reverted([pair])])
    }

    @Test func aChangeOfNumberInAReplacedWordIsNotLearned() {
        // Qwen3 to Qwen2 changes only the number of the pasted word, where the model wrote
        // quen 3.
        let quen = Correction(heard: "quen 3", corrected: "Qwen3")
        let replacedQuen = Replacement(span: 3..<8, heard: "quen 3", corrected: "Qwen3", pair: quen)
        #expect(translated(pasted: "我在用Qwen3写代码", edited: "我在用Qwen2写代码", [replacedQuen]) == [.dropped])
        // GPT-4 to GPT5 changes more than the number of the pasted word, but the pair would
        // be GPT4 to GPT5, since the model wrote GPT4.
        let gpt = Correction(heard: "GPT4", corrected: "GPT-4")
        let replacedGPT = Replacement(span: 8..<13, heard: "GPT4", corrected: "GPT-4", pair: gpt)
        #expect(translated(pasted: "I asked GPT-4 today", edited: "I asked GPT5 today", [replacedGPT]) == [.dropped])
    }

    @Test func aChangeOfNumberInAReplacedWordIsNotLearnedInAnyWriting() {
        // Qwen3 to Qwen2.5, where the model wrote Qwen2: the pair would change its number.
        let qwen = Correction(heard: "Qwen2", corrected: "Qwen3")
        let replacedQwen = Replacement(span: 3..<8, heard: "Qwen2", corrected: "Qwen3", pair: qwen)
        #expect(translated(pasted: "我在用Qwen3写代码", edited: "我在用Qwen2.5写代码", [replacedQwen]) == [.dropped])
        // Qwen3.5 to Qwen3 changes only the number of the pasted word, where the model
        // wrote quen 3.5.
        let quen = Correction(heard: "quen 3.5", corrected: "Qwen3.5")
        let replacedQuen = Replacement(span: 3..<10, heard: "quen 3.5", corrected: "Qwen3.5", pair: quen)
        #expect(translated(pasted: "我在用Qwen3.5写代码", edited: "我在用Qwen3写代码", [replacedQuen]) == [.dropped])
        // Qwen3 to Qwen 2 changes the number of the pasted word and a space beside it.
        let quen3 = Correction(heard: "quen 3", corrected: "Qwen3")
        let replacedQuen3 = Replacement(span: 3..<8, heard: "quen 3", corrected: "Qwen3", pair: quen3)
        #expect(translated(pasted: "我在用Qwen3写代码", edited: "我在用Qwen 2写代码", [replacedQuen3]) == [.dropped])
    }

    /// The model's number put back in another writing is a fix of the replaced word with
    /// the model's number, so it is learned, and the old pair stops replacing.
    @Test func theModelsNumberPutBackInAnotherWritingIsLearned() {
        let gpt = Correction(heard: "GPT4", corrected: "GPT-5")
        let replacedGPT = Replacement(span: 8..<13, heard: "GPT4", corrected: "GPT-5", pair: gpt)
        #expect(translated(pasted: "I asked GPT-5 today", edited: "I asked GPT-4 today", [replacedGPT])
            == [.finding(.word(Correction(heard: "GPT4", corrected: "GPT-4")))])
        let qwen = Correction(heard: "Qwen2", corrected: "Qwen3")
        let replacedQwen = Replacement(span: 3..<8, heard: "Qwen2", corrected: "Qwen3", pair: qwen)
        #expect(translated(pasted: "我在用Qwen3写代码", edited: "我在用Qwen 2写代码", [replacedQwen])
            == [.finding(.word(Correction(heard: "Qwen2", corrected: "Qwen 2")))])
    }
}
