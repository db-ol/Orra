import Foundation
import Testing
@testable import Orra

struct OneCharacterFixTests {
    private func suggest(_ pasted: String, _ edited: String) -> WordSuggestion? {
        OneCharacterFix.suggestion(pasted: pasted, edited: edited)
    }

    private func guess(_ text: String, at index: Int) -> String {
        let characters = Array(text)
        return String(characters[OneCharacterFix.guess(in: characters, at: index)])
    }

    @Test func aMisheardCharacterInAnUnknownNameOffersTheWholeName() {
        // The tokenizer splits the name into 通 | 义 | 千 | 问, and 用 and 写 end it.
        #expect(suggest("我用通一千问写代码", "我用通义千问写代码") == WordSuggestion(
            change: Correction(heard: "一", corrected: "义"),
            pair: Correction(heard: "通一千问", corrected: "通义千问")
        ))
        #expect(suggest("用通一千问吧", "用通义千问吧。")?.guess == "通义千问")
    }

    @Test func theFinderStillLearnsNothingOnItsOwnButOffersTheWord() {
        let finding = CorrectionFinder.finding(pasted: "我用通一千问写代码", edited: "我用通义千问写代码")
        #expect(finding?.correction == Correction(heard: "通一千问", corrected: "通义千问"))
        if case .word = finding { Issue.record("one character must not be learned on its own") }
        #expect(CorrectionFinder.finding(pasted: "同意千万。", edited: "通义千问。") == .word(Correction(heard: "同意千万", corrected: "通义千问")))
    }

    @Test func grammarAndCommonTyposAreNeverOffered() {
        #expect(suggest("我觉得他的很好", "我觉得他得很好") == nil)
        #expect(suggest("我在说一遍", "我再说一遍") == nil)
        #expect(suggest("她在这里", "他在这里") == nil)
        #expect(CorrectionFinder.finding(pasted: "慢慢的走", edited: "慢慢地走") == nil)
    }

    @Test func everyGrammarPairSoundsAlikeSoTheListIsNeeded() {
        for group in OneCharacterFix.grammarGroups {
            for first in group {
                for second in group where first != second {
                    #expect(OneCharacterFix.isGrammar(first, second))
                    #expect(SoundAlike.soundsAlike(String(first), String(second)), "\(first) \(second)")
                }
            }
        }
        #expect(!OneCharacterFix.isGrammar("一", "义"))
        #expect(!OneCharacterFix.isGrammar("的", "在"))
    }

    @Test func onlyOneChangedHanCharacterThatSoundsAlikeIsOffered() {
        // Does not sound alike.
        #expect(suggest("我用通是千问写代码", "我用通义千问写代码") == nil)
        // Two characters: learned on its own as before, not offered.
        #expect(suggest("我用同一千问写代码", "我用通义千问写代码") == nil)
        // Not Han.
        #expect(suggest("I use Ora", "I use Orb") == nil)
        #expect(suggest("用通一千问", "用通义千问写") == nil)
        #expect(suggest("用通一千问", "用通一千问") == nil)
    }

    @Test func theGuessIsTheTokenizersWordWhenItKnowsOne() {
        // 北京 is one word, so the guess is that word.
        #expect(suggest("我们去北经开会", "我们去北京开会")?.pair == Correction(heard: "北经", corrected: "北京"))
    }

    @Test func theGuessStopsAtPunctuationOtherScriptsAndFunctionWords() {
        #expect(guess("我用通义千问，写代码", at: 3) == "通义千问")
        #expect(guess("用Qwen通义千问", at: 6) == "通义千问")
        #expect(guess("他叫通义千问了", at: 3) == "通义千问")
        // A neighbouring word of two characters ends the guess.
        #expect(guess("我想用豆包试试", at: 3) == "豆包")
    }

    @Test func commonVerbsAroundANameStayOutOfTheGuess() {
        // The pair kept for a guess holds no more of the user's words than the name.
        #expect(suggest("找王一博签名", "找王亦博签名")?.pair == Correction(heard: "王一博", corrected: "王亦博"))
        #expect(suggest("我们去小米之家买手机", "我们去小迷之家买手机")?.guess == "小迷之家")
        #expect(suggest("给欧阳娜娜发消息", "给欧阳纳娜发消息")?.guess == "纳娜")
        // 问 is not a stop, since it is part of names such as 通义千问.
        #expect(suggest("你好，通一千问", "你好，通义千问")?.guess == "通义千问")
    }

    @Test func aNameWithAFunctionWordInItIsGuessedInPart() {
        // 文心一言 splits as 文心 | 一 | 言, and 一 is a function word. The user edits the guess.
        #expect(suggest("我们用文心一盐生成", "我们用文心一言生成")?.guess == "言")
    }

    @Test func theGuessIsAtMostSixCharacters() {
        let text = "用焱垚犇骉焱垚犇骉焱垚吧"
        for index in 1...10 {
            let range = OneCharacterFix.guess(in: Array(text), at: index)
            #expect(range.count <= OneCharacterFix.maximumGuessLength)
            #expect(range.contains(index))
        }
    }

    @Test func aLoneCharacterIsOfferedAsItIs() {
        #expect(guess("我用一下", at: 1) == "用")
    }

    @Test func theKeptPairFollowsTheWordTheUserAdded() {
        let suggestion = WordSuggestion(
            change: Correction(heard: "一", corrected: "义"),
            pair: Correction(heard: "通一千问", corrected: "通义千问")
        )
        #expect(suggestion.pair(for: "通义千问") == suggestion.pair)
        #expect(suggestion.pair(for: "通义千问3") == Correction(heard: "通一千问3", corrected: "通义千问3"))
        #expect(suggestion.pair(for: "通义") == Correction(heard: "通一", corrected: "通义"))
        #expect(suggestion.pair(for: "Qwen") == Correction(heard: "通一千问", corrected: "Qwen"))
    }
}

struct DeclinedPairTests {
    private let pair = Correction(heard: "通一千问", corrected: "通义千问")

    @Test func aDeclinedPairIsKeptAndDoesNotBlockItsWord() {
        var store = CorrectionStore()
        store.record(pair, at: Date(timeIntervalSince1970: 1_000_000))
        store.decline(pair)
        #expect(store.state(of: pair) == .declined)
        #expect(!store.has(.dismissed, for: "通义千问"))
        store.forget(pair)
        #expect(store.state(of: pair) == .declined)
        // Kept within the week, and forgotten after it like a pair seen once.
        store.record(Correction(heard: "a", corrected: "b"), at: Date(timeIntervalSince1970: 1_500_000))
        #expect(store.state(of: pair) == .declined)
        store.record(Correction(heard: "a", corrected: "b"), at: Date(timeIntervalSince1970: 3_000_000))
        #expect(store.state(of: pair) == nil)
    }
}

@MainActor
struct WordSuggestionLearningTests {
    private let suggestion = WordSuggestion(
        change: Correction(heard: "一", corrected: "义"),
        pair: Correction(heard: "通一千问", corrected: "通义千问")
    )

    private func makeLearning(_ vocabulary: CorrectionLearningTests.VocabularyBox, field: ScriptedField = ScriptedField([""])) -> CorrectionLearning {
        CorrectionLearning(
            isOn: true,
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
            removeFromVocabulary: { word in vocabulary.words.removeAll { $0 == word } },
            isInVocabulary: { vocabulary.words.contains($0) }
        )
    }

    @Test func aFixOfOneCharacterOffersTheWordAndAddsNothing() async {
        let vocabulary = CorrectionLearningTests.VocabularyBox()
        let field = ScriptedField(["我用通一千问写代码", "我用通一千问写代码", "我用通义千问写代码"])
        let learning = makeLearning(vocabulary, field: field)
        var offered: [WordSuggestion] = []
        var learned: [CorrectionLearning.Learned] = []
        learning.onSuggest = { offered.append($0) }
        learning.onLearned = { learned.append($0) }
        learning.pasted("我用通一千问写代码", in: 42)
        var lastReads = -1
        var quiet = 0
        for _ in 0..<1_000 where offered.isEmpty && quiet < 40 {
            try? await Task.sleep(for: .milliseconds(5))
            quiet = field.reads == lastReads ? quiet + 1 : 0
            lastReads = field.reads
        }
        learning.isOn = false
        #expect(offered == [suggestion])
        #expect(learned.isEmpty)
        #expect(vocabulary.words.isEmpty)
        #expect(learning.store.entries.isEmpty)
    }

    @Test func addingKeepsThePairAsAcceptedAndAddsTheEditedWord() {
        let vocabulary = CorrectionLearningTests.VocabularyBox()
        let learning = makeLearning(vocabulary)
        var learned: [CorrectionLearning.Learned] = []
        learning.onLearned = { learned.append($0) }
        learning.add(suggestion, as: " 通义千问3 ")
        #expect(vocabulary.words == ["通义千问3"])
        #expect(learning.store.state(of: Correction(heard: "通一千问3", corrected: "通义千问3")) == .accepted)
        #expect(learned.isEmpty)
        // Offered again later: already there, so not offered.
        var offered: [WordSuggestion] = []
        learning.onSuggest = { offered.append($0) }
        learning.add(suggestion, as: "通义千问")
        learning.suggest(suggestion)
        #expect(offered.isEmpty)
    }

    @Test func addingToAFullVocabularySaysSo() {
        let vocabulary = CorrectionLearningTests.VocabularyBox()
        vocabulary.limit = 0
        let learning = makeLearning(vocabulary)
        var learned: [CorrectionLearning.Learned] = []
        learning.onLearned = { learned.append($0) }
        learning.add(suggestion, as: "通义千问")
        #expect(learned.map(\.outcome) == [.vocabularyFull])
        #expect(learning.store.state(of: suggestion.pair) == .seen)
        // After the user made room, the same fix offers the word again.
        vocabulary.limit = 100
        var offered: [WordSuggestion] = []
        learning.onSuggest = { offered.append($0) }
        learning.suggest(suggestion)
        #expect(offered == [suggestion])
    }

    @Test func aDeclinedWordIsNotOfferedAgainButCanStillBeLearned() {
        let vocabulary = CorrectionLearningTests.VocabularyBox()
        let learning = makeLearning(vocabulary)
        var offered: [WordSuggestion] = []
        learning.onSuggest = { offered.append($0) }
        learning.suggest(suggestion)
        learning.decline(suggestion)
        learning.suggest(suggestion)
        #expect(offered == [suggestion])
        #expect(vocabulary.words.isEmpty)
        // A fix of more characters still learns the word on its own.
        learning.record(Correction(heard: "同一千问", corrected: "通义千问"))
        #expect(vocabulary.words == ["通义千问"])
    }

    @Test func aWordUndoneBeforeIsNotOffered() {
        let vocabulary = CorrectionLearningTests.VocabularyBox()
        let learning = makeLearning(vocabulary)
        var learned: [CorrectionLearning.Learned] = []
        var offered: [WordSuggestion] = []
        learning.onLearned = { learned.append($0) }
        learning.onSuggest = { offered.append($0) }
        learning.record(Correction(heard: "同一千问", corrected: "通义千问"))
        learning.undo(learned[0])
        learning.suggest(suggestion)
        #expect(offered.isEmpty)
    }
}
