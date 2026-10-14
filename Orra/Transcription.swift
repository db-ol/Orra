import Foundation
import OSLog

/// What PushToTalkController needs from the speech model. Closures, so tests can pass
/// fakes. The live implementation does its work off the main actor.
struct Transcription {
    /// Loads the model. Throws when it cannot be loaded.
    var load: () async throws -> Void
    /// Turns 16 kHz mono samples into text. The context is the user's vocabulary, one
    /// term per line, or nil. The language is the one the model must write, or nil to let
    /// it choose.
    var transcribe: (_ samples: [Float], _ context: String?, _ language: SpeechLanguage?) async throws -> String
}

extension Transcription {
    /// Turns samples into text with the vocabulary as context, guarded against a transcript
    /// in a language other than Chinese or English, see `checkingLanguage`, and against an
    /// echo of the vocabulary, see VocabularyEcho. When the text is only vocabulary terms,
    /// the same samples are transcribed again without the vocabulary. If that pass hears nothing,
    /// nobody spoke and the text is empty. Otherwise the user said the terms, and the text
    /// with the vocabulary stands, since it writes them the user's way. Speech means a
    /// letter or a digit, so a pass that gives only punctuation heard nothing. When that
    /// pass fails, the text with the vocabulary stands too, as it did before the check. A
    /// known limit: a single term spoken so softly that only the pass with the vocabulary
    /// hears it is dropped like an echo. Any other text with the vocabulary gets its numbers
    /// in digits from a pass without it, see `takingNumbers`.
    /// Logs a timing and whether speech was heard, never the text.
    func transcribe(_ samples: [Float], vocabulary terms: [String], audioSeconds: Double) async throws -> String {
        let context = Vocabulary.context(terms)
        let text = try await checkingLanguage(try await transcribe(samples, context, nil), of: samples, context: context)
        guard !terms.isEmpty else { return text }
        guard await Self.isOnlyTerms(text, of: terms) else {
            return try await takingNumbers(into: text, of: samples, terms: terms)
        }
        let logger = Logger(subsystem: "io.github.db-ol.Orra", category: "push-to-talk")
        let started = ContinuousClock.now
        let plain: String
        do {
            plain = try await transcribe(samples, nil, nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.error("Transcript held only vocabulary terms, the pass without them failed after \(started.duration(to: .now), privacy: .public)")
            return text
        }
        let heardSpeech = !VocabularyEcho.normalized(TranscriptGuard.clean(plain, audioSeconds: audioSeconds)).isEmpty
        logger.notice("Transcript held only vocabulary terms, the pass without them took \(started.duration(to: .now), privacy: .public), speech heard: \(heardSpeech, privacy: .public)")
        return heardSpeech ? text : ""
    }

    /// The text written with the vocabulary, with its numbers in Chinese characters written
    /// as digits where a pass without the vocabulary wrote the same number in digits, see
    /// ContextNumbers. That pass runs only when the text may hold such a number. When it
    /// fails, the text stands.
    /// Logs a timing and whether digits were taken, never the text.
    func takingNumbers(into text: String, of samples: [Float], terms: [String]) async throws -> String {
        guard ContextNumbers.mayHoldSpokenNumber(text) else { return text }
        let logger = Logger(subsystem: "io.github.db-ol.Orra", category: "push-to-talk")
        let started = ContinuousClock.now
        let plain: String
        do {
            plain = try await transcribe(samples, nil, nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.error("Transcript may hold a number in words, the pass without the vocabulary failed after \(started.duration(to: .now), privacy: .public)")
            return text
        }
        let merged = await Self.merging(text, plain: plain, terms: terms)
        logger.notice("Transcript may hold a number in words, the pass without the vocabulary took \(started.duration(to: .now), privacy: .public), digits taken: \(merged != text, privacy: .public)")
        return merged
    }

    /// Returns the text when LanguageGuard finds it in Chinese or English. Otherwise the
    /// model chose a third language, and the same samples are transcribed again with the
    /// same context, first with Chinese as the language, then with English. The first of
    /// these passes that gives text in Chinese or English stands. Chinese goes first. On
    /// the speech corpus and on FLEURS the model chose a third language only for Chinese
    /// speech, and with English as the language it translated that clip into English. A
    /// known limit: if English speech ever came out in a third language, the pass in
    /// Chinese would keep it in English for most clips but translate some, on the corpus
    /// 10 of 147 English clips. When neither pass helps or one fails, the text stands as
    /// it was.
    /// Logs a timing and the language that stood, never the text.
    func checkingLanguage(_ text: String, of samples: [Float], context: String?) async throws -> String {
        guard await Self.isForeign(text) else { return text }
        let logger = Logger(subsystem: "io.github.db-ol.Orra", category: "push-to-talk")
        let started = ContinuousClock.now
        for language in [SpeechLanguage.chinese, .english] {
            let hinted: String
            do {
                hinted = try await transcribe(samples, context, language)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                logger.error("Transcript was in another language, the pass in \(language.rawValue, privacy: .public) failed after \(started.duration(to: .now), privacy: .public)")
                return text
            }
            if !hinted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, await !Self.isForeign(hinted) {
                logger.notice("Transcript was in another language, the pass in \(language.rawValue, privacy: .public) stands, took \(started.duration(to: .now), privacy: .public)")
                return hinted
            }
        }
        logger.notice("Transcript was in another language, no pass in Chinese or English helped, took \(started.duration(to: .now), privacy: .public)")
        return text
    }

    /// Off the main actor, since NLLanguageRecognizer reads the whole text.
    @concurrent
    nonisolated private static func isForeign(_ text: String) async -> Bool {
        LanguageGuard.isForeign(text)
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
