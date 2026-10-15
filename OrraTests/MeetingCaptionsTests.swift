import Foundation
import Testing
@testable import Orra

@MainActor
struct MeetingCaptionsTests {
    @MainActor
    private final class FakeSource {
        var fails: SystemAudioProblem?
        var deliver: (@Sendable ([Float]) -> Void)?
        private(set) var starts = 0
        private(set) var stops = 0

        var source: SystemAudioSource {
            SystemAudioSource(start: { [self] deliver in
                starts += 1
                if let fails { throw fails }
                self.deliver = deliver
            }, stop: { [self] in
                stops += 1
                deliver = nil
            })
        }
    }

    private func makeCaptions(_ models: FakeCaptionModels, source: FakeSource, events: Box) -> MeetingCaptions {
        let captions = MeetingCaptions(
            source: source.source,
            engines: models.engines(),
            started: { events.items.append("started") },
            stopped: { events.items.append("stopped") },
            silenceHint: 2
        )
        captions.showWindow = { events.items.append("show") }
        captions.closeWindow = { events.items.append("close") }
        return captions
    }

    @MainActor
    private final class Box {
        var items: [String] = []
    }

    @Test func turningOnStartsTheCaptureAndShowsTheWindow() async throws {
        let source = FakeSource()
        let events = Box()
        let captions = makeCaptions(FakeCaptionModels(["Hello everyone."]), source: source, events: events)
        captions.setOn(true)
        #expect(captions.isOn)
        #expect(captions.capture == .listening)
        #expect(source.starts == 1)
        #expect(events.items == ["started", "show"])
        captions.receive(FakeCaptionModels.audio(sentences: 1), run: captions.currentRun)
        try await eventually { captions.store.sentences.first?.translatedText == "大家好。" }
    }

    @Test func turningOffDropsEveryCaptionAndClosesTheWindow() async throws {
        let source = FakeSource()
        let events = Box()
        let captions = makeCaptions(FakeCaptionModels(["Hello.", "Again."]), source: source, events: events)
        captions.setOn(true)
        let run = captions.currentRun
        captions.receive(FakeCaptionModels.audio(sentences: 1), run: run)
        try await eventually { captions.store.sentences.count == 1 }
        captions.setOn(false)
        #expect(captions.store.sentences.isEmpty)
        #expect(source.stops == 1)
        #expect(captions.capture == .off)
        #expect(events.items == ["started", "show", "stopped", "close"])
        // Samples still on their way from the capture are ignored.
        captions.receive(FakeCaptionModels.audio(sentences: 1), run: run)
        try await Task.sleep(for: .milliseconds(30))
        #expect(captions.store.sentences.isEmpty)
    }

    @Test func aRefusedCaptureSaysSoInTheWindow() {
        let source = FakeSource()
        source.fails = .notConfigured
        let events = Box()
        let captions = makeCaptions(FakeCaptionModels([]), source: source, events: events)
        captions.setOn(true)
        #expect(captions.isOn)
        #expect(captions.capture == .unavailable(.notConfigured))
        #expect(events.items == ["started", "show"])
    }

    @Test func onlyZerosSuggestThePermission() {
        let source = FakeSource()
        let captions = makeCaptions(FakeCaptionModels([]), source: source, events: Box())
        captions.setOn(true)
        captions.receive(CaptionAudio.silence(1.5))
        #expect(!captions.hearsOnlySilence)
        captions.receive(CaptionAudio.silence(1))
        #expect(captions.hearsOnlySilence)
        captions.receive(CaptionAudio.tone(0.1))
        #expect(!captions.hearsOnlySilence)
        captions.receive(CaptionAudio.silence(5))
        #expect(!captions.hearsOnlySilence)
    }

    @Test func theDisplayModeIsSaved() {
        var saved: [CaptionDisplayMode] = []
        let captions = MeetingCaptions(source: FakeSource().source, engines: FakeCaptionModels([]).engines(), saveDisplayMode: { saved.append($0) })
        #expect(captions.displayMode == .translationOnly)
        captions.setDisplayMode(.originalAndTranslation)
        captions.setDisplayMode(.originalAndTranslation)
        #expect(saved == [.originalAndTranslation])
    }

    @Test func theDisplayModeIsReadBack() throws {
        let defaults = try #require(UserDefaults(suiteName: "orra-caption-test-\(UUID().uuidString)"))
        #expect(CaptionDisplayMode.load(from: defaults) == .translationOnly)
        CaptionDisplayMode.originalAndTranslation.save(to: defaults)
        #expect(CaptionDisplayMode.load(from: defaults) == .originalAndTranslation)
    }
}

struct CaptionDisplayTests {
    private func sentence(_ translation: CaptionSentence.Translation) -> CaptionSentence {
        CaptionSentence(id: 1, start: 0, end: 1, original: "我们开始吧。", translation: translation)
    }

    @Test func translationOnlyShowsTheOriginalUntilTheTranslationReplacesIt() {
        let mode = CaptionDisplayMode.translationOnly
        #expect(mode.lines(for: sentence(.pending)) == [.init(text: "我们开始吧。", style: .secondary)])
        #expect(mode.lines(for: sentence(.done("Let's begin."))) == [.init(text: "Let's begin.", style: .main)])
        #expect(mode.lines(for: sentence(.none)) == [.init(text: "我们开始吧。", style: .main)])
    }

    @Test func bothShowTheOriginalAndTheTranslationJoinsIt() {
        let mode = CaptionDisplayMode.originalAndTranslation
        #expect(mode.lines(for: sentence(.pending)) == [.init(text: "我们开始吧。", style: .secondary)])
        #expect(mode.lines(for: sentence(.done("Let's begin."))) == [.init(text: "我们开始吧。", style: .secondary), .init(text: "Let's begin.", style: .main)])
        #expect(mode.lines(for: sentence(.none)) == [.init(text: "我们开始吧。", style: .main)])
    }

    @Test @MainActor func theStoreKeepsTheLatestSentencesOnly() {
        let store = CaptionStore(limit: 3)
        for id in 1...5 {
            store.apply(CaptionSentence(id: id, start: Double(id), end: Double(id) + 1, original: "\(id)", translation: .pending))
        }
        #expect(store.sentences.map(\.id) == [3, 4, 5])
        store.apply(CaptionSentence(id: 4, start: 4, end: 5, original: "4", translation: .done("four")))
        #expect(store.sentences.map(\.id) == [3, 4, 5])
        #expect(store.sentences[1].translatedText == "four")
        store.clear()
        #expect(store.sentences.isEmpty)
    }
}

/// The window follows the newest sentence until the user scrolls up, and again once they
/// are back at the bottom.
struct CaptionFollowTests {
    @Test func newSentencesDoNotStopTheFollowing() {
        var follow = CaptionFollow()
        follow.update(offset: 0, contentHeight: 100, viewportHeight: 200)
        // Content grows below the view, the offset stays: not a scroll by the user.
        follow.update(offset: 0, contentHeight: 400, viewportHeight: 200)
        #expect(follow.isFollowing)
        // The window scrolls to the bottom.
        follow.update(offset: 200, contentHeight: 400, viewportHeight: 200)
        #expect(follow.isFollowing)
    }

    @Test func scrollingUpStopsItAndBackToTheBottomResumesIt() {
        var follow = CaptionFollow()
        follow.update(offset: 800, contentHeight: 1_000, viewportHeight: 200)
        follow.update(offset: 500, contentHeight: 1_000, viewportHeight: 200)
        #expect(!follow.isFollowing)
        // New sentences while the user reads: the view stays where it is.
        follow.update(offset: 500, contentHeight: 1_300, viewportHeight: 200)
        #expect(!follow.isFollowing)
        // Scrolling down, but not all the way.
        follow.update(offset: 1_000, contentHeight: 1_300, viewportHeight: 200)
        #expect(!follow.isFollowing)
        // Close enough to the bottom.
        follow.update(offset: 1_090, contentHeight: 1_300, viewportHeight: 200)
        #expect(follow.isFollowing)
    }

    @Test func resizingTheWindowKeepsTheChoice() {
        var follow = CaptionFollow()
        follow.update(offset: 800, contentHeight: 1_000, viewportHeight: 200)
        follow.update(offset: 800, contentHeight: 1_000, viewportHeight: 300)
        #expect(follow.isFollowing)
        follow.update(offset: 300, contentHeight: 1_000, viewportHeight: 300)
        #expect(!follow.isFollowing)
        follow.update(offset: 300, contentHeight: 1_000, viewportHeight: 250)
        #expect(!follow.isFollowing)
    }

    @Test func jumpingToTheLatestFollowsAgain() {
        var follow = CaptionFollow()
        follow.update(offset: 800, contentHeight: 1_000, viewportHeight: 200)
        follow.update(offset: 100, contentHeight: 1_000, viewportHeight: 200)
        #expect(!follow.isFollowing)
        follow.jumpToLatest()
        #expect(follow.isFollowing)
    }
}
