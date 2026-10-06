import AVFoundation
import Foundation
import Speech

/// Transcribes every WAV in a folder with SpeechAnalyzer and SpeechTranscriber and
/// writes one JSON line per file: file, text, time (seconds, excluding the asset
/// install) and duration.
@main
struct AppleASR {
    static func log(_ message: String) {
        FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    }

    static func collect(_ transcriber: SpeechTranscriber) async throws -> String {
        var text = ""
        for try await result in transcriber.results where result.isFinal {
            text += String(result.text.characters)
        }
        return text
    }

    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 4 else {
            log("usage: apple_asr <locale> <dir> <out.jsonl>")
            exit(2)
        }
        let locale = Locale(identifier: args[1])
        let dir = URL(fileURLWithPath: args[2])
        let outURL = URL(fileURLWithPath: args[3])

        let assetStart = ContinuousClock.now
        let probe = SpeechTranscriber(locale: locale, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            log("Installing the speech asset for \(args[1])")
            try await request.downloadAndInstall()
        }
        log("Asset ready after \(assetStart.duration(to: .now))")

        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var output = ""
        for file in files {
            let audio = try AVAudioFile(forReading: file)
            let seconds = Double(audio.length) / audio.fileFormat.sampleRate
            let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
            let start = ContinuousClock.now
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            async let collected = collect(transcriber)
            if let end = try await analyzer.analyzeSequence(from: audio) {
                try await analyzer.finalizeAndFinish(through: end)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            let text = try await collected
            let elapsed = start.duration(to: .now).components
            let time = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            let line: [String: Any] = [
                "file": file.deletingPathExtension().lastPathComponent,
                "text": text, "time": time, "duration": seconds,
            ]
            output += String(data: try JSONSerialization.data(withJSONObject: line), encoding: .utf8)! + "\n"
        }
        try output.write(to: outURL, atomically: true, encoding: .utf8)
        log("Done: \(files.count) files")
    }
}
