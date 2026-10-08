import AppKit
import Foundation
import Testing
@testable import Orra

/// Records what a RecordingFeedback showed, played and saved. Opens no window and plays
/// no sound.
@MainActor
final class FeedbackOutputs {
    var presented: [RecordingFeedback.Display?] = []
    var played: [RecordingFeedback.Sound] = []
    var saved: [FeedbackPreference.Values] = []
    var level: Float = 0
    /// How often the feedback read the microphone level.
    var levelReads = 0

    /// The latest display passed on, nil when hidden or when nothing was passed yet.
    var lastPresented: RecordingFeedback.Display? {
        presented.last ?? nil
    }
}

@MainActor
struct RecordingFeedbackTests {
    let outputs = FeedbackOutputs()

    /// A feedback that reports to `outputs`, or to the test's own outputs when nil.
    private func makeFeedback(
        _ outputs: FeedbackOutputs? = nil,
        preferences: FeedbackPreference.Values = .init(),
        messageDuration: Duration = .seconds(4)
    ) -> RecordingFeedback {
        let outputs = outputs ?? self.outputs
        return RecordingFeedback(
            preferences: preferences,
            inputLevel: { [outputs] in
                outputs.levelReads += 1
                return outputs.level
            },
            present: { [outputs] in outputs.presented.append($0) },
            play: { [outputs] in outputs.played.append($0) },
            save: { [outputs] in outputs.saved.append($0) },
            messageDuration: messageDuration,
            levelInterval: .milliseconds(5)
        )
    }

    /// Waits until `condition` holds, for at most five seconds.
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<1_000 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func aDictationShowsTheMeterThenTheSpinnerThenNothing() {
        let feedback = makeFeedback()
        feedback.handle(.listening)
        #expect(feedback.display == .listening)
        feedback.handle(.transcribing)
        #expect(feedback.display == .transcribing)
        feedback.handle(.recordingStopped)
        feedback.handle(.finished(message: nil))
        #expect(feedback.display == nil)
        #expect(outputs.presented == [.listening, .transcribing, nil])
    }

    @Test func theSoundsPlayWhenRecordingStartsAndStops() {
        let feedback = makeFeedback()
        feedback.handle(.listening)
        #expect(outputs.played == [.start])
        feedback.handle(.transcribing)
        #expect(outputs.played == [.start])
        feedback.handle(.recordingStopped)
        feedback.handle(.finished(message: nil))
        #expect(outputs.played == [.start, .stop])
    }

    @Test func aMessageStaysForAWhileThenGoes() async throws {
        let feedback = makeFeedback(messageDuration: .milliseconds(50))
        feedback.handle(.finished(message: "Microphone access is off"))
        #expect(feedback.display == .message("Microphone access is off"))
        #expect(outputs.presented == [.message("Microphone access is off")])
        try await waitUntil { feedback.display == nil }
        #expect(feedback.display == nil)
        #expect(outputs.presented.count == 2)
        #expect(outputs.lastPresented == nil)
    }

    @Test func anOlderMessageDoesNotHideTheNextHold() async throws {
        let feedback = makeFeedback(messageDuration: .milliseconds(50))
        feedback.handle(.finished(message: "No speech was recognized"))
        feedback.handle(.listening)
        // A message shown later for as long goes after the first one would have.
        let probe = makeFeedback(FeedbackOutputs(), messageDuration: .milliseconds(50))
        probe.handle(.finished(message: "Microphone access is off"))
        try await waitUntil { probe.display == nil }
        #expect(probe.display == nil)
        #expect(feedback.display == .listening)
        #expect(outputs.lastPresented == .listening)
        feedback.handle(.finished(message: nil))
    }

    @Test func withTheIndicatorOffNothingShowsButTheSoundsPlay() {
        let feedback = makeFeedback(preferences: .init(showsIndicator: false, playsSounds: true))
        feedback.handle(.listening)
        feedback.handle(.transcribing)
        feedback.handle(.recordingStopped)
        feedback.handle(.finished(message: "No speech was recognized"))
        #expect(outputs.presented.allSatisfy { $0 == nil })
        #expect(outputs.played == [.start, .stop])
    }

    @Test func withTheSoundsOffNothingPlays() {
        let feedback = makeFeedback(preferences: .init(showsIndicator: true, playsSounds: false))
        feedback.handle(.listening)
        feedback.handle(.transcribing)
        feedback.handle(.recordingStopped)
        feedback.handle(.finished(message: nil))
        #expect(outputs.played.isEmpty)
        #expect(outputs.presented == [.listening, .transcribing, nil])
    }

    @Test func turningTheIndicatorOffHidesItAtOnceAndSavesTheChoice() {
        let feedback = makeFeedback()
        feedback.handle(.listening)
        feedback.showsIndicator = false
        #expect(outputs.presented == [.listening, nil])
        #expect(outputs.saved == [FeedbackPreference.Values(showsIndicator: false, playsSounds: true)])
        feedback.showsIndicator = true
        #expect(outputs.presented == [.listening, nil, .listening])
        feedback.playsSounds = false
        #expect(outputs.saved.last == FeedbackPreference.Values(showsIndicator: true, playsSounds: false))
    }

    @Test func theMeterFollowsTheMicrophoneOnlyWhileListening() async throws {
        let feedback = makeFeedback()
        // -20 dB, three quarters up the meter.
        outputs.level = 0.1
        feedback.handle(.listening)
        try await waitUntil { feedback.level > 0.7 }
        #expect(abs(feedback.level - 0.75) < 0.001)
        feedback.handle(.transcribing)
        #expect(feedback.level == 0)
        let readsWhenTranscribing = outputs.levelReads
        // A meter that keeps reading meanwhile shows that time passed.
        let probeOutputs = FeedbackOutputs()
        let probe = makeFeedback(probeOutputs)
        probe.handle(.listening)
        try await waitUntil { probeOutputs.levelReads >= 5 }
        #expect(probeOutputs.levelReads >= 5)
        #expect(outputs.levelReads == readsWhenTranscribing)
        #expect(feedback.level == 0)
        probe.handle(.finished(message: nil))
    }

    @Test func aHiddenIndicatorNeverReadsTheMicrophone() async throws {
        let feedback = makeFeedback(preferences: .init(showsIndicator: false, playsSounds: true))
        feedback.handle(.listening)
        let probeOutputs = FeedbackOutputs()
        let probe = makeFeedback(probeOutputs)
        probe.handle(.listening)
        try await waitUntil { probeOutputs.levelReads >= 5 }
        #expect(probeOutputs.levelReads >= 5)
        #expect(outputs.levelReads == 0)
        probe.handle(.finished(message: nil))
        feedback.handle(.finished(message: nil))
    }

    @Test func theMeterFallsSlowlyAfterAPeak() async throws {
        let feedback = makeFeedback()
        outputs.level = 1
        feedback.handle(.listening)
        try await waitUntil { feedback.level == 1 }
        outputs.level = 0
        try await waitUntil { feedback.level < 1 }
        // Lower after a reading, but not at the bottom at once.
        #expect(feedback.level > 0)
        try await waitUntil { feedback.level < 0.01 }
        #expect(feedback.level < 0.01)
    }

    @Test func meterLevelsRunFromMinus50ToMinus10Decibels() {
        #expect(RecordingFeedback.meterLevel(peak: 0) == 0)
        #expect(RecordingFeedback.meterLevel(peak: .nan) == 0)
        #expect(RecordingFeedback.meterLevel(peak: 0.001) == 0)
        #expect(abs(RecordingFeedback.meterLevel(peak: 0.01) - 0.25) < 0.001)
        #expect(RecordingFeedback.meterLevel(peak: 0.5) == 1)
        #expect(RecordingFeedback.meterLevel(peak: 1) == 1)
    }

    @Test func bothPreferencesAreOnUntilTurnedOff() throws {
        let suite = "io.github.db-ol.OrraTests.feedback-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(FeedbackPreference.load(from: defaults) == FeedbackPreference.Values(showsIndicator: true, playsSounds: true))
        FeedbackPreference.save(FeedbackPreference.Values(showsIndicator: false, playsSounds: true), to: defaults)
        #expect(FeedbackPreference.load(from: defaults) == FeedbackPreference.Values(showsIndicator: false, playsSounds: true))
    }

    /// The panel the app shows, made but never ordered front, so no window appears.
    @Test func theIndicatorPanelNeverTakesTheFocusOrTheClicks() throws {
        let feedback = makeFeedback()
        let indicator = RecordingIndicatorPanel()
        indicator.feedback = feedback
        let panel = try #require(indicator.makePanel())
        #expect(panel is NonactivatingPanel)
        #expect(panel.canBecomeKey == false)
        #expect(panel.canBecomeMain == false)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.ignoresMouseEvents)
        #expect(panel.hidesOnDeactivate == false)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(panel.isVisible == false)
    }
}

struct LevelMeterTests {
    @Test func keepsThePeakOfTheLatestBuffer() {
        let meter = LevelMeter()
        #expect(meter.peak == 0)
        let loud: [Float] = [0.1, -0.5, 0.25]
        loud.withUnsafeBufferPointer { meter.record($0.baseAddress!, count: $0.count) }
        #expect(meter.peak == 0.5)
        let quiet: [Float] = [0.01, -0.02]
        quiet.withUnsafeBufferPointer { meter.record($0.baseAddress!, count: $0.count) }
        #expect(meter.peak == 0.02)
        meter.reset()
        #expect(meter.peak == 0)
    }

    @Test func clampsOverloadsAndIgnoresAnEmptyBuffer() {
        let meter = LevelMeter()
        let clipped: [Float] = [1.5, -2]
        clipped.withUnsafeBufferPointer { meter.record($0.baseAddress!, count: $0.count) }
        #expect(meter.peak == 1)
        let empty: [Float] = [0]
        empty.withUnsafeBufferPointer { meter.record($0.baseAddress!, count: 0) }
        #expect(meter.peak == 1)
    }
}
