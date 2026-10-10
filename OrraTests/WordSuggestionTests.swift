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
        // Kept past the week that forgets pairs seen once.
        store.record(Correction(heard: "a", corrected: "b"), at: Date(timeIntervalSince1970: 3_000_000))
        #expect(store.state(of: pair) == .declined)
    }
}
