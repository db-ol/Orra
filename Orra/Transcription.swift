import Foundation

/// What PushToTalkController needs from the speech model. Closures, so tests can pass
/// fakes. The live implementation does its work off the main actor.
struct Transcription {
    /// Loads the model. Throws when it cannot be loaded.
    var load: () async throws -> Void
    /// Turns 16 kHz mono samples into text.
    var transcribe: ([Float]) async throws -> String
}

/// The one speech model Orra uses for now: Qwen3-ASR 1.7B in the 8 bit MLX build. The
/// maintainer chose it on 2026-10-04, see docs/local-asr-models.md. Kept in one place so
/// adding Qwen3-ASR 0.6B later is a small change.
nonisolated enum SpeechModel {
    static let id = "aufklarer/Qwen3-ASR-1.7B-MLX-8bit"

    /// Where speech-swift keeps downloaded models.
    static var defaultCacheBase: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("qwen3-speech", isDirectory: true)
    }

    /// The folders speech-swift may use for a model: the current layout
    /// (models/<owner>/<name>) and the legacy one (<owner>_<name>).
    static func cacheFolders(for id: String, base: URL = defaultCacheBase) -> [URL] {
        var folders = [base.appendingPathComponent("models", isDirectory: true)]
        for part in id.split(separator: "/") {
            folders[0].appendPathComponent(String(part), isDirectory: true)
        }
        folders.append(base.appendingPathComponent(id.replacingOccurrences(of: "/", with: "_"), isDirectory: true))
        return folders
    }

    /// Files that must sit next to the weights. Without them the model loads but returns
    /// token numbers or keeps its language prefix.
    static let tokenizerFiles = ["vocab.json", "merges.txt", "tokenizer_config.json"]

    /// True when the model's weights and tokenizer are on this Mac, so it can load without
    /// a network. Reads the folders only. It never creates or downloads anything.
    static func isOnThisMac(id: String = id, base: URL = defaultCacheBase) -> Bool {
        cacheFolders(for: id, base: base).contains { folder in
            let files = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            return files.contains { $0.hasSuffix(".safetensors") } && tokenizerFiles.allSatisfy(files.contains)
        }
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
