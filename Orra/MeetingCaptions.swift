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

/// What Live Captions listen to, one at a time: what the Mac plays, or the microphone once
/// the user chooses it. Not saved, so every launch starts with what the Mac plays and a
/// launch never opens the microphone. Captions of both at once, each with its own label,
/// would be a third choice.
nonisolated enum CaptionSource: String, CaseIterable, Sendable {
    case systemAudio
    case microphone
}

/// Meeting captions: what the Mac plays, or the microphone when the user chooses it, cut
/// into sentences, transcribed and translated as they come, shown in a floating window.
/// Off at every launch, turned on from the menu.
///
/// A meeting keeps one pipeline and one window from the start to the stop, and only the
/// capture under them changes when the user chooses what captions listen to. Each capture
/// starts and stops on a queue of its own, so a switch never waits for a start of the
/// other, such as one that waits for the permission prompt.
///
/// The microphone is the user's own voice, and dictation goes first: from the press of the
/// talk key or the translation key until the dictation is pasted or cancelled, while a
/// voice sample records and while Orra speaks a translation, microphone captions drop what
/// the microphone hears before it reaches the pipeline, see `MicrophonePause`, and they go
/// on afterwards. Their unit keeps running meanwhile, and a start of it waits until the
/// pause is over, see `startMicrophone`. Their model calls go through EngineTurns as all
/// caption calls do.
///
/// While the screen is locked, or the user's session is switched away, microphone captions
/// let go of the microphone as a stop does, and start it again once the screen unlocks, if
/// they are still on and still listen to it, see `screenLockChanged(_:)`. The sentence
/// being heard ends at the lock, and nothing said meanwhile is captioned. Captions of what
/// the Mac plays go on. A lock counts from its note, or at a wake from a read of the window
/// server's session that says locked, see `macDidWake()`. Microphone captions let go of the
/// microphone at a sleep too, and the wake starts it again, see `macWillSleep()`.
///
/// While captions start or listen and their window can be seen, they keep the display on,
/// as a video player does, see `keepsDisplayOn`.
///
/// Turning it off stops the capture, lets go of the microphone and closes the window. The
/// sentences stay in memory until Orra quits, so they can still be copied, and the next
/// start keeps them as the previous transcript. Nothing is logged or saved but counts,
/// timings and states.
@Observable
final class MeetingCaptions {
    nonisolated enum CaptureState: Equatable, Sendable {
        case off
        /// The capture is being set up off the main actor. The first time, macOS may
        /// show the permission prompt meanwhile. Microphone captions also show as
        /// starting from a sleep until the wake starts the microphone again, see
        /// `macWillSleep()`.
        case starting
        case listening
        /// What the Mac plays cannot be captured.
        case unavailable(SystemAudioProblem)
        /// The microphone cannot be used, see MicrophoneCaptionProblem.
        case microphoneUnavailable(MicrophoneCaptionProblem)
        /// Captions listen to the microphone, but the screen is locked or the user's
        /// session is switched away, so nothing of it runs until the unlock, see
        /// `screenLocked`.
        case pausedWhileLocked
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
        /// The microphone gave no sound, as dictation measures it, see Silence: none since
        /// it started, or none for `microphoneQuietLimit` after it gave some, as with a
        /// closed lid or a muted microphone. The window explains it as the menu explains a
        /// dictation without sound.
        case microphoneSilent(MicrophoneSituation)
    }

    /// What holds microphone captions back, read at each piece of audio the microphone
    /// delivers. Captions of what the Mac plays are never held back.
    nonisolated enum MicrophonePause: Equatable, Sendable {
        /// Nothing: microphone captions take in what the microphone hears.
        case notPaused
        /// A key that waits is down, and its press may still turn out to be a shortcut,
        /// such as right Option to type a character. What the microphone hears meanwhile
        /// waits, and goes into the captions when the press is dropped.
        case arming
        /// A dictation, from the press of its key until it is pasted or cancelled, a voice
        /// sample that records, or Orra speaking a translation. What the microphone hears
        /// meanwhile is left out, and the sentence that was open ends.
        case paused

        /// From the state of push to talk, which goes from idle only at the press of a
        /// key, in any trigger mode, and back to idle once the dictation is pasted or
        /// cancelled, whether a voice sample records, and whether Orra speaks.
        init(dictation: PushToTalkStateMachine.State, recordsVoiceSample: Bool, speaks: Bool) {
            if recordsVoiceSample || speaks {
                self = .paused
                return
            }
            switch dictation {
            case .idle: self = .notPaused
            case .arming: self = .arming
            case .listening, .waitingForSecondPress, .handsFree, .processing: self = .paused
            }
        }
    }

    /// Why captions start the microphone again, for the log. The start at the unlock of the
    /// screen is none of these: it starts at once and never counts toward `restartLimit`,
    /// see `screenLockChanged(_:)`.
    nonisolated enum RestartReason: String, Sendable {
        /// The device went away, changed its rate or lost its inputs, or the microphone to
        /// listen to is now another one.
        case moved
        /// The user chose another microphone under Microphone.
        case choice
        /// The Mac woke from sleep, after which a device may come back silent or under a
        /// new ID. Its start reads the session first, see `lockedAtTheWake()`.
        case wake
        /// Microphone access was given.
        case access
        /// A device came or went while no microphone was connected.
        case inputs
        /// A device came or went after a start of the microphone failed, as on a headset
        /// whose input was not ready yet.
        case retry

        /// Whether the start again follows the device, not the user or the Mac, and so
        /// counts toward `restartLimit`.
        var followsTheDevice: Bool {
            self == .moved || self == .retry
        }
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
    /// Seconds after a pause during which the microphone's audio is still left out. A piece
    /// of audio reaches the main actor up to about a quarter of a second after it was
    /// recorded, a Bluetooth microphone's later, so this keeps the end of a cancelled
    /// dictation, or of Orra's voice from the speakers, out of the captions. Measured from
    /// the first piece that finds the pause over, which is never before its end.
    static let microphoneHold = 0.5
    /// Seconds without sound from the microphone, after it gave some, before the window
    /// says so. Longer than `silenceHint`, since a headset may give exactly zero while its
    /// user only listens.
    static let microphoneQuietLimit = 30.0
    /// Seconds a start again of the microphone waits after a move, a wake or a change of
    /// the devices, so a device that changes in steps opens once.
    static let restartDelay = 0.5
    /// The most starts again of the microphone that follow the device, after a move or a
    /// failed start, within `restartWindow`. One more lets go of the microphone and says
    /// that it could not start, so a device that keeps moving, such as a headset that
    /// changes its profile at each start, does not start again without end.
    static let restartLimit = 3
    /// Seconds over which `restartLimit` counts.
    static let restartWindow = 20.0
    /// Seconds between the looks at microphone access while it is not given, as the
    /// welcome window looks.
    static let accessCheckInterval = 1.0
    /// Seconds between the looks whether a pause of the microphone is over, while a start
    /// of the microphone waits for it.
    static let pauseCheckInterval = 0.1
    /// The most audio heard while a key that waits is down that is kept for the captions.
    /// A key waits 0.3 s, see TalkKeyDetector.
    static let armingLimit = 1.0
    /// Seconds between the looks at the window server's session while captions are on and
    /// take the screen as locked, since Apple's DistributedNotificationCenter says that a
    /// note may come late or be dropped, see `followTheScreenLock()`. A look reads one
    /// dictionary of the window server.
    static let screenLockCheckInterval = 2.0

    private(set) var isOn = false
    private(set) var capture: CaptureState = .off
    /// What captions listen to. What the Mac plays until the user chooses the microphone,
    /// at every launch.
    private(set) var source: CaptionSource = .systemAudio
    /// The microphone captions listen to, for the window's sign. Set only while they
    /// listen to it: nil while it starts or cannot be used, while the screen is locked,
    /// and once captions stop or listen to what the Mac plays again.
    private(set) var microphoneInUse: AudioInput?
    /// Whether the screen is locked or the user's session is switched away, as captions
    /// last learned it, see ScreenLockSource. Microphone captions let go of the microphone
    /// meanwhile, see `screenLockChanged(_:)`.
    private(set) var screenLocked = false
    /// Whether the caption window can be seen, as CaptionWindow reports it, see
    /// `keepsDisplayOn`.
    private(set) var windowVisible = false
    /// What came in place of sound for `silenceHint` since the capture started, for the
    /// window's note. Nil until then and from the first sound on. No audio at all from the
    /// Mac becomes no sound when an app starts to play and still no audio comes, see
    /// `playCheckInterval`, and goes once audio comes, since something plays then. Each
    /// goes after a start that failed, whose own note says why.
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

    /// What one start of the capture keeps. Reset at each start: when captions turn on,
    /// when the user chooses what they listen to, and when the microphone starts again.
    private struct CaptureRun {
        /// Seconds of audio this start delivered, so the log and the notes tell no audio
        /// from silence.
        var receivedSeconds = 0.0
        var heardSound = false
        /// Seconds of the microphone without sound in a row.
        var quietSeconds = 0.0
        /// True once a check found an app playing, or could not tell, while the window
        /// said that nothing plays, until a check finds none.
        var mayPlay = false
        /// True from the first piece of the microphone's audio that a pause left out until
        /// one finds it over.
        var paused = false
        /// The microphone's audio while a key that waits is down, kept until its press
        /// counts or is dropped.
        var armingAudio: [[Float]] = []
        /// Seconds of `armingAudio`.
        var heldSeconds: Double {
            Double(armingAudio.reduce(0) { $0 + $1.count }) / Double(RecordingLimits.sampleRate)
        }
        /// The microphone's audio that arrives before this is still left out after a
        /// pause, see `microphoneHold`.
        var holdUntil: ContinuousClock.Instant?
        /// True after a pause, until the sentence that was open is ended.
        var endsSentence = false
        /// Checks what plays while no samples come, or whether the microphone gave sound.
        var silenceCheck: Task<Void, Never>?
        /// Looks at microphone access while it is not given.
        var accessCheck: Task<Void, Never>?
        /// A start of the microphone that waits for its queue and for a pause to end, see
        /// `startMicrophone`.
        var waitingStart: Task<Void, Never>?
        /// A start again of the microphone, see `scheduleRestart`.
        var restart: Task<Void, Never>?
        /// Watches the devices while no microphone is connected or after a start of it
        /// failed.
        var inputWatch: AnyObject?

        func cancelTasks() {
            silenceCheck?.cancel()
            accessCheck?.cancel()
            waitingStart?.cancel()
            restart?.cancel()
        }
    }

    /// The meeting's counts for the log, over all its starts of the capture.
    private struct MeetingCounts {
        var receivedSeconds = 0.0
        var soundSeconds = 0.0
        /// Pauses of the microphone, and the seconds of its audio they left out.
        var pauses = 0
        var leftOutSeconds = 0.0
        var listenedToMicrophone = false
    }

    @ObservationIgnored private let systemAudio: SystemAudioSource
    @ObservationIgnored private let microphone: MicrophoneCaptionSource
    @ObservationIgnored private let screenLock: ScreenLockSource
    @ObservationIgnored private let engines: CaptionEngines
    @ObservationIgnored private let started: () -> Void
    @ObservationIgnored private let stopped: () -> Void
    @ObservationIgnored private let saveDisplayMode: (CaptionDisplayMode) -> Void
    @ObservationIgnored private let copyText: (String) -> Void
    @ObservationIgnored private let pausesMicrophone: () -> MicrophonePause
    @ObservationIgnored private let askForMicrophoneAccess: () -> Void
    @ObservationIgnored private let silenceHint: Double
    @ObservationIgnored private let playCheckInterval: Double
    @ObservationIgnored private let playCheckLimit: Double
    @ObservationIgnored private let microphoneHold: Double
    @ObservationIgnored private let microphoneQuietLimit: Double
    @ObservationIgnored private let restartDelay: Double
    @ObservationIgnored private let restartWindow: Double
    @ObservationIgnored private let accessCheckInterval: Double
    @ObservationIgnored private let screenLockCheckInterval: Double
    @ObservationIgnored private var pipeline: CaptionPipeline?
    /// Starts and stops the capture of what the Mac plays, one after the other, off the
    /// main actor. Since it is serial, a stop that comes while a start still runs tears
    /// down what the start made.
    @ObservationIgnored private let captureQueue = DispatchQueue(label: "io.github.db-ol.Orra.caption-capture", qos: .userInitiated)
    /// The same for the microphone, so a switch never waits for a start of the other.
    @ObservationIgnored private let microphoneQueue = DispatchQueue(label: "io.github.db-ol.Orra.caption-microphone-start", qos: .userInitiated)
    /// Asks whether an app plays, off the main actor. Not `captureQueue`, which a start
    /// that waits for the first sound holds.
    @ObservationIgnored private let playQueue = DispatchQueue(label: "io.github.db-ol.Orra.caption-plays", qos: .userInitiated)
    /// Counts the starts and stops of the capture, so samples of an earlier one are
    /// ignored.
    @ObservationIgnored private var run = 0
    /// What the current start of the capture listens to, so its stop reaches it after
    /// `source` changed. Nil while captions are off, and while microphone captions wait
    /// for the screen to unlock.
    @ObservationIgnored private var capturing: CaptionSource?
    /// The microphone chosen under Microphone, nil for the system default, see
    /// `microphoneChosen(_:)`.
    @ObservationIgnored private var chosenMicrophone: String?
    /// When the microphone started again to follow the device, within `restartWindow`.
    /// Cleared when captions turn on and when the user chooses what they listen to or a
    /// microphone.
    @ObservationIgnored private var deviceRestarts: [ContinuousClock.Instant] = []
    @ObservationIgnored private var runState = CaptureRun()
    @ObservationIgnored private var meeting = MeetingCounts()
    /// When captions were turned on, for the times in the log.
    @ObservationIgnored private var turnedOn = ContinuousClock.now
    /// When the current start of the capture began, for the times in the log.
    @ObservationIgnored private var captureStarted = ContinuousClock.now
    /// True once this meeting called `started`, so a switch to a mode that translates
    /// calls it once, and a switch back does not undo it until captions stop.
    @ObservationIgnored private var wantsModel = false
    /// Keeps the watch of the screen lock, see ScreenLockSource.watch.
    @ObservationIgnored private var screenLockWatch: AnyObject?
    /// True once a read of the session said locked since captions took the screen as
    /// locked, see `sessionShowsTheUnlock()`.
    @ObservationIgnored private var sessionSaidLocked = false
    /// Looks at the session while captions are on and the screen is locked, see
    /// `followTheScreenLock()`.
    @ObservationIgnored private var screenLockCheck: Task<Void, Never>?

    /// - Parameters:
    ///   - systemAudio: The capture of the sound the Mac plays. Tests pass a fake.
    ///   - microphone: The capture of the microphone. Tests pass a fake, and captions
    ///     without one listen only to what the Mac plays.
    ///   - screenLock: Whether the screen is locked, see ScreenLockSource. Tests pass a fake,
    ///     and captions without one take the screen as never locked.
    ///   - engines: The models, see CaptionEngines.live.
    ///   - started: Called once captions run in a mode that translates, so the cleanup
    ///     model loads, see TextCleanup.captionsStarted. Not in Original only, until the
    ///     user switches to a mode that translates.
    ///   - stopped: Called when they stop.
    ///   - copyText: Puts a copy on the clipboard. Tests pass a fake.
    ///   - pausesMicrophone: What holds microphone captions back now, see
    ///     MicrophonePause. Read on the main actor at each piece of the microphone's audio.
    ///   - askForMicrophoneAccess: Shows the prompt for microphone access, called only when
    ///     the user chooses the microphone while access is not decided yet.
    ///   - silenceHint: Seconds without sound before the window says that nothing plays,
    ///     suggests the permission, or says that the microphone gave no sound.
    ///   - playCheckInterval: See `MeetingCaptions.playCheckInterval`.
    ///   - playCheckLimit: See `MeetingCaptions.playCheckLimit`.
    ///   - microphoneHold: See `MeetingCaptions.microphoneHold`.
    ///   - microphoneQuietLimit: See `MeetingCaptions.microphoneQuietLimit`.
    ///   - restartDelay: See `MeetingCaptions.restartDelay`.
    ///   - restartWindow: See `MeetingCaptions.restartWindow`.
    ///   - accessCheckInterval: See `MeetingCaptions.accessCheckInterval`.
    ///   - screenLockCheckInterval: See `MeetingCaptions.screenLockCheckInterval`.
    init(
        systemAudio: SystemAudioSource,
        microphone: MicrophoneCaptionSource = .unavailable,
        screenLock: ScreenLockSource = .unlocked,
        engines: CaptionEngines,
        started: @escaping () -> Void = {},
        stopped: @escaping () -> Void = {},
        displayMode: CaptionDisplayMode = .translationOnly,
        saveDisplayMode: @escaping (CaptionDisplayMode) -> Void = { _ in },
        store: CaptionStore = CaptionStore(),
        copyText: @escaping (String) -> Void = { ConcealedClipboard.copy($0, to: .general) },
        pausesMicrophone: @escaping () -> MicrophonePause = { .notPaused },
        askForMicrophoneAccess: @escaping () -> Void = {},
        silenceHint: Double = 8,
        playCheckInterval: Double = MeetingCaptions.playCheckInterval,
        playCheckLimit: Double = MeetingCaptions.playCheckLimit,
        microphoneHold: Double = MeetingCaptions.microphoneHold,
        microphoneQuietLimit: Double = MeetingCaptions.microphoneQuietLimit,
        restartDelay: Double = MeetingCaptions.restartDelay,
        restartWindow: Double = MeetingCaptions.restartWindow,
        accessCheckInterval: Double = MeetingCaptions.accessCheckInterval,
        screenLockCheckInterval: Double = MeetingCaptions.screenLockCheckInterval
    ) {
        self.systemAudio = systemAudio
        self.microphone = microphone
        self.screenLock = screenLock
        self.engines = engines
        self.started = started
        self.stopped = stopped
        self.displayMode = displayMode
        self.saveDisplayMode = saveDisplayMode
        self.store = store
        self.copyText = copyText
        self.pausesMicrophone = pausesMicrophone
        self.askForMicrophoneAccess = askForMicrophoneAccess
        self.silenceHint = silenceHint
        self.playCheckInterval = playCheckInterval
        self.playCheckLimit = playCheckLimit
        self.microphoneHold = microphoneHold
        self.microphoneQuietLimit = microphoneQuietLimit
        self.restartDelay = restartDelay
        self.restartWindow = restartWindow
        self.accessCheckInterval = accessCheckInterval
        self.screenLockCheckInterval = screenLockCheckInterval
        // As the session says now, which covers a launch while the screen is locked or the
        // session is switched away, and after that as the watch reports.
        screenLocked = screenLock.isLocked()
        sessionSaidLocked = screenLocked
        screenLockWatch = screenLock.watch { [weak self] locked in
            self?.screenLockNoted(locked)
        }
    }

    func setOn(_ on: Bool) {
        guard on != isOn else { return }
        on ? start() : stop()
    }

    /// Chooses what captions listen to. While they are on, the capture changes at once,
    /// and the meeting, its window and its sentences go on. Choosing the microphone while
    /// access is not decided yet shows the prompt, which so follows the user's own click.
    /// While the screen is locked, the microphone waits for the unlock.
    func setSource(_ choice: CaptionSource) {
        guard choice != source else { return }
        source = choice
        deviceRestarts = []
        if choice == .microphone, microphone.access() == .notDetermined {
            askForMicrophoneAccess()
        }
        guard isOn else { return }
        Logger.captions.notice("Meeting captions now listen to \(choice.rawValue, privacy: .public)")
        lookAtTheScreenLockBeforeAStart()
        restartCapture()
    }

    /// The user chose the microphone with this UID under Microphone, or nil for the system
    /// default. Captions that listen to the microphone start it again with the new one.
    func microphoneChosen(_ uid: String?) {
        guard uid != chosenMicrophone else { return }
        chosenMicrophone = uid
        deviceRestarts = []
        scheduleRestart(.choice, after: 0)
    }

    /// The Mac goes to sleep. Captions that listen to the microphone let go of it, as a stop
    /// does, so no unit runs through the sleep into a lock screen, and the sentence being
    /// heard ends. They still listen to it and show as starting, and the wake starts it
    /// again, see `macDidWake()`. The capture of what the Mac plays goes on as it is.
    func macWillSleep() {
        guard isOn, capturing == .microphone else { return }
        Logger.captions.notice("Meeting captions let go of the microphone while the Mac sleeps")
        stopCapture()
        pipeline?.endSentence()
        capturing = .microphone
        capture = .starting
        silence = nil
    }

    /// The Mac woke from sleep. Captions that listen to the microphone start it again,
    /// since its IO may come back silent or its device under a new ID. The note of a lock
    /// may reach Orra after the wake, so a session that says locked at the wake, or at the
    /// wake's start of the microphone, counts as a lock, see `lockedAtTheWake()`. While the
    /// screen is locked nothing starts, and the unlock starts the microphone. The capture of
    /// what the Mac plays goes on as it is.
    func macDidWake() {
        if lockedAtTheWake() { return }
        scheduleRestart(.wake, after: restartDelay)
    }

    /// Whether captions keep the display on now, the way a video player does: while they
    /// are on and start or listen, their window can be seen and the screen is not locked,
    /// for both sources. AppDelegate holds a process activity while this is true. A capture
    /// that cannot start lets the display sleep, since its window then only says why, and
    /// so does the pause while the screen is locked. A dictation does not change it, and a
    /// start again stops and starts within one turn of the main actor, so it stays true.
    var keepsDisplayOn: Bool {
        guard isOn, windowVisible, !screenLocked else { return false }
        return switch capture {
        case .starting, .listening: true
        case .off, .unavailable, .microphoneUnavailable, .pausedWhileLocked: false
        }
    }

    /// The caption window can be seen now, or no longer, see CaptionWindow.
    func setWindowVisible(_ visible: Bool) {
        guard visible != windowVisible else { return }
        windowVisible = visible
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
        lookAtTheScreenLockBeforeAStart()
        isOn = true
        turnedOn = .now
        meeting = MeetingCounts()
        deviceRestarts = []
        Logger.captions.notice("Meeting captions turned on, listening to \(self.source.rawValue, privacy: .public)")
        store.startOver()
        follow = CaptionFollow()
        speechModelMissing = false
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
        startCapture()
        followTheScreenLock()
    }

    private func stop() {
        isOn = false
        followTheScreenLock()
        let listenedTo = capturing ?? source
        stopCapture()
        let sentences = pipeline?.counts ?? CaptionPipeline.Counts()
        pipeline?.stop()
        pipeline = nil
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
        let pauses = meeting.listenedToMicrophone
            ? ", \(meeting.pauses) pauses of the microphone, \(String(format: "%.1f", meeting.leftOutSeconds)) s of audio left out"
            : ""
        Logger.captions.notice("Meeting captions stopped after \(self.turnedOn.duration(to: .now), privacy: .public), listening to \(listenedTo.rawValue, privacy: .public), with \(self.meeting.receivedSeconds, format: .fixed(precision: 1), privacy: .public) s of audio, \(self.meeting.soundSeconds, format: .fixed(precision: 1), privacy: .public) s of it with sound, \(sentences.cut, privacy: .public) sentences cut, \(sentences.reported, privacy: .public) reported, \(sentences.empty, privacy: .public) without text and \(sentences.dropped, privacy: .public) dropped\(pauses, privacy: .public)")
    }

    /// Starts the capture of what captions listen to, under a new run. While the screen is
    /// locked, microphone captions start nothing and wait for the unlock.
    private func startCapture() {
        run += 1
        runState = CaptureRun()
        captureStarted = .now
        silence = nil
        microphoneInUse = nil
        if source == .microphone, screenLocked {
            capturing = nil
            capture = .pausedWhileLocked
            Logger.captions.notice("Meeting captions wait for the screen to unlock to start the microphone")
            return
        }
        capturing = source
        switch source {
        case .systemAudio:
            startSystemAudio()
        case .microphone:
            meeting.listenedToMicrophone = true
            startMicrophone()
        }
    }

    /// Stops the current capture. Its stop is queued at once behind a start of the same
    /// capture that still runs, and samples still on their way are ignored. What the start
    /// kept goes, also what a key that waits held back, so no audio stays in memory.
    private func stopCapture() {
        run += 1
        runState.cancelTasks()
        meeting.leftOutSeconds += runState.heldSeconds
        runState = CaptureRun()
        switch capturing {
        case .systemAudio:
            let systemAudio = systemAudio
            captureQueue.async {
                systemAudio.stop()
            }
        case .microphone:
            let microphone = microphone
            microphoneQueue.async {
                microphone.stop()
            }
        case nil:
            break
        }
        capturing = nil
        microphoneInUse = nil
    }

    /// Another capture under the same meeting: the window and the sentences stay, and the
    /// sentence that was open ends, since what comes next is not its continuation.
    private func restartCapture() {
        stopCapture()
        pipeline?.endSentence()
        startCapture()
    }

    private func startSystemAudio() {
        let current = run
        capture = .starting
        // When no samples at all came by the time samples of only zeros would suggest the
        // permission, as while nothing plays or the start waits, Core Audio tells whether
        // an app plays. See checkSilence and receive.
        self.runState.silenceCheck = Task { [weak self, silenceHint] in
            var wait = silenceHint
            while true {
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled, let next = await self?.checkSilence(run: current) else { return }
                wait = next
            }
        }
        let systemAudio = systemAudio
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
                try systemAudio.start(deliver)
                problem = nil
            } catch let failure as SystemAudioProblem {
                problem = failure
            } catch {
                problem = .failed(step: "start", status: 0)
            }
            DispatchQueue.main.async {
                self?.systemAudioStarted(run: current, problem: problem)
            }
        }
    }

    /// The outcome of a start of what the Mac plays, on the main actor. Ignored when
    /// captions were turned off or switched meanwhile: that stop is queued after the start
    /// and tears it down.
    private func systemAudioStarted(run current: Int, problem: SystemAudioProblem?) {
        guard isOn, current == run else { return }
        if let problem {
            capture = .unavailable(problem)
            // The window says that the capture failed, which is why no sound comes. So it
            // shows no note about silence, and this run neither checks what plays nor logs
            // about silence anymore. When the start failed after `silenceHint`, the log may
            // already say that nothing plays.
            self.runState.silenceCheck?.cancel()
            self.runState.silenceCheck = nil
            silence = nil
            return
        }
        // Only once the capture runs: the local model is not loaded, nor its download
        // offered, for captions that cannot hear anything, nor in Original only.
        wantModelIfTranslating()
        capture = .listening
        logStarted()
    }

    /// The microphone, after a look at access, which never prompts. Without access the
    /// window says so, nothing starts, and captions start once access is given. A start
    /// never asks: the prompt comes only from the user's choice of the microphone or a
    /// click in the window.
    ///
    /// The start first waits for what `microphoneQueue` still does, such as the stop of the
    /// unit before a start again, and then while a dictation, a voice sample or Orra's
    /// voice holds the microphone, whose audio captions would leave out anyway. So a press
    /// that comes while an earlier stop still runs holds the start too. Only a start already
    /// under way at the press completes, since a unit cannot stop halfway through its start.
    private func startMicrophone() {
        let access = microphone.access()
        guard access == .authorized else {
            microphoneUnavailable(.access(access))
            return
        }
        capture = .starting
        let current = run
        let queue = microphoneQueue
        self.runState.waitingStart = Task { [weak self] in
            await withCheckedContinuation { continuation in
                queue.async {
                    continuation.resume()
                }
            }
            await self?.waitWhileMicrophonePaused()
            guard !Task.isCancelled, let self, self.isOn, self.run == current else { return }
            self.launchMicrophone()
        }
    }

    /// Starts the microphone off the main actor, since a Bluetooth microphone can take
    /// seconds, and brings the outcome back to it.
    private func launchMicrophone() {
        let current = run
        startMicrophoneSilenceCheck(run: current)
        let microphone = microphone
        let preferred = chosenMicrophone
        let deliver: @Sendable ([Float]) -> Void = { [weak self] samples in
            DispatchQueue.main.async {
                self?.receive(samples, run: current)
            }
        }
        let moved: @Sendable () -> Void = { [weak self] in
            DispatchQueue.main.async {
                self?.microphoneMoved(run: current)
            }
        }
        microphoneQueue.async { [weak self] in
            let outcome: Result<AudioInput, MicrophoneCaptionProblem>
            do {
                outcome = .success(try microphone.start(preferred, deliver, moved))
            } catch let problem as MicrophoneCaptionProblem {
                outcome = .failure(problem)
            } catch {
                outcome = .failure(.failed(step: "start", status: 0))
            }
            DispatchQueue.main.async {
                self?.microphoneStarted(run: current, outcome: outcome)
            }
        }
    }

    /// The outcome of a start of the microphone, on the main actor. Ignored when captions
    /// were turned off or switched meanwhile, as for what the Mac plays.
    private func microphoneStarted(run current: Int, outcome: Result<AudioInput, MicrophoneCaptionProblem>) {
        guard isOn, current == run else { return }
        switch outcome {
        case .success(let input):
            microphoneInUse = input
            // A note that came while the start still ran names the device now.
            if case .microphoneSilent = silence {
                silence = .microphoneSilent(MicrophoneSituation(lidClosed: microphone.lidClosed(), input: input))
            }
            wantModelIfTranslating()
            capture = .listening
            logStarted()
        case .failure(let problem):
            microphoneUnavailable(problem)
        }
    }

    /// The window says why the microphone cannot be used, so it shows no note about
    /// silence. Captions start it once access is given, or at the next change of the
    /// devices after none was connected or its start failed.
    private func microphoneUnavailable(_ problem: MicrophoneCaptionProblem) {
        capture = .microphoneUnavailable(problem)
        runState.silenceCheck?.cancel()
        runState.silenceCheck = nil
        silence = nil
        switch problem {
        case .access(let access):
            Logger.captions.notice("Meeting captions cannot use the microphone, access \(String(describing: access), privacy: .public)")
            watchAccess(from: access)
        case .noInput:
            Logger.captions.notice("Meeting captions found no microphone to listen to")
            startAgainWhenTheDevicesChange(.inputs)
        case .failed(let step, let status):
            Logger.captions.error("Meeting captions could not start the microphone: \(step, privacy: .public), \(status, privacy: .public)")
            startAgainWhenTheDevicesChange(.retry)
        }
    }

    /// Starts the microphone again after the next change of Core Audio's devices, such as a
    /// microphone plugged in while none was connected, or a headset whose input is ready by
    /// then. Part of the current start, so a stop, a switch or the start again ends the
    /// watch.
    private func startAgainWhenTheDevicesChange(_ reason: RestartReason) {
        let current = run
        self.runState.inputWatch = microphone.watchInputs { [weak self] in
            guard let self, self.run == current else { return }
            self.scheduleRestart(reason, after: self.restartDelay)
        }
    }

    /// Looks at microphone access every `accessCheckInterval` while it is not given, and
    /// starts the microphone through `scheduleRestart` once it is, such as after the user
    /// allowed it in the prompt or in System Settings. Part of the current start, so a stop
    /// or a switch ends it, and access given later never opens the microphone for captions
    /// that are off or listen to what the Mac plays. A build that cannot ask never changes,
    /// so it is not watched.
    private func watchAccess(from access: MicrophoneAccess) {
        guard access != .notConfigured else { return }
        let current = run
        self.runState.accessCheck = Task { [weak self, accessCheckInterval] in
            var last = access
            while true {
                try? await Task.sleep(for: .seconds(accessCheckInterval))
                guard !Task.isCancelled, let self, self.isOn, self.run == current else { return }
                let now = self.microphone.access()
                if now == .authorized {
                    self.scheduleRestart(.access, after: 0)
                    return
                }
                if now != last {
                    last = now
                    self.capture = .microphoneUnavailable(.access(now))
                    if now == .notConfigured { return }
                }
            }
        }
    }

    /// The microphone moved, see MicrophoneCaptionSource.start.
    private func microphoneMoved(run current: Int) {
        guard current == run else { return }
        scheduleRestart(.moved, after: restartDelay)
    }

    /// Starts the microphone again after `delay`, once no pause holds it, unless captions
    /// were turned off, switched or started again meanwhile. Only while they listen to the
    /// microphone. A later call takes the place of one that still waits, and so does it of
    /// a start that still waits, since it starts the microphone anyway, so the microphone
    /// does not start only to stop and start again.
    private func scheduleRestart(_ reason: RestartReason, after delay: Double) {
        guard isOn, capturing == .microphone else { return }
        let current = run
        self.runState.waitingStart?.cancel()
        self.runState.restart?.cancel()
        self.runState.restart = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            await self?.waitWhileMicrophonePaused()
            guard !Task.isCancelled, let self, self.isOn, self.capturing == .microphone, self.run == current else { return }
            if reason == .wake, self.lockedAtTheWake() { return }
            if reason.followsTheDevice, !self.mayFollowTheDevice() {
                self.stopFollowingTheMicrophone()
                return
            }
            Logger.captions.notice("Meeting captions start the microphone again: \(reason.rawValue, privacy: .public)")
            self.restartCapture()
        }
    }

    /// Whether the microphone may start again to follow the device, see `restartLimit`.
    /// Counts the start again when it may.
    private func mayFollowTheDevice() -> Bool {
        let now = ContinuousClock.now
        deviceRestarts.removeAll { $0.duration(to: now) > .seconds(restartWindow) }
        guard deviceRestarts.count < Self.restartLimit else { return false }
        deviceRestarts.append(now)
        return true
    }

    /// The microphone kept moving, so captions let go of it, as a stop does, and the window
    /// says that it could not start. The sentence that was open ends. They still listen to
    /// the microphone, so turning them off and on, a choice of a microphone, a wake and the
    /// unlock of the screen start it again, and a change of the devices does not.
    private func stopFollowingTheMicrophone() {
        Logger.captions.error("Meeting captions let go of the microphone after \(Self.restartLimit, privacy: .public) starts again within \(self.restartWindow, format: .fixed(precision: 0), privacy: .public) s")
        stopCapture()
        pipeline?.endSentence()
        capturing = .microphone
        capture = .microphoneUnavailable(.failed(step: "follow the microphone", status: 0))
        silence = nil
    }

    /// The watch's report, see ScreenLockSource.watch. It comes after each note, so only a
    /// change counts. Any process can post the note of an unlock, so an unlock counts only
    /// while the session agrees, and otherwise the look at the session finds it once the
    /// session does, see `followTheScreenLock()`. The read that refuses the note said
    /// locked, so it counts for the look, also when the note of the lock came before the
    /// session said locked.
    private func screenLockNoted(_ locked: Bool) {
        guard locked != screenLocked else { return }
        if !locked, sessionSaysLocked() {
            Logger.captions.notice("Meeting captions take no unlock while the session says that the screen is locked")
            return
        }
        screenLockChanged(locked)
    }

    /// Takes the screen as locked when captions do not yet and the session says that it is,
    /// at a wake and at the wake's start of the microphone, since the note of a lock that
    /// came with the sleep may reach Orra after the wake. Only there: elsewhere only the
    /// watch's note locks. The note that comes late then changes nothing, and the unlock
    /// note or the look at the session ends the lock. Returns whether it locked.
    private func lockedAtTheWake() -> Bool {
        guard !screenLocked, sessionSaysLocked() else { return false }
        Logger.captions.notice("Meeting captions found the screen locked at the wake")
        screenLockChanged(true)
        return true
    }

    /// The user opened one of Orra's menus or clicked the caption window, which they can do
    /// only at an unlocked screen. A lock whose unlock note never came ends here when the
    /// session agrees, also on a Mac whose session does not tell a lock.
    func userIsAtTheScreen() {
        guard screenLocked, !sessionSaysLocked() else { return }
        Logger.captions.notice("Meeting captions found the screen unlocked without its note, at a menu or a click")
        screenLockChanged(false)
    }

    /// Takes the screen as locked or unlocked. Microphone captions that are on let go of
    /// the microphone at a lock, as a stop does, and the sentence being heard ends, see
    /// `restartCapture`. They start it again at the unlock, at once and through
    /// `startMicrophone`, so the start waits for a dictation as any start does, and it never
    /// counts toward `restartLimit`. Captions of what the Mac plays go on.
    private func screenLockChanged(_ locked: Bool) {
        screenLocked = locked
        if locked {
            // Only reads from this lock on count.
            sessionSaidLocked = false
            _ = sessionSaysLocked()
        }
        followTheScreenLock()
        guard isOn, source == .microphone else { return }
        if locked {
            Logger.captions.notice("Meeting captions let go of the microphone while the screen is locked")
        } else {
            Logger.captions.notice("Meeting captions start the microphone again after the screen unlocked")
        }
        restartCapture()
    }

    /// Reads the window server's session, see ScreenLockSource.isLocked. Every read after
    /// the first, in init, goes through here, so none that says locked while captions take
    /// the screen as locked is lost: it is noted, see `sessionShowsTheUnlock()`.
    private func sessionSaysLocked() -> Bool {
        let locked = screenLock.isLocked()
        if locked, screenLocked {
            sessionSaidLocked = true
        }
        return locked
    }

    /// Whether a read of the session shows that a lock captions still keep is over: it
    /// says unlocked now, and a read since the lock said locked. So on a Mac whose session
    /// does not tell a lock only the unlock note ends it, and the microphone never starts
    /// at the lock screen. A read locks only at a wake, see `lockedAtTheWake()`.
    private func sessionShowsTheUnlock() -> Bool {
        guard screenLocked, !sessionSaysLocked() else { return false }
        return sessionSaidLocked
    }

    /// Captions are turned on, or choose what they listen to, so a lock whose unlock note
    /// never came ends here once the session shows it, see `sessionShowsTheUnlock()`. Only
    /// the flag changes, since the caller starts the capture next.
    private func lookAtTheScreenLockBeforeAStart() {
        guard sessionShowsTheUnlock() else { return }
        Logger.captions.notice("Meeting captions found the screen unlocked without its note")
        screenLocked = false
        followTheScreenLock()
    }

    /// Looks at the session every `screenLockCheckInterval` while captions are on and take
    /// the screen as locked, so an unlock whose note came late, never came or came while
    /// the session still said locked is found without the user's help, see
    /// `sessionShowsTheUnlock()`. Ends with the lock and when captions stop.
    private func followTheScreenLock() {
        screenLockCheck?.cancel()
        screenLockCheck = nil
        guard isOn, screenLocked else { return }
        screenLockCheck = Task { [weak self, screenLockCheckInterval] in
            while true {
                try? await Task.sleep(for: .seconds(screenLockCheckInterval))
                guard !Task.isCancelled, let self, self.isOn, self.screenLocked else { return }
                if self.sessionShowsTheUnlock() {
                    Logger.captions.notice("Meeting captions found the screen unlocked without its note")
                    self.screenLockChanged(false)
                    return
                }
            }
        }
    }

    /// Returns once nothing holds the microphone back, looking every
    /// `pauseCheckInterval`, or once the task is cancelled.
    private func waitWhileMicrophonePaused() async {
        while pausesMicrophone() != .notPaused, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Self.pauseCheckInterval))
        }
    }

    /// Asks for the local model once per meeting, when the display mode translates.
    private func wantModelIfTranslating() {
        guard displayMode.translates, !wantsModel else { return }
        wantsModel = true
        started()
    }

    private func logStarted() {
        let target = CaptionTarget.effective(engines.target(), for: engines.language())
        // How long the start took tells a start that waited, as for the permission
        // prompt, from audio that comes late.
        Logger.captions.notice("Meeting captions started, listening to \(self.source.rawValue, privacy: .public), showing \(self.displayMode.rawValue, privacy: .public), into \(target.logName, privacy: .public), after \(self.captureStarted.duration(to: .now), privacy: .public)")
    }

    /// Samples from the capture, on the main actor. Internal for tests.
    func receive(_ samples: [Float], run: Int? = nil) {
        guard isOn, run == nil || run == self.run, let pipeline else { return }
        if capturing == .microphone {
            noteMicrophoneAudio(samples)
            guard admitsMicrophoneAudio(samples, into: pipeline) else { return }
        } else {
            noteSystemAudio(samples)
        }
        pipeline.feed(samples)
    }

    /// What the Mac plays: the first audio and the first sound, and samples of only zeros
    /// that suggest the permission.
    private func noteSystemAudio(_ samples: [Float]) {
        if runState.receivedSeconds == 0, !samples.isEmpty {
            Logger.captions.notice("Meeting captions got the first audio \(self.captureStarted.duration(to: .now), privacy: .public) after they started listening")
            // Something plays now, so the window no longer says that nothing does. A
            // suggestion of the permission stays until the first sound, as with zeros.
            if silence == .noAudio {
                silence = nil
            }
        }
        let seconds = Double(samples.count) / Double(RecordingLimits.sampleRate)
        runState.receivedSeconds += seconds
        meeting.receivedSeconds += seconds
        if samples.contains(where: { $0 != 0 }) {
            meeting.soundSeconds += seconds
            if !runState.heardSound {
                runState.heardSound = true
                silence = nil
                Logger.captions.notice("Meeting captions got the first sound \(self.captureStarted.duration(to: .now), privacy: .public) after they started listening")
            }
        } else if !runState.heardSound, runState.receivedSeconds >= silenceHint {
            suggestPermission(after: silenceHint)
        }
    }

    /// The microphone: whether it gives sound, as dictation tells it, see Silence. Also
    /// while a pause leaves its audio out, so the window still knows the device works.
    /// None since the start for `silenceHint`, or none for `microphoneQuietLimit` after
    /// some, says so in the window, and the first sound takes the note away.
    private func noteMicrophoneAudio(_ samples: [Float]) {
        if runState.receivedSeconds == 0, !samples.isEmpty {
            Logger.captions.notice("Meeting captions got the first audio of the microphone \(self.captureStarted.duration(to: .now), privacy: .public) after they started listening")
        }
        let seconds = Double(samples.count) / Double(RecordingLimits.sampleRate)
        runState.receivedSeconds += seconds
        meeting.receivedSeconds += seconds
        guard Silence.isSilent(samples) else {
            meeting.soundSeconds += seconds
            runState.quietSeconds = 0
            if !runState.heardSound {
                runState.heardSound = true
                Logger.captions.notice("Meeting captions got the first sound of the microphone \(self.captureStarted.duration(to: .now), privacy: .public) after they started listening")
            }
            if case .microphoneSilent = silence {
                silence = nil
            }
            return
        }
        runState.quietSeconds += seconds
        if runState.quietSeconds >= (runState.heardSound ? microphoneQuietLimit : silenceHint) {
            sayMicrophoneSilent(after: runState.quietSeconds)
        }
    }

    /// Whether the microphone's samples go into the captions now, see MicrophonePause.
    /// What a pause leaves out is gone at once, and so is what arrives within
    /// `microphoneHold` after it. The sentence that was open ends before the next samples
    /// go in, so what was said before a dictation never joins what is said after it, and
    /// the cut never starts a model call during the wait of a key. What a key that waits
    /// heard goes in, in order, when its press is dropped.
    private func admitsMicrophoneAudio(_ samples: [Float], into pipeline: CaptionPipeline) -> Bool {
        let seconds = Double(samples.count) / Double(RecordingLimits.sampleRate)
        let now = ContinuousClock.now
        let holding = runState.holdUntil.map { now < $0 } ?? false
        switch pausesMicrophone() {
        case .arming:
            guard !runState.paused, !holding else {
                meeting.leftOutSeconds += seconds
                return false
            }
            runState.armingAudio.append(samples)
            var kept = runState.armingAudio.reduce(0) { $0 + $1.count }
            while Double(kept) / Double(RecordingLimits.sampleRate) > Self.armingLimit, !runState.armingAudio.isEmpty {
                let oldest = runState.armingAudio.removeFirst()
                kept -= oldest.count
                meeting.leftOutSeconds += Double(oldest.count) / Double(RecordingLimits.sampleRate)
            }
            return false
        case .paused:
            if !runState.paused {
                runState.paused = true
                meeting.pauses += 1
            }
            runState.holdUntil = nil
            runState.endsSentence = true
            meeting.leftOutSeconds += seconds + runState.heldSeconds
            runState.armingAudio = []
            return false
        case .notPaused:
            if runState.paused {
                runState.paused = false
                runState.holdUntil = now + .seconds(microphoneHold)
                if microphoneHold > 0 {
                    meeting.leftOutSeconds += seconds
                    return false
                }
            }
            if holding {
                meeting.leftOutSeconds += seconds
                return false
            }
            runState.holdUntil = nil
            if runState.endsSentence {
                runState.endsSentence = false
                pipeline.endSentence()
            }
            // A press that turned out to be a shortcut. What was heard meanwhile goes in
            // first, in order.
            for held in runState.armingAudio {
                pipeline.feed(held)
            }
            runState.armingAudio = []
            return true
        }
    }

    /// Starts the clock of `silenceHint` for the microphone: when no sound came by then,
    /// not even quiet samples, the window says so.
    private func startMicrophoneSilenceCheck(run current: Int) {
        self.runState.silenceCheck = Task { [weak self, silenceHint] in
            try? await Task.sleep(for: .seconds(silenceHint))
            guard !Task.isCancelled, let self, self.isOn, self.run == current, !self.runState.heardSound else { return }
            self.sayMicrophoneSilent(after: silenceHint)
        }
    }

    /// The microphone gave no sound for `seconds`, so the window explains it, naming the
    /// device, or the closed lid for the built in microphone.
    private func sayMicrophoneSilent(after seconds: Double) {
        if case .microphoneSilent(let situation) = silence, situation.input == microphoneInUse { return }
        let first = silence == nil
        silence = .microphoneSilent(MicrophoneSituation(lidClosed: microphone.lidClosed(), input: microphoneInUse))
        guard first else { return }
        Logger.captions.notice("Meeting captions got no sound from the microphone for \(seconds, format: .fixed(precision: 1), privacy: .public) s, with \(self.runState.receivedSeconds, format: .fixed(precision: 1), privacy: .public) s of audio")
    }

    /// One check of what plays while no samples came this run: at `silenceHint`, and every
    /// `playCheckInterval` while the window says that nothing plays. Returns the seconds
    /// until the next check, or nil when none is needed anymore.
    private func checkSilence(run current: Int) async -> Double? {
        guard waitsForAudio(run: current) else { return nil }
        let plays = await somethingPlays()
        guard !Task.isCancelled, waitsForAudio(run: current) else { return nil }
        if plays == false {
            self.runState.mayPlay = false
            if silence == nil {
                sayNothingPlays()
            }
            return playCheckInterval
        }
        // An app plays, or Core Audio cannot tell. At `silenceHint` that suggests the
        // permission at once, as samples of only zeros do. Once the window said that
        // nothing plays, the tap's auto start gets until the next check to deliver audio.
        if silence == .noAudio, !self.runState.mayPlay {
            self.runState.mayPlay = true
            if plays == true {
                Logger.captions.notice("Meeting captions found an app playing \(self.captureStarted.duration(to: .now), privacy: .public) after they started listening, with no audio yet")
            }
            return playCheckInterval
        }
        suggestPermission(after: silence == nil ? silenceHint : captureStarted.duration(to: .now) / .seconds(1))
        return nil
    }

    /// Whether this run of what the Mac plays still got no samples at all, with no note
    /// or the note that nothing plays in the window.
    private func waitsForAudio(run current: Int) -> Bool {
        isOn && current == run && capturing == .systemAudio && self.runState.receivedSeconds == 0 && silence != .noSound
    }

    /// Asks on `playQueue` whether an app plays, see SystemAudioSource.somethingPlays. Nil
    /// when Core Audio cannot tell, also when it gave no answer within `playCheckLimit`.
    private func somethingPlays() async -> Bool? {
        let ask = systemAudio.somethingPlays
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
        Logger.captions.notice("Meeting captions got no sound for \(self.silenceHint, format: .fixed(precision: 1), privacy: .public) s, with \(self.runState.receivedSeconds, format: .fixed(precision: 1), privacy: .public) s of audio, and say that nothing plays")
    }

    /// No sound came for `seconds` although something may play, see SilenceKind.noSound,
    /// so the window suggests the permission.
    private func suggestPermission(after seconds: Double) {
        guard silence != .noSound else { return }
        silence = .noSound
        Logger.captions.notice("Meeting captions got no sound for \(seconds, format: .fixed(precision: 1), privacy: .public) s, with \(self.runState.receivedSeconds, format: .fixed(precision: 1), privacy: .public) s of audio, and suggest the permission")
    }

    /// The run of the latest start, for tests that feed samples like the capture does.
    var currentRun: Int {
        run
    }

    /// Seconds of the microphone's audio that a key that waits holds back now, for tests.
    var heldMicrophoneSeconds: Double {
        runState.heldSeconds
    }
}
