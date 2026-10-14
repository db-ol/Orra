import Foundation
import Testing
@testable import Orra

struct BuiltinTermsTests {
    @Test func theListIsCleanAndOfAReviewableSize() {
        let terms = BuiltinTerms.all
        #expect((150...400).contains(terms.count))
        // Each term once ignoring case, and each one a vocabulary line would keep as it is.
        #expect(Set(terms.map { $0.lowercased() }).count == terms.count)
        #expect(Vocabulary.terms(from: terms) == terms)
        #expect(BuiltinTerms.all == BuiltinTerms.common + BuiltinTerms.more)
        for term in ["Qwen3.5", "Claude", "Cursor", "DeepSeek", "Kubernetes", "SwiftUI", "豆包", "通义千问", "小红书", "飞书"] {
            #expect(BuiltinTerms.common.contains(term))
        }
    }

    @Test func theUserWordsComeFirstAndKeepTheirSpelling() {
        let terms = BuiltinTerms.forModel(after: ["Orra", "chatgpt"], from: ["ChatGPT", "Claude", "Cursor"], limit: 4)
        #expect(terms == ["Orra", "chatgpt", "Claude", "Cursor"])
    }

    @Test func builtInTermsFillOnlyTheRoomLeft() {
        let builtin = ["Claude", "Cursor", "DeepSeek"]
        #expect(BuiltinTerms.forModel(after: ["a"], from: builtin, limit: 3) == ["a", "Claude", "Cursor"])
        #expect(BuiltinTerms.forModel(after: ["a", "b"], from: builtin, limit: 2) == ["a", "b"])
        #expect(BuiltinTerms.forModel(after: ["a"], from: [], limit: 2) == ["a"])
        let full = (0..<Vocabulary.modelLimit).map { "term\($0)" }
        #expect(BuiltinTerms.forModel(after: full) == full)
        let one = BuiltinTerms.forModel(after: ["Orra"])
        #expect(one.count == Vocabulary.modelLimit)
        #expect(one.dropFirst().prefix(BuiltinTerms.common.count) == ArraySlice(BuiltinTerms.common))
    }

    @Test func withoutWordsOfTheUserTheModelGetsNoContext() {
        #expect(BuiltinTerms.forModel(after: []) == [])
    }
}
