import Qwen3ASR
import Testing
@testable import Orra

/// Which part of a hypothesis made while the key was held the final pass keeps.
struct HypothesisPrefixTests {
    let marker = Int32(Qwen3ASRTokens.asrTextTokenId)

    @Test func dropsTheLastTokens() {
        let text = (1...20).map { Int32($0) }
        let tokens = [11, 12, marker] + text
        let kept = HypothesisPrefix.cut(tokens)
        #expect(kept == Array(tokens.prefix(tokens.count - HypothesisPrefix.droppedTokens)))
    }

    @Test func keepsTheLanguageStartOfAShortHypothesis() {
        let tokens: [Int32] = [11, 12, marker, 1, 2, 3]
        #expect(HypothesisPrefix.cut(tokens) == [11, 12, marker])
    }

    @Test func forcesNothingWithoutTheTextMarker() {
        #expect(HypothesisPrefix.cut([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]).isEmpty)
        #expect(HypothesisPrefix.cut([]).isEmpty)
    }
}
