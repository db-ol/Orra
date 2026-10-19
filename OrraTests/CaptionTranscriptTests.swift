import Foundation
import Testing
@testable import Orra

/// The text Copy puts on the clipboard: final sentences only, one per line, as the window
/// shows them.
struct CaptionTranscriptTests {
    /// A translated sentence, a pending one, one without translation and one still heard.
    private let transcript = CaptionTranscript([
        CaptionSentence(id: 1, start: 0, end: 2, original: "We should ship the beta on Friday.", translation: .done("我们应该在周五发布测试版。")),
        CaptionSentence(id: 2, start: 2, end: 4, original: "Can everyone review the notes by Thursday?", translation: .pending),
        CaptionSentence(id: 3, start: 4, end: 5, original: "这个我同意。", translation: .none),
        CaptionSentence(id: 4, start: 5, end: 6, original: "so the next thing", translation: .none, isInterim: true),
    ])

    @Test func theLineStillBeingHeardIsLeftOut() {
        #expect(transcript.sentences.map(\.id) == [1, 2, 3])
        #expect(!transcript.isEmpty)
    }

    @Test func originalCopiesTheOriginals() {
        #expect(transcript.text(.original) == """
        We should ship the beta on Friday.
        Can everyone review the notes by Thursday?
        这个我同意。
        """)
    }

    @Test func translationCopiesTheOriginalWhereThereIsNoTranslation() {
        #expect(transcript.text(.translation) == """
        我们应该在周五发布测试版。
        Can everyone review the notes by Thursday?
        这个我同意。
        """)
    }

    @Test func bothPutEachTranslationUnderItsOriginalWithABlankLineBetweenSentences() {
        #expect(transcript.text(.originalAndTranslation) == """
        We should ship the beta on Friday.
        我们应该在周五发布测试版。

        Can everyone review the notes by Thursday?

        这个我同意。
        """)
    }

    @Test func aTranscriptOfOnlyAHeardLineIsEmpty() {
        let heard = CaptionTranscript([CaptionSentence(id: 1, start: 0, end: 1, original: "Hello", translation: .none, isInterim: true)])
        #expect(heard.isEmpty)
        #expect(heard.text(.originalAndTranslation).isEmpty)
    }

    @Test func copyFollowsTheDisplayMode() {
        #expect(CaptionDisplayMode.translationOnly.copyContent == .translation)
        #expect(CaptionDisplayMode.originalAndTranslation.copyContent == .originalAndTranslation)
    }
}
