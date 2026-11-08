import Foundation
import Testing
@testable import Orra

/// EngineTurns with more than one caller: Live Captions and Transcribe File.
@MainActor
struct EngineTurnsCallersTests {
    @MainActor
    private final class Probe {
        var attempts = (caption: 0, file: 0)
        var started = (caption: false, file: false)
        /// When the test pressed the key.
        var pressed: ContinuousClock.Instant?

        /// A first call that only the press may end, however long a busy runner takes to
        /// get to the press. It gives up 5 s after a press that did not cancel it, so the
        /// test fails then instead of waiting for good.
        func runUntilThePress() async throws {
            while pressed.map({ $0.duration(to: .now) < .seconds(5) }) ?? true {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    /// A caption call and a segment of a file can run at once, such as when captions start
    /// during a segment. A press cancels both, and both run again after the dictation.
    @Test func aPressCancelsEveryCallUnderWay() async throws {
        let turns = EngineTurns(pollInterval: .milliseconds(2))
        let probe = Probe()
        let caption = Task {
            try await turns.captionTurn { @MainActor () async throws -> Int in
                probe.attempts.caption += 1
                probe.started.caption = true
                if probe.attempts.caption == 1 {
                    try await probe.runUntilThePress()
                } else {
                    try await Task.sleep(for: .milliseconds(1))
                }
                return probe.attempts.caption
            }
        }
        let file = Task {
            try await turns.turn(for: .file, retries: .max) { @MainActor () async throws -> Int in
                probe.attempts.file += 1
                probe.started.file = true
                if probe.attempts.file == 1 {
                    try await probe.runUntilThePress()
                } else {
                    try await Task.sleep(for: .milliseconds(1))
                }
                return probe.attempts.file
            }
        }
        try await waitUntil { probe.started.caption && probe.started.file }
        probe.pressed = .now
        turns.dictationStarted()
        try await Task.sleep(for: .milliseconds(30))
        #expect(probe.attempts.caption == 1)
        #expect(probe.attempts.file == 1)
        turns.dictationEnded()
        #expect(try await caption.value == 2)
        #expect(try await file.value == 2)
    }
}
