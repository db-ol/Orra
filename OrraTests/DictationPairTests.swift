import Foundation
import Testing
@testable import Orra

/// The parts of the evaluations per dictation pair that need no model.
struct DictationPairTests {
    @Test func thePairComesFromTheEnvironmentWithChineseWithoutOne() throws {
        #expect(try DictationPair.chosen(in: [:]) == .chinese)
        #expect(try DictationPair.chosen(in: ["ORRA_DICTATION_LANGUAGE": ""]) == .chinese)
        #expect(try DictationPair.chosen(in: ["ORRA_DICTATION_LANGUAGE": "Chinese"]) == .chinese)
        #expect(try DictationPair.chosen(in: ["ORRA_DICTATION_LANGUAGE": "Japanese"]) == .japanese)
        #expect(try DictationPair.chosen(in: ["ORRA_DICTATION_LANGUAGE": "Spanish"]) == .spanish)
        // A name the app does not know never runs as Chinese.
        #expect(throws: DictationPair.UnknownLanguage.self) {
            try DictationPair.chosen(in: ["ORRA_DICTATION_LANGUAGE": "Korean"])
        }
        #expect([DictationPair.code(.chinese), DictationPair.code(.japanese), DictationPair.code(.spanish)] == ["zh", "ja", "es"])
    }

    @Test func theFleursClipsOfAPairAreItsOwnInTheOrderOfTheirIDs() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fleurs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let lines = [
            #"{"id": "0002_ja", "lang": "ja", "reference": "三つ目"}"#,
            #"{"id": "0000_es", "lang": "es", "reference": "uno"}"#,
            #"{"id": "0000_ja", "lang": "ja", "reference": "一つ目"}"#,
            #"{"id": "0001_ja", "lang": "ja", "reference": "二つ目"}"#,
        ]
        try lines.joined(separator: "\n").write(to: folder.appendingPathComponent("manifest.jsonl"), atomically: true, encoding: .utf8)
        let clips = try DictationPair.fleursClips(.japanese, count: 2, in: folder)
        #expect(clips.map(\.name) == ["0000_ja", "0001_ja"])
        #expect(clips.map(\.reference) == ["一つ目", "二つ目"])
        #expect(try DictationPair.fleursClips(.spanish, count: 10, in: folder).map(\.name) == ["0000_es"])
    }

    @Test func theLatencySuiteReadsTheLanguageAndLengthOfEverySayClip() throws {
        // The names of latency-say and of the pairs' latency sets in the gate sets.
        let names = ["zh_short_1.wav", "mixed_long_1.wav", "en_mid_2.wav", "ja_short_2.wav", "ja_mixed_long_1.wav", "ko_mixed_mid_1.wav", "es_long_1.wav"]
        let read = try names.map { try LatencyMeasurement.languageAndLength(of: $0) }
        #expect(read.map(\.language) == ["zh", "mixed", "en", "ja", "ja_mixed", "ko_mixed", "es"])
        #expect(read.map(\.length) == ["short", "long", "mid", "short", "long", "mid", "long"])
    }

    @Test func anotherPairTakesTheEnglishStrataOfTheCorpusOnly() {
        #expect(LatencyMeasurement.corpusStrata(for: .chinese) == ["zh_short", "en_short", "mixed", "zh_mid", "en_mid"])
        #expect(LatencyMeasurement.corpusStrata(for: .japanese) == ["en_short", "en_mid"])
        #expect(LatencyMeasurement.corpusStrata(for: .spanish) == ["en_short", "en_mid"])
    }
}
