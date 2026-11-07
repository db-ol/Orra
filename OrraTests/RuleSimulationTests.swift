import Foundation
import Testing
@testable import Orra

/// Runs the filler and number rules as a dictation runs them with both switches on, see
/// DictationRules, on texts that earlier runs stored, and writes what they give with each
/// dictation language, so a change of the rules can be checked on recorded speech model
/// output without the model. Only when asked for, with TEST_RUNNER_ORRA_RULES_INPUTS naming
/// the files, separated by colons, and TEST_RUNNER_ORRA_RULES_OUT a folder for the results:
///
///     TEST_RUNNER_ORRA_RULES_INPUTS=<file>:<file> TEST_RUNNER_ORRA_RULES_OUT=<folder> xcodebuild ... test -only-testing:OrraTests/RuleSimulationTests
///
/// It reads three kinds of file. A run of SpeechCorpusEvaluationTests gives every text
/// field of each clip, such as text, the text before the rules, and text_unhinted, and the
/// clips whose text through the rules with Chinese differs from the stored ruled_text are
/// counted. A manifest.jsonl of a corpus gives each line's reference. A run of
/// GateSetEvaluationTests gives the text it pasted, which already went through the rules.
/// Each result file, named `<folder>__<folder>__<file>.json` after the end of the input's
/// path, holds every text with what the rules make of it for each dictation language. The
/// texts go only to the output folder, never to the log or the test result.
@Suite(.serialized, .enabled(if: RuleSimulation.inputs != nil))
struct RuleSimulationTests {
    @Test func runTheRulesOnStoredTexts() throws {
        let inputs = try #require(RuleSimulation.inputs)
        let output = try #require(RuleSimulation.output, "set TEST_RUNNER_ORRA_RULES_OUT to a folder for the results")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for input in inputs {
            let (kind, texts, stored) = try RuleSimulation.texts(in: input)
            var results: [String: [String: [String: String]]] = [:]
            var differing = 0
            for (id, fields) in texts {
                var row: [String: [String: String]] = [:]
                for (field, text) in fields {
                    var ruled = ["text": text]
                    for language in DictationLanguage.allCases {
                        ruled[language.rawValue] = DictationRules.ruled(text, for: language)
                    }
                    row[field] = ruled
                }
                if let ruledText = stored[id], let text = fields["text"], DictationRules.ruled(text, for: .chinese) != ruledText {
                    differing += 1
                }
                results[id] = row
            }
            var document: [String: Any] = ["input": input.path, "kind": kind, "texts": results]
            if kind == "corpus run" {
                document["clips_differing_from_stored_ruled_text"] = differing
            }
            let folders = input.deletingLastPathComponent()
            let name = "\(folders.deletingLastPathComponent().lastPathComponent)__\(folders.lastPathComponent)__\(input.deletingPathExtension().lastPathComponent).json"
            let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: output.appendingPathComponent(name))
            // Numbers only.
            print("\(name): \(texts.count) clips of a \(kind), \(differing) differ from the stored ruled_text")
        }
    }
}

enum RuleSimulation {
    static var inputs: [URL]? {
        guard let paths = ProcessInfo.processInfo.environment["ORRA_RULES_INPUTS"], !paths.isEmpty else { return nil }
        return paths.split(separator: ":").map { URL(fileURLWithPath: (String($0) as NSString).expandingTildeInPath) }
    }

    static var output: URL? {
        guard let path = ProcessInfo.processInfo.environment["ORRA_RULES_OUT"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// The kind of file, its texts by clip and field, and the ruled_text a corpus run
    /// stored for each clip.
    static func texts(in file: URL) throws -> (kind: String, texts: [String: [String: String]], stored: [String: String]) {
        let data = try Data(contentsOf: file)
        if file.pathExtension == "jsonl" {
            var texts: [String: [String: String]] = [:]
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
                let id = try #require(object["id"] as? String)
                texts[id] = ["reference": try #require(object["reference"] as? String)]
            }
            return ("manifest", texts, [:])
        }
        let document = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        if let clips = document["clips"] as? [[String: Any]] {
            var texts: [String: [String: String]] = [:]
            for clip in clips {
                let id = "\(try #require(clip["set"] as? String))/\(try #require(clip["id"] as? String))"
                texts[id] = ["text": try #require(clip["text"] as? String)]
            }
            return ("set run", texts, [:])
        }
        let clips = try #require(document["clips"] as? [String: [String: Any]])
        var texts: [String: [String: String]] = [:]
        var stored: [String: String] = [:]
        for (id, clip) in clips {
            var fields: [String: String] = [:]
            for (key, value) in clip {
                guard let text = value as? String else { continue }
                if key == "ruled_text" {
                    stored[id] = text
                } else if key == "text" || key.hasPrefix("text_") || key.hasPrefix("caption_text") {
                    fields[key] = text
                }
            }
            texts[id] = fields
        }
        return ("corpus run", texts, stored)
    }
}
