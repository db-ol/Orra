import AppKit
import Foundation
import Observation
import os

/// The caption sentences of the meeting, the newest last, and the last meeting's. In
/// memory only, until Orra quits, so they can still be copied after captions stop. At
/// most `limit` sentences, so a long meeting does not grow without end, of which the
/// window draws the last `shownLimit`.
@Observable
final class CaptionStore {
    /// About 40 hours of a busy call, a few MB with translations.
    static let limit = 10_000
    /// About two hours of a busy call. The window draws no more, so a long meeting does
    /// not make each new sentence redraw thousands.
    static let shownLimit = 500

    private(set) var sentences: [CaptionSentence] = []
    /// The final sentences of the last meeting, moved here when captions start again, so
    /// a stray start does not lose a meeting before it was copied.
    private(set) var previous = CaptionTranscript([])
    /// Whether a sentence is final, so there is something to copy. Kept here, so the menu
    /// does not follow every caption line.
    private(set) var hasFinalSentences = false
    /// Whether a sentence has its translation, so Copy Translation copies more than the
    /// originals.
    private(set) var hasTranslation = false
    /// True once the oldest sentences were dropped to stay within `limit`, until captions
    /// start again.
    private(set) var droppedOldest = false
    /// Whether the captions reported a final sentence since they started. A line that only
    /// became final when they stopped does not count, so a short stray start does not
    /// replace the previous meeting.
    private var reportedFinal = false
    let limit: Int

    init(limit: Int = CaptionStore.limit) {
        self.limit = limit
    }

    /// The sentences the window draws, the latest `shownLimit`. An array of its own, so
    /// the window does not hold on to the store's array, and a new caption line changes
    /// it in place instead of copying up to `limit` sentences.
    var shown: [CaptionSentence] {
        Array(sentences.suffix(Self.shownLimit))
    }

    /// The final sentences, for a copy.
    var transcript: CaptionTranscript {
        CaptionTranscript(sentences)
    }

    /// A new sentence goes at the end, a known one is replaced where it is.
    func apply(_ sentence: CaptionSentence) {
        if let index = sentences.lastIndex(where: { $0.id == sentence.id }) {
            sentences[index] = sentence
        } else {
            sentences.append(sentence)
            if sentences.count > limit {
                sentences.removeFirst(sentences.count - limit)
                if !droppedOldest { droppedOldest = true }
            }
        }
        if !sentence.isInterim { reportedFinal = true }
        noteContents()
    }

    /// Removes a sentence, such as an interim line whose sentence got no final text.
    func remove(id: Int) {
        sentences.removeAll { $0.id == id }
        noteContents()
    }

    /// Captions stopped, so nothing reports anymore. The line still being heard keeps its
    /// last text as a final sentence without translation, so the last words are not
    /// lost, and a pending translation becomes none, so it never waits forever.
    func settle() {
        for index in sentences.indices where sentences[index].isInterim || sentences[index].translation == .pending {
            sentences[index].isInterim = false
            sentences[index].translation = .none
        }
        noteContents()
    }

    /// Captions start again: the final sentences become the previous transcript and the
    /// window starts empty, so a meeting never shows in the next one's window. Unless the
    /// captions reported a final sentence, the previous transcript stays as it is. A line
    /// that was still being heard at the stop alone is not a meeting to keep.
    func startOver() {
        if reportedFinal {
            let transcript = transcript
            if !transcript.isEmpty {
                previous = transcript
            }
        }
        sentences = []
        droppedOldest = false
        reportedFinal = false
        noteContents()
    }

    /// Sets the flags only when they change, since every set notifies the views.
    private func noteContents() {
        let final = sentences.contains { !$0.isInterim }
        if final != hasFinalSentences { hasFinalSentences = final }
        let translated = sentences.contains { $0.translatedText != nil }
        if translated != hasTranslation { hasTranslation = translated }
    }
}

/// What the caption window shows of each sentence. Saved, so the window opens the way the
/// user left it. In the order of the picker, from what was said to its translation.
nonisolated enum CaptionDisplayMode: String, CaseIterable, Sendable {
    /// What was said, without translating it. The local model is not loaded for it.
    case originalOnly
    case translationOnly
    case originalAndTranslation

    static let defaultsKey = "captionDisplayMode"

    /// The saved mode. Translation only while none is saved, so a user who never chose
    /// keeps what they had. A build without Original only reads it as that too.
    static func load(from defaults: UserDefaults = .standard) -> CaptionDisplayMode {
        defaults.string(forKey: defaultsKey).flatMap(CaptionDisplayMode.init(rawValue:)) ?? .translationOnly
    }

    /// Whether captions translate in this mode.
    var translates: Bool {
        self != .originalOnly
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

    /// The lines of a sentence in this mode. While the sentence is still being heard and
    /// while its translation is pending, the original shows on its own in the secondary
    /// style, and the translation replaces or joins it once it is there. Without a
    /// translation the original is the main line. Original only shows a final sentence
    /// as its original, whatever its translation.
    func lines(for sentence: CaptionSentence) -> [Line] {
        if sentence.isInterim {
            return [Line(text: sentence.original, style: .secondary)]
        }
        return switch (self, sentence.translation) {
        case (.originalOnly, _), (_, .none):
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

    private struct Geometry: Equatable {
        let offset: Double
        let contentHeight: Double
        let viewportHeight: Double
    }

    private(set) var isFollowing = true
    private var last: Geometry?
    /// True from asking the view to go to the bottom until it is there, so the steps of
    /// that move do not read as the user scrolling.
    private var movingToBottom = false

    /// The scroll view's geometry changed: its offset from the top, the height of the
    /// content and of the visible part. `userScrolls` is true while the scroll view says
    /// the user is scrolling. Returns true when the view should move to the bottom, which
    /// is when it follows and new or longer sentences, or a smaller window, left the
    /// bottom out of view.
    @discardableResult
    mutating func update(offset: Double, contentHeight: Double, viewportHeight: Double, userScrolls: Bool = false) -> Bool {
        let geometry = Geometry(offset: offset, contentHeight: contentHeight, viewportHeight: viewportHeight)
        defer { last = geometry }
        let distance = contentHeight - viewportHeight - offset
        let atBottom = distance <= Self.tolerance
        if atBottom { movingToBottom = false }
        // Only the offset moved: a scroll, by the user unless it is our own move down.
        let onlyScrolled = last.map {
            abs(offset - $0.offset) > 0.5 && abs(contentHeight - $0.contentHeight) < 0.5
                && abs(viewportHeight - $0.viewportHeight) < 0.5
        } ?? false
        if userScrolls || (onlyScrolled && !movingToBottom) {
            movingToBottom = false
            isFollowing = atBottom
            return false
        }
        // A step of our own move down: it is under way already.
        if onlyScrolled { return false }
        guard isFollowing, distance > 0.5 else { return false }
        movingToBottom = true
        return true
    }

    /// The user asked to go to the latest sentence.
    mutating func jumpToLatest() {
        isFollowing = true
        movingToBottom = true
    }
}

/// Meeting captions: the sound the Mac plays, cut into sentences, transcribed and
/// translated as they come, shown in a floating window. Off at every launch, turned on
/// from the menu.
///
/// Turning it off stops the capture and closes the window. The sentences stay in memory
/// until Orra quits, so they can still be copied, and the next start keeps them as the
/// previous transcript. Nothing is logged or saved but counts and timings.
@Observable
final class MeetingCaptions {
    nonisolated enum CaptureState: Equatable, Sendable {
        case off
        /// The capture is being set up off the main actor. The first time, macOS may
        /// show the permission prompt meanwhile.
        case starting
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
    @ObservationIgnored private let copyText: (String) -> Void
    @ObservationIgnored private let silenceHint: Double
    @ObservationIgnored private var pipeline: CaptionPipeline?
    /// Starts and stops the capture, one after the other, off the main actor. Since it is
    /// serial, a stop that comes while a start still runs tears down what the start made.
    @ObservationIgnored private let captureQueue = DispatchQueue(label: "io.github.db-ol.Orra.caption-capture", qos: .userInitiated)
    /// Counts the starts, so samples of an earlier run are ignored.
    @ObservationIgnored private var run = 0
    @ObservationIgnored private var heardSeconds = 0.0
    @ObservationIgnored private var heardSound = false
    /// True once this run called `started`, so a switch to a mode that translates calls it
    /// once, and a switch back does not undo it until captions stop.
    @ObservationIgnored private var wantsModel = false

    /// - Parameters:
    ///   - source: The capture of the sound the Mac plays. Tests pass a fake.
    ///   - engines: The models, see CaptionEngines.live.
    ///   - started: Called once captions run in a mode that translates, so the cleanup
    ///     model loads, see TextCleanup.captionsStarted. Not in Original only, until the
    ///     user switches to a mode that translates.
    ///   - stopped: Called when they stop.
    ///   - copyText: Puts a copy on the clipboard. Tests pass a fake.
    ///   - silenceHint: Seconds of only zeros before the window suggests the permission.
    init(
        source: SystemAudioSource,
        engines: CaptionEngines,
        started: @escaping () -> Void = {},
        stopped: @escaping () -> Void = {},
        displayMode: CaptionDisplayMode = .translationOnly,
        saveDisplayMode: @escaping (CaptionDisplayMode) -> Void = { _ in },
        store: CaptionStore = CaptionStore(),
        copyText: @escaping (String) -> Void = { ConcealedClipboard.copy($0, to: .general) },
        silenceHint: Double = 8
    ) {
        self.source = source
        self.engines = engines
        self.started = started
        self.stopped = stopped
        self.displayMode = displayMode
        self.saveDisplayMode = saveDisplayMode
        self.store = store
        self.copyText = copyText
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
        // Logged while captions are on, so a model load in the middle of a run has its
        // cause in the log.
        if isOn {
            Logger.captions.notice("Meeting captions now showing \(mode.rawValue, privacy: .public)")
        }
        // A switch to a mode that translates while captions run loads the model now. A
        // switch back keeps it until captions stop, so it does not load and unload.
        if capture == .listening {
            wantModelIfTranslating()
        }
    }

    /// Copies a transcript, such as `store.transcript` or `store.previous`, the way the
    /// window shows it unless `content` says otherwise. Concealed and kept on this Mac,
    /// as Copy Last Dictation, see ConcealedClipboard, since captions are other people's
    /// words. Returns false when there is nothing to copy. Logs the count, never the text.
    @discardableResult
    func copy(_ transcript: CaptionTranscript, as content: CaptionTranscript.Content? = nil) -> Bool {
        guard !transcript.isEmpty else { return false }
        let content = content ?? displayMode.copyContent
        copyText(transcript.text(content))
        Logger.captions.notice("Captions copied, \(transcript.sentences.count, privacy: .public) sentences, \(content.logName, privacy: .public)")
        return true
    }

    private func start() {
        isOn = true
        run += 1
        store.startOver()
        follow = CaptionFollow()
        hearsOnlySilence = false
        speechModelMissing = false
        heardSeconds = 0
        heardSound = false
        let pipeline = CaptionPipeline(engines: engines, interimInterval: CaptionPipeline.defaultInterimInterval, wantsTranslation: { [weak self] in
            self?.displayMode.translates ?? false
        }, speechNotReady: { [weak self] in
            self?.speechModelMissing = true
        }, withdraw: { [weak self] id in
            self?.store.remove(id: id)
        }, report: { [weak self] sentence in
            self?.speechModelMissing = false
            self?.store.apply(sentence)
        })
        self.pipeline = pipeline
        showWindow()
        let current = run
        capture = .starting
        let source = source
        let deliver: @Sendable ([Float]) -> Void = { [weak self] samples in
            DispatchQueue.main.async {
                self?.receive(samples, run: current)
            }
        }
        // Creating the tap and the device and starting it can wait for the permission
        // prompt, so it runs off the main actor and the outcome comes back to it.
        captureQueue.async { [weak self] in
            let problem: SystemAudioProblem?
            do {
                try source.start(deliver)
                problem = nil
            } catch let failure as SystemAudioProblem {
                problem = failure
            } catch {
                problem = .failed(step: "start", status: 0)
            }
            DispatchQueue.main.async {
                self?.captureStarted(run: current, problem: problem)
            }
        }
    }

    /// The outcome of a start, on the main actor. Ignored when captions were turned off
    /// meanwhile: that stop is queued after the start and tears it down.
    private func captureStarted(run current: Int, problem: SystemAudioProblem?) {
        guard isOn, current == run else { return }
        if let problem {
            capture = .unavailable(problem)
            return
        }
        // Only once the capture runs: the local model is not loaded, nor its download
        // offered, for captions that cannot hear anything, nor in Original only.
        wantModelIfTranslating()
        capture = .listening
        Logger.captions.notice("Meeting captions started, showing \(self.displayMode.rawValue, privacy: .public), into \(self.engines.target().logName, privacy: .public)")
    }

    /// Asks for the local model once per run, when the display mode translates.
    private func wantModelIfTranslating() {
        guard displayMode.translates, !wantsModel else { return }
        wantsModel = true
        started()
    }

    private func stop() {
        isOn = false
        run += 1
        let source = source
        captureQueue.async {
            source.stop()
        }
        pipeline?.stop()
        pipeline = nil
        wantsModel = false
        // Kept for a copy after the meeting. Sentences still waiting to be transcribed
        // are dropped, since transcribing them would keep the GPU busy after the stop.
        store.settle()
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
