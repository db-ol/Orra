import AppKit
import Foundation
import SwiftUI
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
        preferences: FeedbackPreference.Values = .init(showsIdleBar: false),
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
        let feedback = makeFeedback(preferences: .init(showsIndicator: false, playsSounds: true, showsIdleBar: false))
        feedback.handle(.listening)
        feedback.handle(.transcribing)
        feedback.handle(.recordingStopped)
        feedback.handle(.finished(message: "No speech was recognized"))
        #expect(outputs.presented.allSatisfy { $0 == nil })
        #expect(outputs.played == [.start, .stop])
    }

    @Test func withTheSoundsOffNothingPlays() {
        let feedback = makeFeedback(preferences: .init(showsIndicator: true, playsSounds: false, showsIdleBar: false))
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
        #expect(outputs.saved == [FeedbackPreference.Values(showsIndicator: false, playsSounds: true, showsIdleBar: false)])
        feedback.showsIndicator = true
        #expect(outputs.presented == [.listening, nil, .listening])
        feedback.playsSounds = false
        #expect(outputs.saved.last == FeedbackPreference.Values(showsIndicator: true, playsSounds: false, showsIdleBar: false))
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
        let feedback = makeFeedback(preferences: .init(showsIndicator: false, playsSounds: true, showsIdleBar: false))
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

    @Test func thePreferencesAreOnUntilTurnedOff() throws {
        let suite = "io.github.db-ol.OrraTests.feedback-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(FeedbackPreference.load(from: defaults) == FeedbackPreference.Values(showsIndicator: true, playsSounds: true, showsIdleBar: true))
        FeedbackPreference.save(FeedbackPreference.Values(showsIndicator: false, playsSounds: true, showsIdleBar: false), to: defaults)
        #expect(FeedbackPreference.load(from: defaults) == FeedbackPreference.Values(showsIndicator: false, playsSounds: true, showsIdleBar: false))
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

    @Test func theIdleBarShowsBetweenDictations() {
        let feedback = makeFeedback(preferences: .init())
        feedback.canDictate = true
        feedback.handle(.listening)
        feedback.handle(.transcribing)
        feedback.handle(.finished(message: nil))
        #expect(outputs.presented == [.idle, .listening, .transcribing, .idle])
        #expect(feedback.display == nil)
    }

    @Test func turningTheIdleBarOffHidesItAndIsSaved() {
        let feedback = makeFeedback(preferences: .init())
        feedback.canDictate = true
        feedback.showsIdleBar = false
        #expect(outputs.presented == [.idle, nil])
        #expect(outputs.saved.last == FeedbackPreference.Values(showsIndicator: true, playsSounds: true, showsIdleBar: false))
    }

    @Test func withTheIndicatorOffTheIdleBarStays() {
        let feedback = makeFeedback(preferences: .init(showsIndicator: false))
        feedback.canDictate = true
        feedback.handle(.listening)
        #expect(outputs.presented == [.idle, .idle])
        #expect(feedback.presented == .idle)
    }

    /// The opacity of the indicator view's pixel at the bottom center, where the bar is.
    private func opacityAtTheBar(_ feedback: RecordingFeedback) throws -> CGFloat {
        let view = NSHostingView(rootView: RecordingIndicatorView(feedback: feedback))
        view.frame = NSRect(origin: .zero, size: RecordingIndicatorView.panelSize)
        view.layoutSubtreeIfNeeded()
        let image = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        let scale = CGFloat(image.pixelsWide) / view.bounds.width
        // Image rows count from the top. The bar's middle is 3 points above its bottom.
        let fromBottom = RecordingIndicatorView.bottomPadding + RecordingIndicatorView.idleBarSize.height / 2
        let color = try #require(image.colorAt(x: image.pixelsWide / 2, y: image.pixelsHigh - Int(fromBottom * scale)))
        return color.alphaComponent
    }

    @Test func theViewDrawsTheIdleBarOnlyWhenItIsPresented() throws {
        let feedback = makeFeedback(preferences: .init())
        #expect(try opacityAtTheBar(feedback) == 0)
        feedback.canDictate = true
        #expect(try opacityAtTheBar(feedback) > 0.3)
    }

    @Test func theIdleBarWaitsUntilOrraCanDictate() {
        let feedback = makeFeedback(preferences: .init())
        #expect(feedback.presented == nil)
        feedback.canDictate = true
        #expect(feedback.presented == .idle)
        feedback.canDictate = false
        #expect(outputs.presented == [.idle, nil])
    }

    /// The colors the indicator view draws near the bottom of the panel, where the
    /// indicator sits, in sRGB.
    private func colorsNearTheBottom(_ feedback: RecordingFeedback) throws -> [NSColor] {
        let view = NSHostingView(rootView: RecordingIndicatorView(feedback: feedback))
        view.frame = NSRect(origin: .zero, size: RecordingIndicatorView.panelSize)
        view.layoutSubtreeIfNeeded()
        let image = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        let scale = CGFloat(image.pixelsWide) / view.bounds.width
        let rows = Int(60 * scale)
        var colors: [NSColor] = []
        for y in stride(from: image.pixelsHigh - rows, to: image.pixelsHigh, by: 1) {
            for x in stride(from: image.pixelsWide / 2 - Int(40 * scale), to: image.pixelsWide / 2 + Int(40 * scale), by: 1) {
                if let color = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                    colors.append(color)
                }
            }
        }
        return colors
    }

    @Test(arguments: [DictationCue.listening, .transcribing, .finished(message: "No speech was recognized")])
    func theIndicatorDrawsWhiteOnDarkWithoutColor(_ cue: DictationCue) throws {
        let feedback = makeFeedback()
        if cue == .transcribing {
            feedback.handle(.listening)
        }
        feedback.handle(cue)
        let colors = try colorsNearTheBottom(feedback)
        let visible = colors.filter { $0.alphaComponent > 0.5 }
        // Gray only: no green microphone and no other color.
        for color in visible {
            #expect(abs(color.redComponent - color.greenComponent) < 0.08)
            #expect(abs(color.greenComponent - color.blueComponent) < 0.08)
        }
        // A dark capsule or box, and white bars or text on it.
        #expect(visible.contains { $0.redComponent < 0.2 })
        #expect(visible.contains { $0.redComponent > 0.9 })
    }

    @Test func theIdleBarAreaSurroundsTheBar() {
        let area = RecordingIndicatorPanel.idleBarArea(inPanelAt: NSRect(x: 100, y: 50, width: 520, height: 150))
        #expect(area.contains(NSPoint(x: 360, y: 50 + RecordingIndicatorView.bottomPadding + 3)))
        #expect(!area.contains(NSPoint(x: 360, y: 150)))
        #expect(!area.contains(NSPoint(x: 200, y: 69)))
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

struct IndicatorBarsTests {
    @Test func silenceLeavesEveryBarAtTheMinimum() {
        let heights = IndicatorBars.heights(level: 0)
        #expect(heights.count == IndicatorBars.count)
        #expect(heights.allSatisfy { $0 == IndicatorBars.minimumHeight })
    }

    @Test func aFullLevelRaisesTheMiddleBarToTheMaximum() {
        let heights = IndicatorBars.heights(level: 1)
        #expect(heights[IndicatorBars.count / 2] == IndicatorBars.maximumHeight)
        #expect(heights.allSatisfy { $0 <= IndicatorBars.maximumHeight })
        #expect(heights.first! < heights[IndicatorBars.count / 2])
        #expect(heights.first! == heights.last!)
    }

    @Test func louderIsTallerAndTheLevelIsClamped() {
        let quiet = IndicatorBars.heights(level: 0.3)
        let loud = IndicatorBars.heights(level: 0.7)
        #expect(zip(quiet, loud).allSatisfy { $0 < $1 })
        #expect(IndicatorBars.heights(level: 2) == IndicatorBars.heights(level: 1))
        #expect(IndicatorBars.heights(level: -1) == IndicatorBars.heights(level: 0))
    }

    @Test func theWaveStaysLowAndMoves() {
        let low = IndicatorBars.minimumHeight
        let high = IndicatorBars.minimumHeight + IndicatorBars.waveHeight
        for phase in stride(from: 0.0, to: 2.0, by: 0.05) {
            let heights = IndicatorBars.waveHeights(phase: phase)
            #expect(heights.count == IndicatorBars.count)
            #expect(heights.allSatisfy { $0 >= low - 0.001 && $0 <= high + 0.001 })
        }
        // Well below a voice, so the bars clearly settle.
        #expect(high < IndicatorBars.maximumHeight / 2)
        #expect(IndicatorBars.waveHeights(phase: 0) != IndicatorBars.waveHeights(phase: 0.25))
        let resting = IndicatorBars.restingWaveHeights
        #expect(resting != IndicatorBars.heights(level: 0))
        #expect(Set(resting).count > 1)
        #expect(resting.allSatisfy { $0 >= low - 0.001 && $0 <= high + 0.001 })
        let a = IndicatorBars.waveHeights(phase: 0.3)
        let b = IndicatorBars.waveHeights(phase: 1.3)
        #expect(zip(a, b).allSatisfy { abs($0 - $1) < 0.001 })
    }
}

@MainActor
struct MenuBarIconTests {
    private func symbol(
        modelSymbol: String? = nil,
        isHotkeyActive: Bool = true,
        dictation: PushToTalkStateMachine.State = .idle,
        showsIndicator: Bool = true,
        modelState: PushToTalkController.ModelState = .ready,
        microphoneAccess: MicrophoneAccess = .authorized,
        hasProblem: Bool = false
    ) -> String {
        MenuBarIcon.symbolName(
            modelSymbol: modelSymbol,
            isHotkeyActive: isHotkeyActive,
            dictation: dictation,
            showsIndicator: showsIndicator,
            modelState: modelState,
            microphoneAccess: microphoneAccess,
            hasProblem: hasProblem
        )
    }

    @Test func readyIsThePlainMicrophone() {
        #expect(symbol() == "mic")
    }

    @Test func withTheIndicatorOnTheIconStaysTheSameDuringADictation() {
        #expect(symbol(dictation: .listening) == "mic")
        #expect(symbol(dictation: .processing) == "mic")
        #expect(symbol(dictation: .processing, hasProblem: true) == "exclamationmark.triangle")
    }

    @Test func withTheIndicatorOffTheIconShowsListeningAndTranscribing() {
        #expect(symbol(dictation: .listening, showsIndicator: false) == "mic.fill")
        #expect(symbol(dictation: .processing, showsIndicator: false) == "waveform")
        #expect(symbol(dictation: .idle, showsIndicator: false) == "mic")
        #expect(symbol(dictation: .idle, showsIndicator: false, hasProblem: true) == "exclamationmark.triangle")
        // The download and the missing hotkey still come first.
        #expect(symbol(modelSymbol: "arrow.down.circle", dictation: .processing, showsIndicator: false) == "arrow.down.circle")
        #expect(symbol(isHotkeyActive: false, dictation: .listening, showsIndicator: false) == "mic.slash")
    }

    @Test func theModelDownloadComesFirst() {
        #expect(symbol(modelSymbol: "arrow.down.circle", isHotkeyActive: false) == "arrow.down.circle")
    }

    @Test func otherStatesKeepTheirSymbols() {
        #expect(symbol(isHotkeyActive: false) == "mic.slash")
        #expect(symbol(modelState: .loading) == "hourglass")
        #expect(symbol(modelState: .notLoaded) == "hourglass")
        #expect(symbol(modelState: .unavailable("x")) == "exclamationmark.triangle")
        #expect(symbol(microphoneAccess: .denied) == "exclamationmark.triangle")
        #expect(symbol(microphoneAccess: .notConfigured) == "exclamationmark.triangle")
        #expect(symbol(hasProblem: true) == "exclamationmark.triangle")
    }
}
