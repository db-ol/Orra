import Foundation
import Testing
@testable import Orra

/// The user's words put back into a transcript from the pairs learning kept.
struct WordReplacementTests {
    /// A few ordinary English words, so the tests do not depend on the system's lists.
    private let ordinary = OrdinaryWords([
        "there", "their", "a", "pie", "cloud", "code", "and", "is", "fast", "it", "on", "today",
        "deployed", "sentinel", "the", "use", "we", "maple", "wood", "report",
    ])
    private let claude = Correction(heard: "克劳德", corrected: "Claude")

    private func replaced(_ text: String, _ pairs: [Correction], _ vocabulary: [String]) -> String {
        WordReplacement.apply(to: text, pairs: pairs, vocabulary: vocabulary, ordinary: ordinary).text
    }

    // MARK: Learned pairs

    @Test func aLearnedPairReplacesWhatTheModelWrote() {
        let result = WordReplacement.apply(to: "我在用克劳德写代码，克劳德很好", pairs: [claude], vocabulary: ["Claude"], ordinary: ordinary)
        #expect(result.text == "我在用Claude写代码，Claude很好")
        #expect(result.replacements == [
            Replacement(span: 3..<9, heard: "克劳德", corrected: "Claude", pair: claude),
            Replacement(span: 13..<19, heard: "克劳德", corrected: "Claude", pair: claude),
        ])
    }

    @Test func aPairWhoseWordLeftTheVocabularyReplacesNothing() {
        #expect(replaced("我在用克劳德写代码", [claude], []) == "我在用克劳德写代码")
        #expect(replaced("我在用克劳德写代码", [claude], ["Orra"]) == "我在用克劳德写代码")
        // The vocabulary ignores case, and so does this check.
        #expect(replaced("我在用克劳德写代码", [claude], ["claude"]) == "我在用Claude写代码")
    }

    @Test func latinWordsAreReplacedAtWordBoundariesOnly() {
        let pair = Correction(heard: "Ora", corrected: "Orra")
        #expect(replaced("Orange, Ora and Oral", [pair], ["Orra"]) == "Orange, Orra and Oral")
        #expect(replaced("我在用Ora写", [pair], ["Orra"]) == "我在用Orra写")
        #expect(replaced("Ora2 and Ora's", [pair], ["Orra"]) == "Ora2 and Orra's")
    }

    /// As learning sees it: the case of the first letter changes at the start of a
    /// sentence, other letters' case is part of the word.
    @Test func latinWordsMatchButForTheCaseOfTheFirstLetter() {
        let pair = Correction(heard: "sglang", corrected: "SGLang")
        #expect(replaced("Sglang is fast, sglang too, SGLANG not", [pair], ["SGLang"]) == "SGLang is fast, SGLang too, SGLANG not")
        #expect(replaced("我用sglang写", [pair], ["SGLang"]) == "我用SGLang写")
    }

    @Test func heardSpellingsOfOrdinaryWordsAreNeverReplaced() {
        let pairs = [Correction(heard: "there", corrected: "their"), Correction(heard: "a pie", corrected: "API")]
        #expect(replaced("there is a pie", pairs, ["their", "API"]) == "there is a pie")
        // 生根 is one word of the system's lexicon, 克劳德 is not.
        #expect(replaced("树要生根", [Correction(heard: "生根", corrected: "申根")], ["申根"]) == "树要生根")
    }

    @Test func aSingleCharacterIsNeverReplaced() {
        #expect(replaced("我得去", [Correction(heard: "得", corrected: "德")], ["德"]) == "我得去")
    }

    @Test func nothingIsReplacedInsideALongerVocabularyWord() {
        #expect(replaced("我喜欢克劳德·莫奈的画，也用克劳德", [claude], ["Claude", "克劳德·莫奈"]) == "我喜欢克劳德·莫奈的画，也用Claude")
    }

    @Test func nothingIsReplacedInsideTheWordOfAnotherPair() {
        let whole = Correction(heard: "SG Lang Omni", corrected: "SGLang-Omni")
        let part = Correction(heard: "Omni", corrected: "Omnia")
        #expect(replaced("SGLang-Omni and Omni", [whole, part], ["SGLang-Omni", "Omnia"]) == "SGLang-Omni and Omnia")
        // Also when that pair's word is no longer in the vocabulary.
        #expect(replaced("SGLang-Omni and Omni", [whole, part], ["Omnia"]) == "SGLang-Omni and Omnia")
    }

    /// A Chinese end of a heard spelling must end a word as the system breaks the text.
    @Test func aChineseHeardSpellingNeverCutsIntoAWord() {
        let pair = Correction(heard: "克劳", corrected: "克罗")
        #expect(replaced("克劳德", [pair], ["克罗"]) == "克劳德")
        #expect(replaced("克劳说", [pair], ["克罗"]) == "克罗说")
    }

    @Test func theLongestHeardSpellingWins() {
        let whole = Correction(heard: "迪力热吧", corrected: "迪丽热巴")
        let part = Correction(heard: "力热吧", corrected: "丽热巴")
        let result = WordReplacement.apply(to: "我喜欢迪力热吧和力热吧", pairs: [part, whole], vocabulary: ["迪丽热巴", "丽热巴"], ordinary: ordinary)
        #expect(result.text == "我喜欢迪丽热巴和丽热巴")
        #expect(result.replacements.map(\.pair) == [whole, part])
    }

    /// Every replacement is made in the text as the model wrote it, and a heard spelling
    /// that is a vocabulary word is the user's word, so one never feeds another.
    @Test func replacementsDoNotChain() {
        let first = Correction(heard: "Kwen", corrected: "Qwen")
        let second = Correction(heard: "Qwen", corrected: "Qwen3")
        #expect(replaced("Kwen and Qwen", [first, second], ["Qwen", "Qwen3"]) == "Qwen and Qwen")
    }

    @Test func pairsThatDisagreeReplaceNothing() {
        let other = Correction(heard: "克劳德", corrected: "Clyde")
        #expect(replaced("我在用克劳德写代码", [claude, other], ["Claude", "Clyde"]) == "我在用克劳德写代码")
        #expect(WordReplacement.usablePairs([claude, other], vocabulary: ["Claude", "Clyde"], ordinary: ordinary).isEmpty)
    }

    // MARK: Ordinary words

    @Test func ordinaryWordsTakeCommonEndingsAndCompounds() {
        let words = OrdinaryWords(["run", "stop", "traffic", "lay", "up", "city"])
        #expect(words.contains("running"))
        #expect(words.contains("stopped"))
        #expect(words.contains("trafficking"))
        #expect(words.contains("cities"))
        #expect(words.contains("layup"))
        #expect(words.contains("Run"))
        #expect(!words.contains("kubernetis"))
        #expect(words.contains("42"))
    }

    @Test func withoutWordListsEveryLatinWordIsOrdinary() {
        let none = OrdinaryWords([], everything: true)
        #expect(none.contains("kubernetis"))
        let kubernetes = Correction(heard: "Kubernetis", corrected: "Kubernetes")
        #expect(WordReplacement.apply(to: "Kubernetis", pairs: [kubernetes], vocabulary: ["Kubernetes"], ordinary: none).text == "Kubernetis")
        #expect(WordReplacement.apply(to: "Kubernetis", pairs: [kubernetes], vocabulary: ["Kubernetes"], ordinary: ordinary).text == "Kubernetes")
        // A Chinese pair does not need the lists.
        #expect(WordReplacement.apply(to: "用克劳德", pairs: [claude], vocabulary: ["Claude"], ordinary: none).text == "用Claude")
    }

    @Test func theSystemListsAreThere() {
        #expect(OrdinaryWords.system.contains("there"))
        #expect(!OrdinaryWords.system.contains("kubernetis"))
    }

    // MARK: Learning from a fix of a replaced word

    private func translated(pasted: String, edited: String, _ replacements: [Replacement]) -> [CorrectionFinder.Translation] {
        CorrectionFinder.locatedFindings(pasted: pasted, edited: edited).map {
            CorrectionFinder.translate($0, pasted: Array(pasted), replacements: replacements)
        }
    }

    private var replacedClaude: Replacement {
        Replacement(span: 3..<9, heard: "克劳德", corrected: "Claude", pair: claude)
    }

    /// A fix of a replaced word is learned with what the model wrote, not with Orra's word.
    @Test func aFixOfAReplacedWordIsLearnedWithTheHeardSpelling() {
        #expect(translated(pasted: "我在用Claude写代码", edited: "我在用Clyde写代码", [replacedClaude])
            == [.finding(.word(Correction(heard: "克劳德", corrected: "Clyde")))])
    }

    @Test func puttingBackTheHeardSpellingRevertsThePair() {
        #expect(translated(pasted: "我在用Claude写代码", edited: "我在用克劳德写代码", [replacedClaude]) == [.reverted([claude])])
    }

    @Test func aFixAwayFromTheReplacementsStaysAsItIs() {
        let orra = Correction(heard: "Ora", corrected: "Orra")
        #expect(translated(pasted: "我在用Claude写Ora", edited: "我在用Claude写Orra", [replacedClaude]) == [.finding(.word(orra))])
    }

    @Test func aFixOfPartOfAReplacedWordTeachesNothing() {
        let replacement = Replacement(span: 0..<4, heard: "迪力热吧", corrected: "迪丽热巴", pair: Correction(heard: "迪力热吧", corrected: "迪丽热巴"))
        let item = CorrectionFinder.Located(span: 2..<6, finding: .word(Correction(heard: "热巴好看", corrected: "热八好看")))
        #expect(CorrectionFinder.translate(item, pasted: Array("迪丽热巴好看"), replacements: [replacement]) == .dropped)
    }

    @Test func puttingBackALatinHeardSpellingRevertsThePair() {
        let pair = Correction(heard: "Kubernetis", corrected: "Kubernetes")
        let replacement = Replacement(span: 0..<10, heard: "Kubernetis", corrected: "Kubernetes", pair: pair)
        #expect(translated(pasted: "Kubernetes rocks", edited: "Kubernetis rocks", [replacement]) == [.reverted([pair])])
    }
}
