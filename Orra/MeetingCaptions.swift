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

    /// What came in place of sound, see `silence`.
    nonisolated enum SilenceKind: Equatable, Sendable {
        /// No samples at all while Core Audio says that no app but Orra plays. The capture
        /// delivers none until an app plays something, see SystemAudioTap, so the window
        /// says that nothing plays.
        case noAudio
        /// No sound although something may play, so the window suggests the permission.
        /// Samples that were all exactly zero, which is what a refused permission looks
        /// like while something plays, or no samples at all while an app plays or Core
        /// Audio cannot tell, which a refused permission may give too.
        case noSound
    }

    /// Seconds between the checks of whether an app plays, while no samples came and the
    /// window says that nothing plays. Two checks in a row that find an app playing, or
    /// that cannot tell, suggest the permission instead, so the tap's auto start has had
    /// at least this long to deliver audio once something plays. A call that starts while
    /// the window says that nothing plays, and brings no audio, gets the permission note 3
    /// to 6 s later. Each check reads only Core Audio's list of processes and their state,
    /// see SystemAudioTap.somethingPlays, and the checks end with the first audio and when
    /// captions stop.
    static let playCheckInterval = 3.0
    /// Seconds a check waits for Core Audio's answer. Its reads take milliseconds, so a
    /// check with no answer by then counts as one that cannot tell, and an audio server
    /// that hangs suggests the permission instead of leaving the window without a note.
    static let playCheckLimit = 2.0

    private(set) var isOn = false
    private(set) var capture: CaptureState = .off
    /// What came in place of sound for `silenceHint` since captions were turned on, for
    /// the window's note. Nil until then and from the first sound on. No audio at all
    /// becomes no sound when an app starts to play and still no audio comes, see
    /// `playCheckInterval`, and goes once audio comes, since something plays then. Both go
    /// after a start that failed, whose own note says why.
    private(set) var silence: SilenceKind?
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
    @ObservationIgnored private let playCheckInterval: Double
    @ObservationIgnored private let playCheckLimit: Double
    @ObservationIgnored private var pipeline: CaptionPipeline?
    /// Starts and stops the capture, one after the other, off the main actor. Since it is
    /// serial, a stop that comes while a start still runs tears down what the start made.
    @ObservationIgnored private let captureQueue = DispatchQueue(label: "io.github.db-ol.Orra.caption-capture", qos: .userInitiated)
    /// Asks whether an app plays, off the main actor. Not `captureQueue`, which a start
    /// that waits for the first sound holds.
    @ObservationIgnored private let playQueue = DispatchQueue(label: "io.github.db-ol.Orra.caption-plays", qos: .userInitiated)
    /// Counts the starts, so samples of an earlier run are ignored.
    @ObservationIgnored private var run = 0
    /// When captions were turned on, for the times in the log.
    @ObservationIgnored private var turnedOn = ContinuousClock.now
    /// Seconds of audio this run, and of those with sound, so the log tells no audio
    /// from silence.
    @ObservationIgnored private var receivedSeconds = 0.0
    @ObservationIgnored private var soundSeconds = 0.0
    @ObservationIgnored private var heardSound = false
    /// Checks what plays while no samples come, see `checkSilence`.
    @ObservationIgnored private var silenceCheck: Task<Void, Never>?
    /// True once a check found an app playing, or could not tell, while the window said
    /// that nothing plays, until a check finds none.
    @ObservationIgnored private var mayPlay = false
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
    ///   - silenceHint: Seconds without sound before the window says that nothing plays or
    ///     suggests the permission.
    ///   - playCheckInterval: See `MeetingCaptions.playCheckInterval`.
    ///   - playCheckLimit: See `MeetingCaptions.playCheckLimit`.
    init(
        source: SystemAudioSource,
        engines: CaptionEngines,
        started: @escaping () -> Void = {},
        stopped: @escaping () -> Void = {},
        displayMode: CaptionDisplayMode = .translationOnly,
        saveDisplayMode: @escaping (CaptionDisplayMode) -> Void = { _ in },
        store: CaptionStore = CaptionStore(),
        copyText: @escaping (String) -> Void = { ConcealedClipboard.copy($0, to: .general) },
        silenceHint: Double = 8,
        playCheckInterval: Double = MeetingCaptions.playCheckInterval,
        playCheckLimit: Double = MeetingCaptions.playCheckLimit
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
        self.playCheckInterval = playCheckInterval
        self.playCheckLimit = playCheckLimit
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
        turnedOn = .now
        Logger.captions.notice("Meeting captions turned on")
        store.startOver()
        follow = CaptionFollow()
        silence = nil
        speechModelMissing = false
        receivedSeconds = 0
        soundSeconds = 0
        heardSound = false
        mayPlay = false
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
        // When no samples at all came by the time samples of only zeros would suggest the
        // permission, as while nothing plays or the start waits, Core Audio tells whether
        // an app plays. See checkSilence and receive.
        silenceCheck = Task { [weak self, silenceHint] in
            var wait = silenceHint
            while true {
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled, let next = await self?.checkSilence(run: current) else { return }
                wait = next
            }
        }
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
            // The window says that the capture failed, which is why no sound comes. So it
            // shows no note about silence, and this run neither checks what plays nor logs
            // about silence anymore. When the start failed after `silenceHint`, the log may
            // already say that nothing plays.
            silenceCheck?.cancel()
            silenceCheck = nil
            silence = nil
            return
        }
        // Only once the capture runs: the local model is not loaded, nor its download
        // offered, for captions that cannot hear anything, nor in Original only.
        wantModelIfTranslating()
        capture = .listening
        let target = CaptionTarget.effective(engines.target(), for: engines.language())
        // How long the start took tells a start that waited, as for the permission
        // prompt, from audio that comes late.
        Logger.captions.notice("Meeting captions started, showing \(self.displayMode.rawValue, privacy: .public), into \(target.logName, privacy: .public), after \(self.turnedOn.duration(to: .now), privacy: .public)")
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
        let sentences = pipeline?.counts ?? CaptionPipeline.Counts()
        pipeline?.stop()
        pipeline = nil
        silenceCheck?.cancel()
        silenceCheck = nil
        wantsModel = false
        // Kept for a copy after the meeting. Sentences still waiting to be transcribed
        // are dropped, since transcribing them would keep the GPU busy after the stop.
        store.settle()
        capture = .off
        silence = nil
        speechModelMissing = false
        stopped()
        closeWindow()
        // The counts tell no audio from silence, and sound without speech from sentences
        // that were dropped or still waited, as behind a long dictation.
        Logger.captions.notice("Meeting captions stopped after \(self.turnedOn.duration(to: .now), privacy: .public), with \(self.receivedSeconds, format: .fixed(precision: 1), privacy: .public) s of audio, \(self.soundSeconds, format: .fixed(precision: 1), privacy: .public) s of it with sound, \(sentences.cut, privacy: .public) sentences cut, \(sentences.reported, privacy: .public) reported, \(sentences.empty, privacy: .public) without text and \(sentences.dropped, privacy: .public) dropped")
    }

    /// Samples from the capture, on the main actor. Internal for tests.
    func receive(_ samples: [Float], run: Int? = nil) {
        guard isOn, run == nil || run == self.run, let pipeline else { return }
        if receivedSeconds == 0, !samples.isEmpty {
            Logger.captions.notice("Meeting captions got the first audio \(self.turnedOn.duration(to: .now), privacy: .public) after they were turned on")
            // Something plays now, so the window no longer says that nothing does. A
            // suggestion of the permission stays until the first sound, as with zeros.
            if silence == .noAudio {
                silence = nil
            }
        }
        let seconds = Double(samples.count) / Double(RecordingLimits.sampleRate)
        receivedSeconds += seconds
        if samples.contains(where: { $0 != 0 }) {
            soundSeconds += seconds
            if !heardSound {
                heardSound = true
                silence = nil
                Logger.captions.notice("Meeting captions got the first sound \(self.turnedOn.duration(to: .now), privacy: .public) after they were turned on")
            }
        } else if !heardSound, receivedSeconds >= silenceHint {
            suggestPermission(after: silenceHint)
        }
        pipeline.feed(samples)
    }

    /// One check of what plays while no samples came this run: at `silenceHint`, and every
    /// `playCheckInterval` while the window says that nothing plays. Returns the seconds
    /// until the next check, or nil when none is needed anymore.
    private func checkSilence(run current: Int) async -> Double? {
        guard waitsForAudio(run: current) else { return nil }
        let plays = await somethingPlays()
        guard !Task.isCancelled, waitsForAudio(run: current) else { return nil }
        if plays == false {
            mayPlay = false
            if silence == nil {
                sayNothingPlays()
            }
            return playCheckInterval
        }
        // An app plays, or Core Audio cannot tell. At `silenceHint` that suggests the
        // permission at once, as samples of only zeros do. Once the window said that
        // nothing plays, the tap's auto start gets until the next check to deliver audio.
        if silence == .noAudio, !mayPlay {
            mayPlay = true
            if plays == true {
                Logger.captions.notice("Meeting captions found an app playing \(self.turnedOn.duration(to: .now), privacy: .public) after they were turned on, with no audio yet")
            }
            return playCheckInterval
        }
        suggestPermission(after: silence == nil ? silenceHint : turnedOn.duration(to: .now) / .seconds(1))
        return nil
    }

    /// Whether this run still got no samples at all, with no note or the note that nothing
    /// plays in the window.
    private func waitsForAudio(run current: Int) -> Bool {
        isOn && current == run && receivedSeconds == 0 && silence != .noSound
    }

    /// Asks on `playQueue` whether an app plays, see SystemAudioSource.somethingPlays. Nil
    /// when Core Audio cannot tell, also when it gave no answer within `playCheckLimit`.
    private func somethingPlays() async -> Bool? {
        let ask = source.somethingPlays
        let queue = playQueue
        let (answer, timedOut) = await TimedCall.run(within: .seconds(playCheckLimit)) {
            await withCheckedContinuation { continuation in
                queue.async {
                    continuation.resume(returning: ask())
                }
            }
        }
        if timedOut {
            Logger.captions.notice("Meeting captions could not tell within \(self.playCheckLimit, format: .fixed(precision: 1), privacy: .public) s whether an app plays")
        }
        return try? answer.get()
    }

    /// No samples at all came for `silenceHint` while no app plays, so the window says
    /// that nothing plays. The log line has the shape of the one in `suggestPermission`,
    /// and its 0.0 s of audio tells the two apart.
    private func sayNothingPlays() {
        silence = .noAudio
        Logger.captions.notice("Meeting captions got no sound for \(self.silenceHint, format: .fixed(precision: 1), privacy: .public) s, with \(self.receivedSeconds, format: .fixed(precision: 1), privacy: .public) s of audio, and say that nothing plays")
    }

    /// No sound came for `seconds` although something may play, see SilenceKind.noSound,
    /// so the window suggests the permission.
    private func suggestPermission(after seconds: Double) {
        guard silence != .noSound else { return }
        silence = .noSound
        Logger.captions.notice("Meeting captions got no sound for \(seconds, format: .fixed(precision: 1), privacy: .public) s, with \(self.receivedSeconds, format: .fixed(precision: 1), privacy: .public) s of audio, and suggest the permission")
    }

    /// The run of the latest start, for tests that feed samples like the capture does.
    var currentRun: Int {
        run
    }
}
