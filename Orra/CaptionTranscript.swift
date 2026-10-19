import Foundation

/// The final sentences of a meeting's captions, for copying them as plain text. Lines
/// still being heard are left out. In memory only, like the captions, and never logged.
nonisolated struct CaptionTranscript: Equatable, Sendable {
    /// What a copy holds of each sentence.
    nonisolated enum Content: Equatable, Sendable {
        /// The originals.
        case original
        /// The translations, and the original of a sentence without one.
        case translation
        /// Each original with its translation below it.
        case originalAndTranslation

        /// The name in the log.
        var logName: String {
            switch self {
            case .original: "original"
            case .translation: "translation"
            case .originalAndTranslation: "both"
            }
        }
    }

    /// The final sentences, oldest first.
    let sentences: [CaptionSentence]

    init(_ sentences: some Sequence<CaptionSentence>) {
        self.sentences = sentences.filter { !$0.isInterim }
    }

    var isEmpty: Bool {
        sentences.isEmpty
    }

    /// The text to copy, one sentence per line. With both, the original comes first and
    /// its translation second, as in the window, with a blank line between sentences. A
    /// sentence without a translation, pending or none, is copied as its original.
    /// Nothing is added: no header, no times, no labels.
    func text(_ content: Content) -> String {
        switch content {
        case .original:
            sentences.map(\.original).joined(separator: "\n")
        case .translation:
            sentences.map { $0.translatedText ?? $0.original }.joined(separator: "\n")
        case .originalAndTranslation:
            sentences.map { sentence in
                sentence.translatedText.map { "\(sentence.original)\n\($0)" } ?? sentence.original
            }
            .joined(separator: "\n\n")
        }
    }
}

extension CaptionDisplayMode {
    /// What Copy copies in this mode: every sentence the way the window shows it.
    nonisolated var copyContent: CaptionTranscript.Content {
        switch self {
        case .originalOnly: .original
        case .translationOnly: .translation
        case .originalAndTranslation: .originalAndTranslation
        }
    }
}
