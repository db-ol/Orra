import Foundation
import OSLog

/// What PushToTalkController needs from the speech model. Closures, so tests can pass
/// fakes. The live implementation does its work off the main actor.
struct Transcription {
    /// Loads the model. Throws when it cannot be loaded.
    var load: () async throws -> Void
    /// Turns 16 kHz mono samples into text. The context is the user's vocabulary, after
    /// the names from the screen while Use names on screen is on, one term per line, or
    /// nil. The language is the one the model must write, or nil to let it choose.
    var transcribe: (_ samples: [Float], _ context: String?, _ language: SpeechLanguage?) async throws -> String
    /// The model gate the speech model runs at, see `gated`. Nil when it runs at none, as
    /// a test's fake does. A dictation reserves it, see PushToTalkController.
    var gate: ModelGate? = nil
}

extension Transcription {
    /// Turns samples into text with the vocabulary as context, guarded against a transcript
    /// in a language the user does not dictate in, see `checkingLanguage`, and against an
    /// echo of the vocabulary, see VocabularyEcho. When the text is only vocabulary terms,
    /// the same samples are transcribed again without the vocabulary. If that pass hears nothing,
    /// nobody spoke and the text is empty. Otherwise the user said the terms, and the text
    /// with the vocabulary stands, since it writes them the user's way. Speech means a
    /// letter or a digit, so a pass that gives only punctuation heard nothing. When that
    /// pass fails, the text with the vocabulary stands too, as it did before the check. A
    /// known limit: a single term spoken so softly that only the pass with the vocabulary
    /// hears it is dropped like an echo. Any other text with the vocabulary gets its numbers
    /// in digits from a pass without it, see `takingNumbers`, unless `takingDigits` is off
    /// because the user wants numbers in words.
    ///
    /// When the terms hold names read from the screen, `holdsScreenNames`, the protections
    /// of ListEcho apply too, so a list of names is never pasted in place of speech: a text
    /// of two or more terms only that does not sound like the pass without them gives way
    /// to that pass, and so does a text that may be a list, see `checkingList`. A name said
    /// alone stays.
    /// Logs a timing and whether speech was heard, never the text.
    func transcribe(_ samples: [Float], vocabulary terms: [String], holdsScreenNames: Bool = false, audioSeconds: Double, takingDigits: Bool = true, language: DictationLanguage = .chinese) async throws -> String {
        let context = Vocabulary.context(terms)
        let text = try await checkingLanguage(try await transcribe(samples, context, nil), of: samples, context: context, language: language)
        guard !terms.isEmpty else { return text }
        guard await Self.isOnlyTerms(text, of: terms) else {
            if holdsScreenNames, await Self.mayBeList(text, of: terms) {
                return try await checkingList(text, of: samples, terms: terms, audioSeconds: audioSeconds, takingDigits: takingDigits, language: language)
            }
            guard takingDigits else { return text }
            return try await takingNumbers(into: text, of: samples, terms: terms)
        }
        let started = ContinuousClock.now
        let plain: String
        do {
            plain = try await transcribe(samples, nil, nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Logger.pushToTalk.error("Transcript held only vocabulary terms, the pass without them failed after \(started.duration(to: .now), privacy: .public)")
            return text
        }
        let heardSpeech = !VocabularyEcho.normalized(TranscriptGuard.clean(plain, audioSeconds: audioSeconds)).isEmpty
        Logger.pushToTalk.notice("Transcript held only vocabulary terms, the pass without them took \(started.duration(to: .now), privacy: .public), speech heard: \(heardSpeech, privacy: .public)")
        guard heardSpeech else { return "" }
        if holdsScreenNames, await Self.isListOverSpeech(text, plain: plain, terms: terms) {
            Logger.pushToTalk.notice("Transcript was a list of terms over speech (\(ListEcho.Protection.onlyTermsOverSpeech.rawValue, privacy: .public)), the pass without them stands")
            return try await checkingLanguage(plain, of: samples, context: nil, language: language)
        }
        return text
    }

    /// For a text with names from the screen that may be a list written over speech, see
    /// ListEcho: transcribes the samples again without the terms. When that pass shows the
    /// text to be a list, the pass stands. Otherwise the text stands, with its numbers in
    /// digits from that pass as in `takingNumbers` unless `takingDigits` is off. When the
    /// pass fails, the text stands as it is.
    /// Logs a timing and which protection decided, never the text.
    private func checkingList(_ text: String, of samples: [Float], terms: [String], audioSeconds: Double, takingDigits: Bool, language: DictationLanguage) async throws -> String {
        let started = ContinuousClock.now
        let plain: String
        do {
            plain = try await transcribe(samples, nil, nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Logger.pushToTalk.error("Transcript may be a list of terms, the pass without them failed after \(started.duration(to: .now), privacy: .public)")
            return text
        }
        let heardSpeech = !VocabularyEcho.normalized(TranscriptGuard.clean(plain, audioSeconds: audioSeconds)).isEmpty
        if let protection = await Self.protection(text, plain: plain, terms: terms, heardSpeech: heardSpeech) {
            Logger.pushToTalk.notice("Transcript was a list of terms (\(protection.rawValue, privacy: .public)), the pass without them took \(started.duration(to: .now), privacy: .public) and stands")
            return try await checkingLanguage(plain, of: samples, context: nil, language: language)
        }
        Logger.pushToTalk.notice("Transcript may have been a list of terms, the pass without them took \(started.duration(to: .now), privacy: .public), the text stands")
        guard takingDigits, ContextNumbers.mayHoldSpokenNumber(text) else { return text }
        return await Self.merging(text, plain: plain, terms: terms)
    }

    /// Turns a recording into text in pieces of at most a minute, see RecordingPieces, one
    /// after another, each the way `transcribe(_:vocabulary:holdsScreenNames:audioSeconds:takingDigits:language:)`
    /// turns a recording into text, with the vocabulary, its echo check, the number pass
    /// and the language check of its own. A recording of up to a minute is one piece,
    /// transcribed as before, and its failure throws. Of several pieces, one that fails
    /// gives no text and the others go on, while a cancellation ends them all. When no
    /// piece gave text and one failed, the first failure throws.
    /// Logs the number of pieces and their times, never the text.
    func transcribeInPieces(_ samples: [Float], vocabulary terms: [String], holdsScreenNames: Bool = false, audioSeconds: Double, takingDigits: Bool = true, language: DictationLanguage = .chinese) async throws -> [TranscribedPiece] {
        // A recording of up to a minute needs no look for a cut.
        let isOnePiece = Double(samples.count) <= RecordingPieces.maximumSeconds * Double(RecordingLimits.sampleRate)
        let bounds = isOnePiece ? [samples.indices] : await Self.pieces(of: samples)
        guard bounds.count > 1 else {
            let text = try await transcribe(samples, vocabulary: terms, holdsScreenNames: holdsScreenNames, audioSeconds: audioSeconds, takingDigits: takingDigits, language: language)
            return [TranscribedPiece(text: text, seconds: audioSeconds)]
        }
        let started = ContinuousClock.now
        var pieces: [TranscribedPiece] = []
        var failure: (any Error)?
        var lastTook = Duration.zero
        for (index, range) in bounds.enumerated() {
            let seconds = Double(range.count) / Double(RecordingLimits.sampleRate)
            let pieceStarted = ContinuousClock.now
            do {
                let text = try await transcribe(Array(samples[range]), vocabulary: terms, holdsScreenNames: holdsScreenNames, audioSeconds: seconds, takingDigits: takingDigits, language: language)
                pieces.append(TranscribedPiece(text: text, seconds: seconds))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Logger.pushToTalk.error("Piece \(index + 1, privacy: .public) of \(bounds.count, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                failure = failure ?? error
                pieces.append(TranscribedPiece(text: nil, seconds: seconds))
            }
            lastTook = pieceStarted.duration(to: .now)
        }
        let failed = pieces.count(where: { $0.text == nil })
        Logger.pushToTalk.notice("Transcribed \(bounds.count, privacy: .public) pieces in \(started.duration(to: .now), privacy: .public), the last in \(lastTook, privacy: .public), failed: \(failed, privacy: .public)")
        if let failure, pieces.allSatisfy({ $0.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true }) {
            throw failure
        }
        return pieces
    }

    /// The text written with the vocabulary, with its numbers in Chinese characters written
    /// as digits where a pass without the vocabulary wrote the same number in digits, see
    /// ContextNumbers. That pass runs only when the text may hold such a number. When it
    /// fails, the text stands.
    /// Logs a timing and whether digits were taken, never the text.
    func takingNumbers(into text: String, of samples: [Float], terms: [String]) async throws -> String {
        guard ContextNumbers.mayHoldSpokenNumber(text) else { return text }
        let started = ContinuousClock.now
        let plain: String
        do {
            plain = try await transcribe(samples, nil, nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Logger.pushToTalk.error("Transcript may hold a number in words, the pass without the vocabulary failed after \(started.duration(to: .now), privacy: .public)")
            return text
        }
        let merged = await Self.merging(text, plain: plain, terms: terms)
        Logger.pushToTalk.notice("Transcript may hold a number in words, the pass without the vocabulary took \(started.duration(to: .now), privacy: .public), digits taken: \(merged != text, privacy: .public)")
        return merged
    }

    /// Turns a sentence of Live Captions into text: one pass without a vocabulary, which
    /// stands when its text is in any of the four languages captions read, see
    /// LanguageGuard.isForeignToCaptions, so a meeting in Japanese or Spanish keeps what the
    /// speech model wrote whatever the dictation language. Only text in a fifth language is
    /// transcribed again, in the dictation language and then in English, as in
    /// `checkingLanguage`. A dictation keeps the check of its dictation language.
    /// Logs a timing and the language that stood, never the text.
    func transcribeCaption(_ samples: [Float], language: DictationLanguage) async throws -> String {
        try await checkingLanguage(try await transcribe(samples, nil, nil), of: samples, context: nil, language: language, forCaptions: true)
    }

    /// Returns the text when LanguageGuard finds it in the dictation language or English.
    /// Otherwise the model chose a third language, and the same samples are transcribed
    /// again with the same context, first with the dictation language as the language,
    /// then with English, see DictationLanguage.passes. The first of these passes that
    /// gives text in one of the two stands. The dictation language goes first. On the
    /// speech corpus and on FLEURS the model chose a third language only for Chinese
    /// speech, and with English as the language it translated that clip into English. A
    /// known limit: if English speech ever came out in a third language, the pass in
    /// Chinese would keep it in English for most clips but translate some, on the corpus
    /// 10 of 147 English clips. When neither pass helps or one fails, the text stands as
    /// it was. With `forCaptions`, text in any of the four languages captions read stands,
    /// see `transcribeCaption`.
    /// Logs a timing and the language that stood, never the text.
    func checkingLanguage(_ text: String, of samples: [Float], context: String?, language: DictationLanguage = .chinese, forCaptions: Bool = false) async throws -> String {
        guard await Self.isForeign(text, for: language, forCaptions: forCaptions) else { return text }
        let started = ContinuousClock.now
        for pass in language.passes {
            // A caption cancelled for a dictation starts no pass, see EngineTurns.
            try Task.checkCancellation()
            let hinted: String
            do {
                hinted = try await transcribe(samples, context, pass)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Logger.pushToTalk.error("Transcript was in another language, the pass in \(pass.rawValue, privacy: .public) failed after \(started.duration(to: .now), privacy: .public)")
                return text
            }
            if !hinted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, await !Self.isForeign(hinted, for: language, forCaptions: forCaptions) {
                Logger.pushToTalk.notice("Transcript was in another language, the pass in \(pass.rawValue, privacy: .public) stands, took \(started.duration(to: .now), privacy: .public)")
                return hinted
            }
        }
        Logger.pushToTalk.notice("Transcript was in another language, no pass in \(language.passes.map(\.rawValue).joined(separator: " or "), privacy: .public) helped, took \(started.duration(to: .now), privacy: .public)")
        return text
    }

    /// Off the main actor, since the cuts read the whole recording.
    @concurrent
    nonisolated private static func pieces(of samples: [Float]) async -> [Range<Int>] {
        RecordingPieces.bounds(of: samples)
    }

    /// Off the main actor, since NLLanguageRecognizer reads the whole text.
    @concurrent
    nonisolated private static func isForeign(_ text: String, for language: DictationLanguage, forCaptions: Bool) async -> Bool {
        forCaptions ? LanguageGuard.isForeignToCaptions(text) : LanguageGuard.isForeign(text, for: language)
    }

    /// Off the main actor, since a long transcript is compared character by character.
    @concurrent
    nonisolated private static func merging(_ text: String, plain: String, terms: [String]) async -> String {
        ContextNumbers.merging(text, plain: plain, terms: terms)
    }

    /// Off the main actor, since a long transcript is compared with every term.
    @concurrent
    nonisolated private static func isOnlyTerms(_ text: String, of terms: [String]) async -> Bool {
        VocabularyEcho.isOnlyTerms(text, of: terms)
    }

    /// Off the main actor, since a long transcript is compared with every term.
    @concurrent
    nonisolated private static func mayBeList(_ text: String, of terms: [String]) async -> Bool {
        ListEcho.mayBeList(text, terms: terms)
    }

    /// Off the main actor, since a long transcript is compared with every term.
    @concurrent
    nonisolated private static func protection(_ text: String, plain: String, terms: [String], heardSpeech: Bool) async -> ListEcho.Protection? {
        ListEcho.protection(text, plain: plain, terms: terms, heardSpeech: heardSpeech)
    }

    /// Off the main actor, since the sound of Han text comes from a transform and the text
    /// is compared with every term.
    @concurrent
    nonisolated private static func isListOverSpeech(_ text: String, plain: String, terms: [String]) async -> Bool {
        ListEcho.isListOverSpeech(text, plain: plain, terms: terms)
    }
}

/// The one speech model Orra uses for now: Qwen3-ASR 1.7B in the 8 bit MLX build. The
/// maintainer chose it on 2026-10-04, see docs/local-asr-models.md. ModelManifest.qwen3
/// pins its files. Kept in one place so adding Qwen3-ASR 0.6B later is a small change.
nonisolated enum SpeechModel {
    static let id = "aufklarer/Qwen3-ASR-1.7B-MLX-8bit"

    /// The folder ModelInstaller installed the model in, when every pinned file is there at
    /// its size, the tokenizer files included. Reads sizes only. It never creates or
    /// downloads anything.
    static func installedFolder(_ folders: ModelFolders = .live, _ manifest: ModelManifest = .qwen3) -> URL? {
        let folder = folders.installed(manifest)
        return ModelDisk.isComplete(folder, manifest) ? folder : nil
    }
}

nonisolated enum TranscriptionError: Error, Equatable {
    /// The model files are not where Orra looks for them.
    case modelMissing
    /// There was no audio to transcribe.
    case noAudio
}

/// Catches decoding loops in model output.
///
/// A speech model can get stuck and repeat one phrase hundreds of times, which the public
/// baseline saw once ("非常" over and over). Two rules, both independent of the model:
/// a phrase of up to 10 characters repeated 6 or more times in a row, over at least 20
/// characters, is cut back to two copies, and text longer than the audio could hold (30
/// characters per second plus 30) is cut at that length. The 20 character floor keeps
/// numbers such as 13800000000 or a code such as 000000 intact.
nonisolated enum TranscriptGuard {
    static let repeatLimit = 6
    static let minimumLoopLength = 20
    static let charactersPerSecond = 30.0
    static let extraCharacters = 30

    static func clean(_ text: String, audioSeconds: Double) -> String {
        var result = collapseRepeats(in: text)
        let limit = Int(audioSeconds * charactersPerSecond) + extraCharacters
        if result.count > limit {
            result = String(result.prefix(limit))
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cuts every run of one phrase repeated `repeatLimit` or more times back to two copies.
    static func collapseRepeats(in text: String) -> String {
        let characters = Array(text)
        var output: [Character] = []
        var index = 0
        while index < characters.count {
            var collapsed = false
            for length in 1...10 where index + length * repeatLimit <= characters.count {
                let unit = characters[index..<(index + length)]
                var copies = 1
                while index + (copies + 1) * length <= characters.count,
                      characters[(index + copies * length)..<(index + (copies + 1) * length)].elementsEqual(unit) {
                    copies += 1
                }
                if copies >= repeatLimit, copies * length >= minimumLoopLength {
                    output.append(contentsOf: unit)
                    output.append(contentsOf: unit)
                    index += copies * length
                    collapsed = true
                    break
                }
            }
            if !collapsed {
                output.append(characters[index])
                index += 1
            }
        }
        return String(output)
    }
}
