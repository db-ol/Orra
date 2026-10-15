import Foundation
import Observation
import os

/// The caption sentences the window shows, the newest last. In memory only, and at most
/// `limit`, so a long meeting does not grow without end.
@Observable
final class CaptionStore {
    /// About two hours of a busy call.
    static let limit = 500

    private(set) var sentences: [CaptionSentence] = []
    let limit: Int

    init(limit: Int = CaptionStore.limit) {
        self.limit = limit
    }

    /// A new sentence goes at the end, a known one is replaced where it is.
    func apply(_ sentence: CaptionSentence) {
        if let index = sentences.lastIndex(where: { $0.id == sentence.id }) {
            sentences[index] = sentence
            return
        }
        sentences.append(sentence)
        if sentences.count > limit {
            sentences.removeFirst(sentences.count - limit)
        }
    }

    func clear() {
        sentences = []
    }
}

/// What the caption window shows of each sentence. Saved, so the window opens the way the
/// user left it.
nonisolated enum CaptionDisplayMode: String, CaseIterable, Sendable {
    case translationOnly
    case originalAndTranslation

    static let defaultsKey = "captionDisplayMode"

    static func load(from defaults: UserDefaults = .standard) -> CaptionDisplayMode {
        defaults.string(forKey: defaultsKey).flatMap(CaptionDisplayMode.init(rawValue:)) ?? .translationOnly
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }

    /// One line of a sentence in the window.
    nonisolated struct Line: Equatable, Sendable {
        nonisolated enum Style: Equatable, Sendable {
            /// The line to read: the translation, or the original while there is none.
            case main
            /// The original above its translation, or the original while it is translated.
            case secondary
        }

        let text: String
        let style: Style
    }

    /// The lines of a sentence in this mode. While the translation is pending, the
    /// original shows on its own in the secondary style, and the translation replaces or
    /// joins it once it is there. Without a translation the original is the main line.
    func lines(for sentence: CaptionSentence) -> [Line] {
        switch (self, sentence.translation) {
        case (_, .none):
            [Line(text: sentence.original, style: .main)]
        case (_, .pending):
            [Line(text: sentence.original, style: .secondary)]
        case (.translationOnly, .done(let translation)):
            [Line(text: translation, style: .main)]
        case (.originalAndTranslation, .done(let translation)):
            [Line(text: sentence.original, style: .secondary), Line(text: translation, style: .main)]
        }
    }
}

/// Whether the caption list follows its bottom as sentences come in. Pure state, fed with
/// the scroll geometry, so the tests drive it without a window.
///
/// It follows until the user scrolls up, and follows again once they scroll back to the
/// bottom. Content that grows or a window that changes size is not a scroll by the user,
/// so it leaves the choice alone, which is how a new sentence below the view does not
/// stop the following, and how one that comes in while the user reads does not jump the
/// view.
nonisolated struct CaptionFollow: Equatable, Sendable {
    /// How close to the bottom counts as at the bottom, in points.
    static let tolerance: Double = 24

    private(set) var isFollowing = true
    private var offset: Double?

    /// The scroll view's geometry changed: its offset from the top, the height of the
    /// content and of the visible part.
    mutating func update(offset newOffset: Double, contentHeight: Double, viewportHeight: Double) {
        defer { offset = newOffset }
        guard let offset, abs(newOffset - offset) > 0.5 else { return }
        let distance = contentHeight - viewportHeight - newOffset
        isFollowing = distance <= Self.tolerance
    }

    /// The user asked to go to the latest sentence.
    mutating func jumpToLatest() {
        isFollowing = true
    }
}

/// Meeting captions: the sound the Mac plays, cut into sentences, transcribed and
/// translated as they come, shown in a floating window. Off at every launch, turned on
/// from the menu.
///
/// Turning it off stops the capture, drops every sentence and closes the window. Nothing
/// is logged or saved but counts and timings.
@Observable
final class MeetingCaptions {
    nonisolated enum CaptureState: Equatable, Sendable {
        case off
        case listening
        case unavailable(SystemAudioProblem)
    }

    private(set) var isOn = false
    private(set) var capture: CaptureState = .off
    /// True when every sample so far was exactly zero for `silenceHint`, which is what a
    /// refused permission looks like. Cleared by the first sound.
    private(set) var hearsOnlySilence = false
    /// True after a sentence was dropped since the speech model was not loaded.
    private(set) var speechModelMissing = false
    private(set) var displayMode: CaptionDisplayMode
    let store: CaptionStore
    /// The window's scroll state, reset each time captions start.
    var follow = CaptionFollow()

    /// Shows and closes the caption window. AppDelegate sets them.
    @ObservationIgnored var showWindow: () -> Void = {}
    @ObservationIgnored var closeWindow: () -> Void = {}

    @ObservationIgnored private let source: SystemAudioSource
    @ObservationIgnored private let engines: CaptionEngines
    @ObservationIgnored private let started: () -> Void
    @ObservationIgnored private let stopped: () -> Void
    @ObservationIgnored private let saveDisplayMode: (CaptionDisplayMode) -> Void
    @ObservationIgnored private let silenceHint: Double
    @ObservationIgnored private var pipeline: CaptionPipeline?
    /// Counts the starts, so samples of an earlier run are ignored.
    @ObservationIgnored private var run = 0
    @ObservationIgnored private var heardSeconds = 0.0
    @ObservationIgnored private var heardSound = false

    /// - Parameters:
    ///   - source: The capture of the sound the Mac plays. Tests pass a fake.
    ///   - engines: The models, see CaptionEngines.live.
    ///   - started: Called when captions start, so the cleanup model loads, see
    ///     TextCleanup.captionsStarted.
    ///   - stopped: Called when they stop.
    ///   - silenceHint: Seconds of only zeros before the window suggests the permission.
    init(
        source: SystemAudioSource,
        engines: CaptionEngines,
        started: @escaping () -> Void = {},
        stopped: @escaping () -> Void = {},
        displayMode: CaptionDisplayMode = .translationOnly,
        saveDisplayMode: @escaping (CaptionDisplayMode) -> Void = { _ in },
        store: CaptionStore = CaptionStore(),
        silenceHint: Double = 8
    ) {
        self.source = source
        self.engines = engines
        self.started = started
        self.stopped = stopped
        self.displayMode = displayMode
        self.saveDisplayMode = saveDisplayMode
        self.store = store
        self.silenceHint = silenceHint
    }

    func setOn(_ on: Bool) {
        guard on != isOn else { return }
        on ? start() : stop()
    }

    func setDisplayMode(_ mode: CaptionDisplayMode) {
        guard mode != displayMode else { return }
        displayMode = mode
        saveDisplayMode(mode)
    }

    private func start() {
        isOn = true
        run += 1
        follow = CaptionFollow()
        hearsOnlySilence = false
        speechModelMissing = false
        heardSeconds = 0
        heardSound = false
        let pipeline = CaptionPipeline(engines: engines, speechNotReady: { [weak self] in
            self?.speechModelMissing = true
        }, report: { [weak self] sentence in
            self?.speechModelMissing = false
            self?.store.apply(sentence)
        })
        self.pipeline = pipeline
        started()
        showWindow()
        let current = run
        do {
            try source.start { [weak self] samples in
                DispatchQueue.main.async {
                    self?.receive(samples, run: current)
                }
            }
            capture = .listening
            Logger.captions.notice("Meeting captions started")
        } catch let problem as SystemAudioProblem {
            capture = .unavailable(problem)
        } catch {
            capture = .unavailable(.failed(step: "start", status: 0))
        }
    }

    private func stop() {
        isOn = false
        run += 1
        source.stop()
        pipeline?.stop()
        pipeline = nil
        store.clear()
        capture = .off
        hearsOnlySilence = false
        speechModelMissing = false
        stopped()
        closeWindow()
        Logger.captions.notice("Meeting captions stopped")
    }

    /// Samples from the capture, on the main actor. Internal for tests.
    func receive(_ samples: [Float], run: Int? = nil) {
        guard isOn, run == nil || run == self.run, let pipeline else { return }
        if !heardSound {
            if samples.contains(where: { $0 != 0 }) {
                heardSound = true
                hearsOnlySilence = false
            } else {
                heardSeconds += Double(samples.count) / Double(RecordingLimits.sampleRate)
                hearsOnlySilence = heardSeconds >= silenceHint
            }
        }
        pipeline.feed(samples)
    }

    /// The run of the latest start, for tests that feed samples like the capture does.
    var currentRun: Int {
        run
    }
}
