import Foundation
import MLX
import MLXNN
import Synchronization
import Testing
@testable import Orra

/// The lock order inversion in mlx-swift 0.31.6 that ModelGate keeps Orra out of, with no
/// model. Adapted from CompileLockRepro of mlx-swift pull request 461.
///
/// Each round compiles a new outer function, so its first call traces its body while MLX
/// holds the evaluation lock, as Qwen3-TTS's traces do. The body signals, waits 200 ms and
/// calls MLXNN.silu, the one compiled function that the voice model's traces and the speech
/// and cleanup models share. Once signalled, a second task calls silu in a loop, as the
/// speech model does. Without the gate the second task takes silu's lock and waits for the
/// evaluation lock, while the trace holds that and waits for silu's lock, for good. With
/// the gate the outer call is exclusive and the loop shared, so they never meet.
///
/// Only when asked for, and alone. A hung round cannot be undone in the test process and
/// would hang every later MLX test. Swift Testing's exit tests would give each run a
/// process of its own, but in this app hosted bundle that process also runs the app's
/// whole launch, with the user's settings and models. So a round that misses its deadline
/// ends the test process with _exit(1) and names the round. From the repository root:
///
///     TEST_RUNNER_ORRA_COMPILE_LOCK=gated xcodebuild test -project Orra.xcodeproj -scheme Orra -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData -only-testing:OrraTests/CompileLockTests
///
/// With `ungated` in place of `gated` the rounds run without the gate. On mlx-swift 0.31.6
/// the first round hangs, so the run ends with the test process gone and a line that names
/// the round. Once Orra takes a release with the fix of pull request 461, the ungated rounds
/// pass, and the voice model could share the gate.
@Suite(.serialized, .enabled(if: CompileLockRounds.mode != nil))
struct CompileLockTests {
    @Test(.enabled(if: CompileLockRounds.mode == "gated"))
    func theGateKeepsAVoiceTraceFromHanging() async {
        await CompileLockRounds.run(gated: true)
    }

    @Test(.enabled(if: CompileLockRounds.mode == "ungated"))
    func withoutTheGateMLXHangs() async {
        await CompileLockRounds.run(gated: false)
    }
}

/// The rounds of CompileLockTests.
enum CompileLockRounds {
    static let rounds = 20
    /// A round takes about 0.2 s. One that is not done by then hangs for good.
    static let deadline = 10.0

    /// `gated` or `ungated`, from TEST_RUNNER_ORRA_COMPILE_LOCK, nil when not asked for.
    static var mode: String? {
        ProcessInfo.processInfo.environment["ORRA_COMPILE_LOCK"]
    }

    static func run(gated: Bool) async {
        // Every outer function stays alive to the end, since the compiler cache knows a
        // function by its address, which a new one could reuse.
        var kept: [@Sendable (MLXArray) -> MLXArray] = []
        for round in 1...rounds {
            kept.append(await runRound(round, gated: gated))
        }
        print("The compile lock test finished \(kept.count) rounds, gated: \(gated)")
    }

    private static func runRound(_ round: Int, gated: Bool) async -> @Sendable (MLXArray) -> MLXArray {
        let gate = ModelGate()
        let traced = OneTimeSignal()
        let voiceDone = OneTimeSignal()
        let roundDone = OneTimeSignal()
        DispatchQueue.global().asyncAfter(deadline: .now() + deadline) {
            guard !roundDone.fired else { return }
            print("Round \(round) of the compile lock test hung, gated: \(gated)")
            fflush(stdout)
            // Not exit(), whose handlers could wait for the locks the hung threads hold.
            _exit(1)
        }
        let outer: @Sendable (MLXArray) -> MLXArray = compile(shapeless: true) { x in
            // Inside the trace, with the evaluation lock held.
            traced.fire()
            usleep(200_000)
            return MLXNN.silu(x) + 3
        }
        let voice = Task {
            let trace = { eval(outer(MLXArray([1, 2, 3] as [Float]))) }
            if gated {
                try? await gate.run(.exclusive) { trace() }
            } else {
                trace()
            }
            voiceDone.fire()
        }
        let speech = Task {
            await traced.wait()
            let input = MLXArray([4, 5, 6] as [Float])
            let step = { eval(MLXNN.silu(input)) }
            var steps = 0
            repeat {
                if gated {
                    try? await gate.run(.shared) { step() }
                } else {
                    step()
                }
                steps += 1
            } while !voiceDone.fired && steps < 1_000
        }
        await voice.value
        await speech.value
        roundDone.fire()
        return outer
    }
}

/// A one time signal that tasks can wait for and a closure can fire from any thread.
final class OneTimeSignal: Sendable {
    private let state = Mutex<(fired: Bool, waiting: [CheckedContinuation<Void, Never>])>((false, []))

    var fired: Bool {
        state.withLock { $0.fired }
    }

    func fire() {
        let waiting = state.withLock { state in
            state.fired = true
            defer { state.waiting = [] }
            return state.waiting
        }
        for continuation in waiting {
            continuation.resume()
        }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let fired = state.withLock { state in
                if !state.fired {
                    state.waiting.append(continuation)
                }
                return state.fired
            }
            if fired {
                continuation.resume()
            }
        }
    }
}
