import AppKit
import Observation

/// Shows the recording indicator and plays the start and stop sounds, following the
/// controller's cues. Settings can turn either off.
///
/// The indicator shows a level meter while Orra listens, a spinner while it transcribes,
/// and for a few seconds the reason when a hold ends without a paste.
@Observable
final class RecordingFeedback {
    /// What the indicator shows.
    nonisolated enum Display: Equatable, Sendable {
        case listening
        case transcribing
        case message(String)
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
            guard showsIndicator != oldValue else { return }
            savePreferences()
            present(showsIndicator ? display : nil)
            updateLevelTask()
        }
    }
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
    ///   - messageDuration: How long a message stays.
    ///   - levelInterval: How often the meter reads the level.
    init(
        preferences: FeedbackPreference.Values,
        inputLevel: @escaping () -> Float,
        present: @escaping (Display?) -> Void,
        play: @escaping (Sound) -> Void,
        save: @escaping (FeedbackPreference.Values) -> Void,
        messageDuration: Duration = .seconds(4),
        levelInterval: Duration = .milliseconds(33)
    ) {
        showsIndicator = preferences.showsIndicator
        playsSounds = preferences.playsSounds
        self.inputLevel = inputLevel
        self.present = present
        self.play = play
        self.save = save
        self.messageDuration = messageDuration
        self.levelInterval = levelInterval
    }

    /// The app's feedback: the floating panel and the system's Tink and Pop sounds.
    static func live(inputLevel: @escaping () -> Float) -> RecordingFeedback {
        let panel = RecordingIndicatorPanel()
        let sounds = DictationSounds()
        let feedback = RecordingFeedback(
            preferences: FeedbackPreference.load(),
            inputLevel: inputLevel,
            present: { panel.present($0) },
            play: { sounds.play($0) },
            save: { FeedbackPreference.save($0) }
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
        if newDisplay != .listening {
            level = 0
        }
        present(showsIndicator ? newDisplay : nil)
        updateLevelTask()
    }

    /// Reads the level only while the meter is on screen.
    private func updateLevelTask() {
        guard showsIndicator, display == .listening else {
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
        save(FeedbackPreference.Values(showsIndicator: showsIndicator, playsSounds: playsSounds))
    }
}

/// Whether the recording indicator shows and the sounds play. Both are on until the user
/// turns them off in Settings.
nonisolated enum FeedbackPreference {
    struct Values: Equatable, Sendable {
        var showsIndicator = true
        var playsSounds = true
    }

    static let indicatorKey = "showsRecordingIndicator"
    static let soundsKey = "playsSounds"

    static func load(from defaults: UserDefaults = .standard) -> Values {
        Values(
            showsIndicator: defaults.object(forKey: indicatorKey) as? Bool ?? true,
            playsSounds: defaults.object(forKey: soundsKey) as? Bool ?? true
        )
    }

    static func save(_ values: Values, to defaults: UserDefaults = .standard) {
        defaults.set(values.showsIndicator, forKey: indicatorKey)
        defaults.set(values.playsSounds, forKey: soundsKey)
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
