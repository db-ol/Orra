import AppKit
import Observation

/// Shows the recording indicator and plays the start and stop sounds, following the
/// controller's cues. Settings can turn either off.
///
/// The indicator shows white bars that move with the voice while Orra listens, with how to
/// finish during a hands free dictation, a slow wave of the same bars while it transcribes,
/// and for a few seconds the reason when a hold ends without a paste. In between, while
/// Orra can dictate, a small bar at the bottom of the screen shows that it is ready, unless
/// Settings turns it off.
@Observable
final class RecordingFeedback {
    /// What the indicator shows.
    nonisolated enum Display: Equatable, Sendable {
        case listening
        /// The bars during a hands free dictation, with how to finish it.
        case handsFree(finishHint: String)
        case transcribing
        case message(String)
        /// The small bar while Orra waits. Only ever presented, never in `display`.
        case idle

        /// Whether the level meter shows.
        var showsMeter: Bool {
            switch self {
            case .listening, .handsFree: true
            case .transcribing, .message, .idle: false
            }
        }
    }

    nonisolated enum Sound: Equatable, Sendable {
        case start
        case stop
    }

    /// What the indicator shows, or nil while there is nothing to show.
    private(set) var display: Display?
    /// The microphone level for the meter, from 0 to 1, falling slowly after a peak.
    private(set) var level = 0.0
    var showsIndicator: Bool {
        didSet {
            guard showsIndicator != oldValue, !isSettingHint else { return }
            savePreferences()
            present(presented)
            updateLevelTask()
        }
    }
    var showsIdleBar: Bool {
        didSet {
            guard showsIdleBar != oldValue, !isSettingHint else { return }
            savePreferences()
            present(presented)
        }
    }
    /// Both switches above as the one choice Settings shows. Setting it saves once and
    /// updates the panel once.
    var onScreenHint: OnScreenHint {
        get { OnScreenHint(showsIndicator: showsIndicator, showsIdleBar: showsIdleBar) }
        set {
            guard newValue != onScreenHint else { return }
            isSettingHint = true
            showsIndicator = newValue.showsIndicator
            showsIdleBar = newValue.showsIdleBar
            isSettingHint = false
            savePreferences()
            present(presented)
            updateLevelTask()
        }
    }
    /// True while onScreenHint sets both switches, so they do not save one by one.
    @ObservationIgnored private var isSettingHint = false
    /// True while the pointer is over the idle bar, which then shows how to talk.
    var pointerIsOverIdleBar = false
    /// Whether a hold would dictate: the talk key is watched and the model is loaded.
    /// AppDelegate keeps it current. The idle bar shows only then, so it never says Orra
    /// is ready when it is not.
    var canDictate = false {
        didSet {
            guard canDictate != oldValue else { return }
            present(presented)
        }
    }

    /// What the panel shows: the indicator, or the idle bar when the indicator has nothing
    /// to show and Orra can dictate.
    var presented: Display? {
        (showsIndicator ? display : nil) ?? (showsIdleBar && canDictate ? .idle : nil)
    }

    /// The hint the idle bar shows, such as "Hold right Control to talk".
    @ObservationIgnored let holdHint: () -> String
    var playsSounds: Bool {
        didSet {
            guard playsSounds != oldValue else { return }
            savePreferences()
        }
    }

    @ObservationIgnored private let inputLevel: () -> Float
    @ObservationIgnored private let present: (Display?) -> Void
    @ObservationIgnored private let play: (Sound) -> Void
    @ObservationIgnored private let save: (FeedbackPreference.Values) -> Void
    @ObservationIgnored private let messageDuration: Duration
    @ObservationIgnored private let levelInterval: Duration
    @ObservationIgnored private var levelTask: Task<Void, Never>?
    @ObservationIgnored private var hideTask: Task<Void, Never>?

    /// - Parameters:
    ///   - preferences: Whether the indicator shows and the sounds play, as saved.
    ///   - inputLevel: The peak of the latest audio while recording. Read about 30 times a
    ///     second while the indicator listens.
    ///   - present: Shows the indicator, or hides it for nil. Tests pass fakes, so they
    ///     never open a window.
    ///   - play: Plays a sound. Tests pass fakes.
    ///   - save: Saves the preferences after a change.
    ///   - holdHint: How to talk, for the idle bar.
    ///   - messageDuration: How long a message stays.
    ///   - levelInterval: How often the meter reads the level.
    init(
        preferences: FeedbackPreference.Values,
        inputLevel: @escaping () -> Float,
        present: @escaping (Display?) -> Void,
        play: @escaping (Sound) -> Void,
        save: @escaping (FeedbackPreference.Values) -> Void,
        holdHint: @escaping () -> String = { "" },
        messageDuration: Duration = .seconds(4),
        levelInterval: Duration = .milliseconds(33)
    ) {
        showsIndicator = preferences.showsIndicator
        playsSounds = preferences.playsSounds
        showsIdleBar = preferences.showsIdleBar
        self.inputLevel = inputLevel
        self.holdHint = holdHint
        self.present = present
        self.play = play
        self.save = save
        self.messageDuration = messageDuration
        self.levelInterval = levelInterval
    }

    /// The app's feedback: the floating panel and the system's Tink and Pop sounds.
    static func live(inputLevel: @escaping () -> Float, holdHint: @escaping () -> String) -> RecordingFeedback {
        let panel = RecordingIndicatorPanel()
        let sounds = DictationSounds()
        let feedback = RecordingFeedback(
            preferences: FeedbackPreference.load(),
            inputLevel: inputLevel,
            present: { panel.present($0) },
            play: { sounds.play($0) },
            save: { FeedbackPreference.save($0) },
            holdHint: holdHint
        )
        panel.feedback = feedback
        panel.prepare()
        return feedback
    }

    func handle(_ cue: DictationCue) {
        switch cue {
        case .listening:
            if playsSounds {
                play(.start)
            }
            show(.listening)
        case .handsFree(let hint):
            // A hold that turned hands free has played the start sound already.
            if playsSounds, display?.showsMeter != true {
                play(.start)
            }
            show(.handsFree(finishHint: hint))
        case .transcribing:
            show(.transcribing)
        case .recordingStopped:
            if playsSounds {
                play(.stop)
            }
        case .finished(let message?):
            show(.message(message))
            let shown = display
            hideTask = Task { [weak self, messageDuration] in
                try? await Task.sleep(for: messageDuration)
                guard !Task.isCancelled, let self, display == shown else { return }
                show(nil)
            }
        case .finished(nil):
            show(nil)
        }
    }

    /// Maps a peak to the meter, from -50 dB at the bottom to -10 dB at the top. Speech
    /// into a Mac's microphone peaks between about -35 and -10 dB.
    nonisolated static func meterLevel(peak: Float) -> Double {
        guard peak > 0 else { return 0 }
        let decibels = 20 * log10(Double(peak))
        return min(max((decibels + 50) / 40, 0), 1)
    }

    private func show(_ newDisplay: Display?) {
        hideTask?.cancel()
        hideTask = nil
        display = newDisplay
        if newDisplay?.showsMeter != true {
            level = 0
        }
        present(presented)
        updateLevelTask()
    }

    /// Reads the level only while the meter is on screen.
    private func updateLevelTask() {
        guard showsIndicator, display?.showsMeter == true else {
            levelTask?.cancel()
            levelTask = nil
            return
        }
        guard levelTask == nil else { return }
        levelTask = Task { [weak self, levelInterval] in
            while !Task.isCancelled, self?.readLevel() == true {
                try? await Task.sleep(for: levelInterval)
            }
        }
    }

    /// Moves the meter toward the latest peak. It rises at once and falls slowly, so it
    /// does not flicker.
    private func readLevel() -> Bool {
        let target = Self.meterLevel(peak: inputLevel())
        level = target >= level ? target : max(target, level * 0.85)
        return true
    }

    private func savePreferences() {
        save(FeedbackPreference.Values(showsIndicator: showsIndicator, playsSounds: playsSounds, showsIdleBar: showsIdleBar))
    }
}

/// Whether the recording indicator shows, the sounds play and the idle bar shows. All are
/// on until the user turns them off in Settings.
nonisolated enum FeedbackPreference {
    struct Values: Equatable, Sendable {
        var showsIndicator = true
        var playsSounds = true
        var showsIdleBar = true
    }

    static let indicatorKey = "showsRecordingIndicator"
    static let soundsKey = "playsSounds"
    static let idleBarKey = "showsIdleBar"

    static func load(from defaults: UserDefaults = .standard) -> Values {
        Values(
            showsIndicator: defaults.object(forKey: indicatorKey) as? Bool ?? true,
            playsSounds: defaults.object(forKey: soundsKey) as? Bool ?? true,
            showsIdleBar: defaults.object(forKey: idleBarKey) as? Bool ?? true
        )
    }

    static func save(_ values: Values, to defaults: UserDefaults = .standard) {
        defaults.set(values.showsIndicator, forKey: indicatorKey)
        defaults.set(values.playsSounds, forKey: soundsKey)
        defaults.set(values.showsIdleBar, forKey: idleBarKey)
    }
}

/// What Settings offers as the on screen hint. It is saved as the two switches of earlier
/// versions, the recording indicator and the idle bar, so a saved choice keeps meaning
/// what it did and nothing is rewritten on disk.
nonisolated enum OnScreenHint: String, CaseIterable, Identifiable, Sendable {
    /// The indicator while dictating, and the idle bar while Orra is ready.
    case always
    /// The indicator only.
    case whileDictating
    /// Neither. The menu bar icon then shows listening and transcribing.
    case off
    /// The idle bar only. Settings offers it only to someone who had turned the indicator
    /// off and kept the bar, so their choice still shows.
    case whileReady

    var id: String { rawValue }

    init(showsIndicator: Bool, showsIdleBar: Bool) {
        switch (showsIndicator, showsIdleBar) {
        case (true, true): self = .always
        case (true, false): self = .whileDictating
        case (false, false): self = .off
        case (false, true): self = .whileReady
        }
    }

    init(_ values: FeedbackPreference.Values) {
        self.init(showsIndicator: values.showsIndicator, showsIdleBar: values.showsIdleBar)
    }

    var showsIndicator: Bool {
        self == .always || self == .whileDictating
    }

    var showsIdleBar: Bool {
        self == .always || self == .whileReady
    }

    /// The choices in Settings, in order. Only the bar while ready is left out, unless it
    /// is the current choice.
    static func choices(current: OnScreenHint) -> [OnScreenHint] {
        current == .whileReady ? allCases : [.always, .whileDictating, .off]
    }
}

/// The start and stop sounds, from the system's sound folder. Loaded once, so playing
/// reads no file. NSSound plays without blocking.
final class DictationSounds {
    private let start = NSSound(named: "Tink")
    private let stop = NSSound(named: "Pop")

    init() {
        start?.volume = 0.5
        stop?.volume = 0.5
    }

    func play(_ sound: RecordingFeedback.Sound) {
        let player = sound == .start ? start : stop
        // A sound that is still playing would ignore play().
        player?.stop()
        player?.play()
    }
}
