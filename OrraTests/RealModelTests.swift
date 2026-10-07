import Foundation
import Testing
@testable import Orra

/// Groups every test that loads the real Qwen3-ASR model. Serialized, so only one model
/// runs at a time and the latency and memory readings are not skewed by another suite.
/// Skipped when the model or the evaluation data is not on this Mac.
@Suite(.serialized, .enabled(if: RealModel.folder != nil && EvaluationData.isAvailable))
struct RealModelTests {}

/// The real model on this Mac, for the tests that run it: the folder Orra installed, or,
/// before a build with the model download has run once, the copy speech-swift left in
/// ~/Library/Caches/qwen3-speech. Found by file sizes and only read, never changed.
enum RealModel {
    static var folder: URL? {
        SpeechModel.installedFolder() ?? ModelFolders.live.oldCopies.first { ModelDisk.isComplete($0, .qwen3) }
    }

    static func engine() -> Qwen3Engine {
        Qwen3Engine(folder: { folder })
    }
}
