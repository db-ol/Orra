import Foundation

/// Where the opt in evaluations write their results for the release gate,
/// Tools/release-gate/run.sh. With TEST_RUNNER_ORRA_GATE_OUT set to a folder, an
/// evaluation writes one JSON file there with a row per clip or case, which
/// Tools/release-gate/gate.py compares with a baseline. Without it nothing is written.
enum GateOutput {
    static var folder: URL? {
        guard let path = ProcessInfo.processInfo.environment["ORRA_GATE_OUT"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    static var build: String {
        #if DEBUG
        "Debug"
        #else
        "Release"
        #endif
    }

    /// Writes the document as `<name>.json` with the build and the chip added. Does
    /// nothing when no folder is set.
    static func write(_ document: [String: Any], named name: String) throws {
        guard let folder else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var document = document
        document["build"] = build
        document["device"] = SpeechCorpus.chip()
        let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: folder.appendingPathComponent("\(name).json"))
    }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
