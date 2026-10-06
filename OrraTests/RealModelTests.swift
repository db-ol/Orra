import Testing
@testable import Orra

/// Groups every test that loads the real Qwen3-ASR model. Serialized, so only one model
/// runs at a time and the latency and memory readings are not skewed by another suite.
/// Skipped when the model or the evaluation data is not on this Mac.
@Suite(.serialized, .enabled(if: SpeechModel.isOnThisMac() && EvaluationData.isAvailable))
struct RealModelTests {}
