import Foundation
import Testing
@testable import Orra

/// The dictation pair an opt in evaluation runs with, for the measurements of each pair in
/// docs/release-gate.md, read the same way by every evaluation that takes one. Without
/// TEST_RUNNER_ORRA_DICTATION_LANGUAGE an evaluation runs with Chinese, the default, and
/// writes exactly what it wrote before it took a pair, so its numbers stay comparable with
/// the gate's baselines. With the variable it runs the way the app runs for the pair it
/// names, see DictationLanguage, and its gate file names that pair in dictation_language,
/// Chinese included, which gate.py checks for every run of a pair.
nonisolated enum DictationPair {
    /// A name that is no dictation language, such as Korean before the app has it.
    struct UnknownLanguage: Error, CustomStringConvertible {
        let name: String

        var description: String {
            "TEST_RUNNER_ORRA_DICTATION_LANGUAGE names no dictation language: \(name)"
        }
    }

    /// The pair the environment names, Chinese without the variable. Its value must be a
    /// dictation language as DictationLanguage spells it, such as Japanese. Any other value,
    /// an empty one too, throws, so a run never measures Chinese under another pair's name.
    static func chosen(in environment: [String: String] = ProcessInfo.processInfo.environment) throws -> DictationLanguage {
        guard let name = environment["ORRA_DICTATION_LANGUAGE"] else { return .chinese }
        guard let language = DictationLanguage(rawValue: name) else { throw UnknownLanguage(name: name) }
        return language
    }

    /// A gate file's document with the pair in dictation_language when the variable names
    /// one, and as it is without the variable, so a run without a pair writes what it always
    /// wrote. Every run of a pair sets the variable, so gate.py refuses a file of a pair
    /// without the key.
    static func marked(_ document: [String: Any], in environment: [String: String] = ProcessInfo.processInfo.environment) throws -> [String: Any] {
        guard environment["ORRA_DICTATION_LANGUAGE"] != nil else { return document }
        var marked = document
        marked["dictation_language"] = try chosen(in: environment).rawValue
        return marked
    }

    /// The speech model's text for a recording the way PushToTalkController gets it with the
    /// pair chosen, before the post steps: Transcription with the vocabulary as context, the
    /// pair's language check, the echo check and, where the pair takes them, digits from a
    /// pass without the vocabulary. In one piece, as a dictation of up to a minute is.
    @MainActor
    static func transcribe(_ samples: [Float], vocabulary: [String], language: DictationLanguage, transcription: Transcription) async throws -> String {
        try await transcription.transcribe(
            samples,
            vocabulary: vocabulary,
            audioSeconds: Double(samples.count) / Double(RecordingLimits.sampleRate),
            takingDigits: language.takesDigitsFromPassWithoutVocabulary,
            language: language
        )
    }

    /// The folder TEST_RUNNER_ORRA_FLEURS_DIR names, in the layout of the speech corpus:
    /// clips/<id>.wav and manifest.jsonl with id, lang and reference, such as
    /// bench/fleurs-ja-es or bench/fleurs-ko.
    static var fleursFolder: URL? {
        guard let path = ProcessInfo.processInfo.environment["ORRA_FLEURS_DIR"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// The first `count` clips of that folder in the pair's language, by ID, with their
    /// reference.
    static func fleursClips(_ language: DictationLanguage, count: Int, in folder: URL? = fleursFolder) throws -> [(name: String, reference: String)] {
        let root = try #require(folder, "set TEST_RUNNER_ORRA_FLEURS_DIR to a folder with the FLEURS clips of the pair")
        var clips: [(name: String, reference: String)] = []
        for line in try String(contentsOf: root.appendingPathComponent("manifest.jsonl"), encoding: .utf8).split(separator: "\n") {
            let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            guard object["lang"] as? String == language.pairCode else { continue }
            let id = try #require(object["id"] as? String)
            let reference = try #require(object["reference"] as? String)
            clips.append((name: id, reference: reference))
        }
        try #require(!clips.isEmpty, "no clip with lang \(language.pairCode) in \(root.path)")
        return Array(clips.sorted { $0.name < $1.name }.prefix(count))
    }

    /// 16 kHz mono samples of a clip of that folder.
    static func fleursSamples(_ name: String, in folder: URL? = fleursFolder) throws -> [Float] {
        let root = try #require(folder, "set TEST_RUNNER_ORRA_FLEURS_DIR to a folder with the FLEURS clips of the pair")
        return AudioResampler.monoAt16kHz(try SpeechCorpus.recording(root.appendingPathComponent("clips/\(name).wav")))
    }
}

extension DictationLanguage {
    /// The code of the pair in the release gate's files, the one table of them in the tests:
    /// the pair a set's set.json names, run.sh's --pairs, the lang of a manifest line in the
    /// pair's language, and the names of a pair's sets and reports. gate.py's PAIRS holds the
    /// same codes. A switch, so a new pair needs its code here.
    var pairCode: String {
        switch self {
        case .chinese: "zh"
        case .japanese: "ja"
        case .spanish: "es"
        }
    }
}
