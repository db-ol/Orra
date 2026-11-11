import Foundation
import os

/// What the recording indicator shows of a dictation while the user speaks, see
/// LiveDictation: the speech model's text of the pieces that ended, and the text of the
/// sentence still being heard. In memory only, never logged, saved or pasted.
nonisolated struct LiveText: Equatable, Sendable {
    /// The pieces that ended, joined as RecordingPieces joins the pieces of a recording.
    var finished = ""
    /// The sentence still being heard, which the text of its piece replaces once it ends.
    var interim: String?

    var isEmpty: Bool {
        finished.isEmpty && (interim?.isEmpty ?? true)
    }

    /// The interim text as it follows the finished text, with a space before it where the
    /// two need one, see `RecordingPieces.joined(_:)`.
    var interimAfterFinished: String {
        guard let interim, !interim.isEmpty else { return "" }
        return String(RecordingPieces.joined([finished, interim]).dropFirst(finished.count))
    }

    /// The end of the text, at most `limit` characters with the interim text kept first,
    /// for a box that shows only its last lines, so text that would not show is not laid
    /// out at all.
    func tail(_ limit: Int) -> LiveText {
        let interim = interim.map { String($0.suffix(limit)) }
        let room = max(limit - (interim?.count ?? 0), 0)
        return LiveText(finished: String(finished.suffix(room)), interim: interim)
    }
}

/// Whether the recording indicator shows the speech model's text while the user speaks, see
/// LiveDictation. Off until the user turns it on in Settings.
nonisolated enum LiveTextPreference {
    static let defaultsKey = "showsLiveText"

    static func load(from defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: defaultsKey, default: false)
    }

    static func save(_ on: Bool, to defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: defaultsKey)
    }
}

/// What a dictation gives the speech model besides its audio, see
/// `Transcription.transcribe(_:vocabulary:holdsScreenNames:audioSeconds:takingDigits:language:)`.
/// Pieces joined during the hold, see `LiveDictation.PiecePass`, are pasted only when the
/// release would give the same.
nonisolated struct DictationContext: Equatable, Sendable {
    /// The terms for the model, the names on screen first, see Vocabulary.forModel.
    var vocabulary: [String]
    var holdsScreenNames: Bool
    var takingDigits: Bool
    var language: DictationLanguage
}

/// The audio of one hold at 16 kHz and the pieces DictationPieces cuts it into, off the main
/// actor, so converting and cutting never hold up the keyboard tap, see LiveDictation.
actor LiveAudio {
    /// What the segmenter knows after the samples taken so far.
    nonisolated struct Update: Sendable {
        /// The pieces these samples finished, in order.
        var pieces: [DictationPieces.Piece] = []
        /// The sentence being heard, see `DictationPieces.openSentence`.
        var open: Range<Int>?
        var openSeconds = 0.0
        var openSilence = 0.0
        var isInSpeech = false
        /// Where the latest piece ends.
        var lastCut = 0
    }

    private var pieces: DictationPieces
    private var resampler: LiveResampler?
    /// The samples at 16 kHz from `base` on. Those before it were let go.
    private var samples: [Float] = []
    private var base = 0

    init(settings: CaptionSegmenter.Settings = DictationPieces.settings) {
        pieces = DictationPieces(settings: settings)
    }

    /// Takes the next samples of the recording at the device's rate and returns what the
    /// segmenter knows now. Nil for a rate the converter does not take, and for one other
    /// than the rate of the samples before.
    func take(_ recorded: [Float], sampleRate: Double) -> Update? {
        if resampler == nil {
            resampler = LiveResampler(sampleRate: sampleRate)
        }
        guard let resampler, resampler.sampleRate == sampleRate else { return nil }
        let converted = resampler.convert(recorded)
        samples.append(contentsOf: converted)
        let ended = pieces.append(converted)
        return Update(
            pieces: ended,
            open: pieces.openSentence,
            openSeconds: pieces.openSeconds,
            openSilence: pieces.openSilenceSeconds,
            isInSpeech: pieces.isInSpeech,
            lastCut: pieces.lastCut
        )
    }

    /// The samples of `range` that are still kept.
    func samples(in range: Range<Int>) -> [Float] {
        let from = max(range.lowerBound - base, 0)
        let to = min(range.upperBound - base, samples.count)
        return from < to ? Array(samples[from..<to]) : []
    }

    /// The samples a pass for the text on screen reads for `sentence`, see
    /// `DictationPieces.shownRange(for:after:leadIn:)`.
    func samples(forSentence sentence: Range<Int>, after cut: Int, leadIn: Double) -> [Float] {
        samples(in: pieces.shownRange(for: sentence, after: cut, leadIn: leadIn))
    }

    /// Lets go of the samples before `index`, which no pass reads any more. In steps of at
    /// least 10 s, so the kept samples are not moved at every piece.
    func forget(before index: Int) {
        let dropped = min(max(index - base, 0), samples.count)
        guard dropped >= 10 * RecordingLimits.sampleRate else { return }
        samples.removeFirst(dropped)
        base += dropped
    }
}

/// Shows the speech model's text in the recording indicator while the user speaks, for one
/// hold, while Show text while you speak is on. The paste does not change: it comes from
/// the pass over the whole recording after the release, as without this.
///
/// Every `readInterval` it reads what the microphone recorded since its last read, by
/// index, so a reader left from an earlier hold never takes samples from a newer one.
/// LiveAudio converts it to 16 kHz and cuts it at pauses, see DictationPieces. Each piece
/// that ends is transcribed, and about once a second, while the sentence being heard grows
/// and no piece waits, so is that sentence, for interim text, which the text of its piece
/// replaces once it ends. One pass at a time, awaited in this task, so a cancel reaches
/// the model call, which stops at its next check, see `Qwen3Engine.transcribe`. A pass has
/// no vocabulary, no names and no language, so no echo, list, number or language pass
/// follows it, and a text in a third language is not shown. It reads one sentence with
/// what came at most `leadIn` before it, never more than 12.2 s, so a pass never grows
/// with a long pause, and neither does the work at its start that a cancel cannot cut.
///
/// The interim interval grows to twice the last interim pass, and an interim pass waits
/// while the passes of this hold used more than `busyShare` of the last `busyWindow`, so a
/// slow Mac shows the text later instead of keeping the model busy. No pass starts while
/// the cleanup model loads or reads its prompts, see `CleanupModel.isPreparing`, so the
/// load the press started is not slowed.
///
/// Its passes are the dictation's own calls on the speech model. They take the model gate
/// shared, as the pass after the release does, inside the reservation of the press, and
/// never through EngineTurns. The release cancels the pass under way, see `release()`,
/// and the pass after it starts once that one stopped, see `ended()`. A cancel ends the
/// reservation without waiting, so the pass under way may run on to its next check after
/// it, see `cancel()`.
///
/// Option B, only for the measurements: with a `PiecePass`, each piece is transcribed the
/// way a piece of a long recording is, with the vocabulary and the guards, and the release
/// pastes those texts with the rest of the recording after the last of them, see
/// JoinedPieces.
///
/// Logs only the type of an error of a pass. The controller logs its counts and times,
/// never text.
final class LiveDictation {
    nonisolated struct Settings: Sendable {
        /// Where pieces are cut, see DictationPieces.
        var pieces = DictationPieces.settings
        /// How often the recording is read: the engine's buffer of about 100 ms.
        var readInterval: Duration = .milliseconds(100)
        /// How often `allowed` is read: at the first read and then at most this often,
        /// since the app's answer asks the window server about secure input on the main
        /// thread, where the keyboard tap runs.
        var rulesInterval: Duration = .milliseconds(500)
        /// Seconds of new audio in the sentence being heard between two interim passes, at
        /// least, as `CaptionPipeline.defaultInterimInterval` for captions.
        var interimInterval = 1.0
        /// A sentence silent this long at its end gets no interim pass, since its piece is
        /// likely to end, as `CaptionPipeline.interimPauseLimit` for captions.
        var interimPauseLimit = 0.1
        /// The share of `busyWindow` the passes of this hold may use before an interim pass
        /// waits.
        var busyShare = 0.3
        var busyWindow: Duration = .seconds(10)
        /// Seconds before a sentence that go with it into its pass.
        var leadIn = 1.0
        /// Failed passes after which the hold starts no more.
        var failureLimit = 3
    }

    /// What one hold did, for the log. Counts and times only.
    nonisolated struct Counts: Equatable, Sendable {
        var pieces = 0
        var piecePasses = 0
        var interimPasses = 0
        var failedPasses = 0
        var longestPass: Duration = .zero
        /// The time the passes took in all.
        var busy: Duration = .zero

        var summary: String {
            "\(pieces) pieces, \(piecePasses) piece passes, \(interimPasses) interim passes, \(failedPasses) failed, longest pass \(DictationTimings.milliseconds(longestPass)) ms, passes \(DictationTimings.milliseconds(busy)) ms in all"
        }
    }

    /// Option B: how a piece that ended is transcribed. `context` is read when the first
    /// piece's pass starts, and every piece of the hold gets what it read.
    struct PiecePass {
        var context: () -> DictationContext
        var transcribe: (_ samples: [Float], _ context: DictationContext) async throws -> String
    }

    /// What option B pastes from: the texts of the pieces transcribed during the hold, in
    /// order, where the last of them ends in the 16 kHz recording, and the context they had.
    nonisolated struct JoinedPieces: Equatable, Sendable {
        var pieces: [TranscribedPiece]
        var cut: Int
        var context: DictationContext
    }

    /// What the pass under way is for.
    private enum Pass {
        case piece
        case interim
    }

    /// The text on show, in memory only.
    private(set) var text = LiveText()
    private(set) var counts = Counts()

    private let read: (_ after: Int, _ recording: Int?) async -> RecordedAudio?
    private let transcribe: (_ samples: [Float]) async throws -> String
    private let language: DictationLanguage
    private let settings: Settings
    private let allowed: () -> Bool
    private let mayStartPass: () -> Bool
    private let piecePass: PiecePass?
    private let publish: (LiveText?) -> Void
    private let audio: LiveAudio
    private var task: Task<Void, Never>?
    /// Set by the release and by a cancel. Nothing new starts or shows after it.
    private var isOver = false
    private var running: Pass?
    /// The pieces that ended and wait for their pass, with their numbers, oldest first.
    private var waiting: [(piece: DictationPieces.Piece, number: Int)] = []
    /// Pieces cut so far, which is the number of the sentence being heard.
    private var cutCount = 0
    /// What the segmenter knew after the latest read.
    private var latest = LiveAudio.Update()
    /// The sentence the latest interim pass was for, and its length then.
    private var lastInterim: (number: Int, seconds: Double)?
    /// How long the latest interim pass took.
    private var lastInterimTook: Duration = .zero
    /// The sentence whose interim text shows.
    private var interimNumber: Int?
    /// When the passes of the last `busyWindow` ran.
    private var passes: [(start: ContinuousClock.Instant, end: ContinuousClock.Instant)] = []
    /// Option B: the context the pieces got, their texts, where the last ends, and whether a
    /// piece failed or the text stopped, either of which makes the release paste as without B.
    private var context: DictationContext?
    private var joined: [TranscribedPiece] = []
    private var joinedCut = 0
    private var joinFailed = false

    /// - Parameters:
    ///   - read: The samples the recording in progress holds past an index, see
    ///     `AudioCapture.recorded`.
    ///   - transcribe: One pass of the speech model without context or language that stops
    ///     when its task is cancelled, see `Transcription.stoppablePass(_:)`.
    ///   - language: The dictation language, for the language check and the characters.
    ///   - allowed: Whether the text may still show, read before the first read of the
    ///     recording and then every `Settings.rulesInterval`. Once false, the text goes for
    ///     the rest of the hold.
    ///   - mayStartPass: Whether a pass may start now, false while the cleanup model loads.
    ///   - piecePass: Option B, nil for the text on screen only.
    ///   - publish: Shows the text, or hides it for nil.
    init(
        read: @escaping (_ after: Int, _ recording: Int?) async -> RecordedAudio?,
        transcribe: @escaping (_ samples: [Float]) async throws -> String,
        language: DictationLanguage,
        settings: Settings = Settings(),
        allowed: @escaping () -> Bool = { true },
        mayStartPass: @escaping () -> Bool = { true },
        piecePass: PiecePass? = nil,
        publish: @escaping (LiveText?) -> Void
    ) {
        self.read = read
        self.transcribe = transcribe
        self.language = language
        self.settings = settings
        self.allowed = allowed
        self.mayStartPass = mayStartPass
        self.piecePass = piecePass
        self.publish = publish
        audio = LiveAudio(settings: settings.pieces)
    }

    /// Starts reading once `capture`, the start of the microphone, returned, from the first
    /// sample on, so what a key that waited recorded counts too. Never delays the start.
    func start(after capture: Task<ContinuousClock.Instant?, Never>?) {
        task = Task { [weak self] in
            guard await capture?.value != nil else { return }
            await self?.run()
        }
    }

    /// The release of the key. Nothing new starts or shows, and the text stays as it is.
    /// The pass under way is cancelled, except in option B a piece's pass, whose text the
    /// paste needs.
    func release() {
        isOver = true
        if piecePass == nil || running != .piece {
            task?.cancel()
        }
    }

    /// Waits until the pass under way at the release ended, which a cancel makes quick,
    /// and returns what option B pastes from. Nil without option B, and when B pastes as
    /// without it: no piece was transcribed, one failed, or the text stopped during the hold.
    func ended() async -> JoinedPieces? {
        await task?.value
        task = nil
        guard piecePass != nil, !joinFailed, let context, !joined.isEmpty else { return nil }
        return JoinedPieces(pieces: joined, cut: joinedCut, context: context)
    }

    /// The hold ended without a paste: the pass under way is cancelled and nothing more
    /// shows. The caller hides the text and does not wait, so the pass may hold the gate
    /// shared until its next check, which a voice request then waits for. It never waits
    /// for a voice request itself.
    func cancel() {
        isOver = true
        task?.cancel()
    }

    private func run() async {
        var received = 0
        var recording: Int?
        var rulesRead: ContinuousClock.Instant?
        while !Task.isCancelled, !isOver {
            if rulesRead.map({ $0.duration(to: .now) >= settings.rulesInterval }) ?? true {
                guard allowed() else {
                    stopShowing()
                    return
                }
                rulesRead = .now
            }
            // Nil once the recording is over, or when a newer one is in progress.
            guard let recorded = await read(received, recording), recording == nil || recorded.recording == recording else { return }
            guard !Task.isCancelled, !isOver else { return }
            recording = recorded.recording
            received += recorded.samples.count
            if !recorded.samples.isEmpty {
                let update = await audio.take(recorded.samples, sampleRate: recorded.sampleRate)
                guard !Task.isCancelled, !isOver else { return }
                // A rate the converter does not take.
                guard let update else {
                    stopShowing()
                    return
                }
                take(update)
            }
            if let next = waiting.first, mayStartPass() {
                await transcribe(next.piece, number: next.number)
            } else if mayStartPass(), takeInterimTurn() {
                await interim()
            } else {
                try? await Task.sleep(for: settings.readInterval)
            }
            guard counts.failedPasses < settings.failureLimit else { return }
        }
    }

    /// The text stops for the rest of the hold, as when it was off at the press, and
    /// option B pastes as without it.
    private func stopShowing() {
        isOver = true
        joinFailed = true
        text = LiveText()
        publish(nil)
    }

    private func take(_ update: LiveAudio.Update) {
        for piece in update.pieces {
            waiting.append((piece, cutCount))
            cutCount += 1
            counts.pieces += 1
        }
        latest = update
    }

    /// Whether the sentence being heard gets an interim pass now: it grew by the interval
    /// since its last one, no piece waits, it is not pausing, and the passes of this hold
    /// left the model free enough lately.
    private func takeInterimTurn(now: ContinuousClock.Instant = .now) -> Bool {
        guard waiting.isEmpty, latest.open != nil, latest.isInSpeech, latest.openSilence < settings.interimPauseLimit else { return false }
        let heard = lastInterim.flatMap { $0.number == cutCount ? $0.seconds : nil } ?? 0
        let interval = max(settings.interimInterval, Self.seconds(lastInterimTook) * 2)
        guard latest.openSeconds >= heard + interval else { return false }
        return busy(over: settings.busyWindow, now: now) <= settings.busyWindow * settings.busyShare
    }

    /// How long the passes of this hold ran within the last `window`.
    private func busy(over window: Duration, now: ContinuousClock.Instant) -> Duration {
        let from = now - window
        passes.removeAll { $0.end < from }
        return passes.reduce(.zero) { total, pass in total + max(pass.start, from).duration(to: pass.end) }
    }

    /// Runs one pass and notes how long it took.
    private func timed<T>(_ work: () async throws -> T) async throws -> T {
        let started = ContinuousClock.now
        defer {
            let ended = ContinuousClock.now
            let took = started.duration(to: ended)
            passes.append((started, ended))
            counts.busy += took
            counts.longestPass = max(counts.longestPass, took)
        }
        return try await work()
    }

    private func transcribe(_ piece: DictationPieces.Piece, number: Int) async {
        running = .piece
        defer { running = nil }
        let shown: String?
        do {
            if let piecePass {
                let samples = await audio.samples(in: piece.range)
                let seconds = Double(samples.count) / Double(RecordingLimits.sampleRate)
                let context = context ?? piecePass.context()
                self.context = context
                let raw = try await timed { try await piecePass.transcribe(samples, context) }
                counts.piecePasses += 1
                joined.append(TranscribedPiece(text: raw, seconds: seconds))
                joinedCut = piece.range.upperBound
                shown = RecordingPieces.transcript(of: [TranscribedPiece(text: raw, seconds: seconds)], simplifying: language.simplifiesCharacters).text
            } else {
                let samples = await audio.samples(forSentence: piece.sentence, after: piece.range.lowerBound, leadIn: settings.leadIn)
                // The gate lets a cancelled call in when it can enter at once, so a release
                // during the read must start no pass here.
                guard !Task.isCancelled, !isOver else { return }
                let seconds = Double(samples.count) / Double(RecordingLimits.sampleRate)
                let raw = try await timed { try await transcribe(samples) }
                counts.piecePasses += 1
                // A pass that ended after the release shows nothing, and the paste waits for
                // this task, so nothing more runs for it.
                guard !Task.isCancelled, !isOver else { return }
                shown = await Self.shownText(raw, seconds: seconds, language: language)
            }
        } catch is CancellationError where Task.isCancelled || isOver {
            return
        } catch {
            counts.failedPasses += 1
            joinFailed = true
            Logger.pushToTalk.error("A pass for the text while speaking failed with \(String(reflecting: type(of: error)), privacy: .public)")
            shown = nil
        }
        waiting.removeFirst()
        guard !Task.isCancelled, !isOver else { return }
        await audio.forget(before: waiting.first?.piece.range.lowerBound ?? latest.lastCut)
        guard !Task.isCancelled, !isOver else { return }
        // The interim text of this sentence goes, whether its piece gave text or not.
        var changed = false
        if interimNumber == number {
            text.interim = nil
            interimNumber = nil
            changed = true
        }
        if let shown, !shown.isEmpty {
            text.finished = RecordingPieces.joined([text.finished, shown])
            changed = true
        }
        if changed {
            publish(text)
        }
    }

    private func interim() async {
        guard let open = latest.open else { return }
        running = .interim
        defer { running = nil }
        let number = cutCount
        let heard = latest.openSeconds
        let samples = await audio.samples(forSentence: open, after: latest.lastCut, leadIn: settings.leadIn)
        // As for a piece, a release during the read starts no pass.
        guard !Task.isCancelled, !isOver else { return }
        let seconds = Double(samples.count) / Double(RecordingLimits.sampleRate)
        let started = ContinuousClock.now
        let raw: String
        do {
            raw = try await timed { try await transcribe(samples) }
        } catch is CancellationError where Task.isCancelled || isOver {
            return
        } catch {
            counts.failedPasses += 1
            Logger.pushToTalk.error("An interim pass for the text while speaking failed with \(String(reflecting: type(of: error)), privacy: .public)")
            return
        }
        counts.interimPasses += 1
        lastInterim = (number, heard)
        lastInterimTook = started.duration(to: .now)
        // A text in a third language, or none, leaves the interim text that shows.
        guard !Task.isCancelled, !isOver, let shown = await Self.shownText(raw, seconds: seconds, language: language) else { return }
        // A cut of this sentence while the pass ran shows only at the next read, after this
        // returns, so the text shows until the text of its piece takes its place.
        guard !Task.isCancelled, !isOver else { return }
        text.interim = shown
        interimNumber = number
        publish(text)
    }

    /// The text a pass gives for the indicator: through TranscriptGuard, in simplified
    /// characters for a user who dictates in Chinese, and nil when it is empty or in a
    /// language the user does not dictate in. Off the main actor, since NLLanguageRecognizer
    /// may read the whole text.
    @concurrent
    nonisolated private static func shownText(_ raw: String, seconds: Double, language: DictationLanguage) async -> String? {
        let guarded = TranscriptGuard.clean(raw, audioSeconds: seconds)
        guard !guarded.isEmpty, !LanguageGuard.isForeign(guarded, for: language) else { return nil }
        return language.simplifiesCharacters ? ChineseText.simplified(guarded) : guarded
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
