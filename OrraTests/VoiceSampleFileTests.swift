import Foundation
import Testing
@testable import Orra

/// Remember my voice: the voice sample's audio on disk, in a temporary folder, never the
/// real Application Support.
@MainActor
struct VoiceSampleFileTests {
    let synthesizer = FakeSynthesizer()
    let file: VoiceSampleFile

    init() {
        file = VoiceSampleFile(folder: FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceSampleFileTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Voice", isDirectory: true))
    }

    static let threeSeconds = VoiceSample(samples: (0..<48_000).map { Float(sin(Double($0) / 7)) * 0.3 }, sampleRate: 16_000)
    static let fourSeconds = VoiceSample(samples: (0..<96_000).map { Float(cos(Double($0) / 11)) * 0.2 }, sampleRate: 24_000)

    private func makeSpeech(
        remembers: Bool,
        isOn: Bool = true,
        file: VoiceSampleFile? = nil,
        transcribeVoice: @escaping (VoiceSample) async throws -> String = { _ in "We met at noon." }
    ) -> TranslationSpeech {
        let speech = TranslationSpeech(
            engines: .only(synthesizer),
            playback: FakePlayback(),
            outputs: { [] },
            folders: { nil },
            settings: TranslationSpeech.Settings(isOn: isOn, remembersVoice: remembers),
            voiceFile: file ?? self.file,
            dictationPoll: .milliseconds(1)
        )
        speech.transcribeVoice = transcribeVoice
        return speech
    }

    /// A speech model that is not ready until the test says so.
    @MainActor
    private struct SpeechModelGate {
        let ready = AsyncStream<Void>.makeStream()
        let waited = Flag()

        func install(on speech: TranslationSpeech) {
            speech.waitForSpeechModel = { [ready, waited] in
                waited.value = true
                for await _ in ready.stream { break }
            }
        }

        /// Returns once the restore waits for the speech model.
        func untilWaiting() async throws {
            for _ in 0..<400 where !waited.value {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(waited.value)
        }

        func open() {
            ready.continuation.yield()
            ready.continuation.finish()
        }
    }

    @MainActor
    private final class Flag {
        var value = false
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: file.folder.deletingLastPathComponent())
    }

    private func saved() async throws -> VoiceSample? {
        try await file.load()
    }

    // MARK: Saving

    /// With the switch on, a sample in use is saved, its audio only: the file holds the
    /// samples and a header, and not what is said in it.
    @Test func aSampleIsSavedWhileOnWithItsAudioOnly() async throws {
        defer { cleanUp() }
        let speech = makeSpeech(remembers: true, transcribeVoice: { _ in "Secret words of the sample." })
        await speech.useVoice(Self.threeSeconds)
        await speech.waitForVoiceFile()
        #expect(try await saved() == Self.threeSeconds)
        let data = try Data(contentsOf: file.url)
        #expect(data.count == VoiceSampleFile.headerSize + Self.threeSeconds.samples.count * 4)
        #expect(data.range(of: Data("Secret".utf8)) == nil)
        #expect(speech.problem == nil)
        #expect(speech.voiceIsSaved)
        #expect(speech.voiceFileProblem == nil)
    }

    @Test func nothingIsWrittenWhileOff() async throws {
        defer { cleanUp() }
        let speech = makeSpeech(remembers: false)
        await speech.useVoice(Self.threeSeconds)
        await speech.waitForVoiceFile()
        #expect(speech.voiceSeconds == 3)
        #expect(!speech.voiceIsSaved)
        #expect(!FileManager.default.fileExists(atPath: file.folder.path))
        #expect(!FileManager.default.fileExists(atPath: file.folder.deletingLastPathComponent().path))
    }

    /// Turning the switch on saves the sample in memory at once, turning it off deletes the
    /// file at once and keeps the sample in memory. Neither changes anything else.
    @Test func turningTheSwitchOnSavesAndOffDeletes() async throws {
        defer { cleanUp() }
        var saves: [TranslationSpeech.Settings] = []
        let speech = TranslationSpeech(
            engines: .only(synthesizer),
            playback: FakePlayback(),
            outputs: { [] },
            folders: { nil },
            settings: TranslationSpeech.Settings(isOn: true),
            save: { saves.append($0) },
            voiceFile: file
        )
        speech.transcribeVoice = { _ in "We met at noon." }
        // Without a sample, turning it on writes nothing.
        speech.setRemembersVoice(true)
        await speech.waitForVoiceFile()
        #expect(!file.exists)
        speech.setRemembersVoice(false)
        await speech.useVoice(Self.threeSeconds)
        await speech.waitForVoiceFile()
        #expect(!file.exists)

        speech.setRemembersVoice(true)
        await speech.waitForVoiceFile()
        #expect(try await saved() == Self.threeSeconds)
        #expect(speech.voiceIsSaved)
        speech.setRemembersVoice(false)
        #expect(!speech.voiceIsSaved)
        await speech.waitForVoiceFile()
        #expect(!file.exists)
        #expect(!FileManager.default.fileExists(atPath: file.folder.path))
        #expect(speech.voiceSeconds == 3)
        #expect(saves.map(\.remembersVoice) == [true, false, true, false])
        #expect(saves.allSatisfy { $0.isOn && $0.alsoPastes })
    }

    @Test func removeDeletesTheFile() async throws {
        defer { cleanUp() }
        let speech = makeSpeech(remembers: true)
        await speech.useVoice(Self.threeSeconds)
        await speech.waitForVoiceFile()
        #expect(file.exists)
        speech.forgetVoice()
        #expect(!speech.voiceIsSaved)
        await speech.waitForVoiceFile()
        #expect(!file.exists)
        #expect(speech.remembersVoice)
    }

    /// While Speak translations is off, the saved sample is not read, Settings shows it as
    /// saved, and both Remove and the switch turned off delete it.
    @Test(arguments: [false, true])
    func aSavedSampleCanBeRemovedWhileSpeakTranslationsIsOff(_ turnsTheSwitchOff: Bool) async throws {
        defer { cleanUp() }
        try await file.save(Self.threeSeconds)
        var heard = 0
        let speech = makeSpeech(remembers: true, isOn: false, transcribeVoice: { _ in
            heard += 1
            return "We met at noon."
        })
        speech.restoreVoice()
        await speech.waitForVoiceRestore()
        #expect(heard == 0)
        #expect(speech.voiceSeconds == nil)
        #expect(speech.voiceIsSaved)
        #expect(file.exists)
        if turnsTheSwitchOff {
            speech.setRemembersVoice(false)
        } else {
            speech.forgetVoice()
        }
        await speech.waitForVoiceFile()
        #expect(!file.exists)
        #expect(!speech.voiceIsSaved)
        #expect(!speech.isOn)
        #expect(speech.remembersVoice == !turnsTheSwitchOff)
    }

    /// While Speak translations is off, the saved sample waits, and turning it on loads it.
    @Test func turningSpeakTranslationsOnLoadsTheSavedSample() async throws {
        defer { cleanUp() }
        try await file.save(Self.threeSeconds)
        let speech = makeSpeech(remembers: true, isOn: false)
        speech.restoreVoice()
        await speech.waitForVoiceRestore()
        #expect(speech.voiceSeconds == nil)
        speech.setOn(true)
        await speech.waitForVoiceRestore()
        #expect(speech.voiceSeconds == 3)
        #expect(speech.voiceIsSaved)
        speech.setOn(false)
        await speech.waitUntilDone()
    }

    /// A new sample takes the old one's place on disk. One the speech model hears nothing
    /// in is not used, and the old one stays on disk too.
    @Test func aNewSampleReplacesTheFile() async throws {
        defer { cleanUp() }
        var answer = "We met at noon."
        let speech = makeSpeech(remembers: true, transcribeVoice: { _ in answer })
        await speech.useVoice(Self.threeSeconds)
        await speech.useVoice(Self.fourSeconds)
        await speech.waitForVoiceFile()
        #expect(try await saved() == Self.fourSeconds)

        answer = " "
        await speech.useVoice(Self.threeSeconds)
        await speech.waitForVoiceFile()
        #expect(try await saved() == Self.fourSeconds)
        #expect(speech.voiceSeconds == 4)
        #expect(speech.voiceIsSaved)
        let names = try FileManager.default.contentsOfDirectory(atPath: file.folder.path)
        #expect(names == [VoiceSampleFile.name])
    }

    /// A save that fails says so, the row does not call the sample saved, and no older
    /// sample stays on disk.
    @Test func aSaveThatFailsSaysSo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceSampleFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // A file where the folder's parent should be, so the folder cannot be made.
        let blocked = root.appendingPathComponent("blocked", isDirectory: false)
        try Data("x".utf8).write(to: blocked)
        let failing = VoiceSampleFile(folder: blocked.appendingPathComponent("Voice", isDirectory: true))
        let speech = makeSpeech(remembers: true, file: failing)
        await speech.useVoice(Self.threeSeconds)
        await speech.waitForVoiceFile()
        #expect(speech.voiceSeconds == 3)
        #expect(!speech.voiceIsSaved)
        #expect(speech.voiceFileProblem == "Orra could not save the voice sample on this Mac.")
        #expect(!failing.exists)
        // The message stays whether Speak translations is on or off.
        speech.setOn(false)
        #expect(speech.voiceFileProblem != nil)
        speech.forgetVoice()
        #expect(speech.voiceFileProblem == nil)
        await speech.waitForVoiceFile()
        await speech.waitUntilDone()
    }

    /// The recording sheet's checkbox applies with the sample: on writes the new sample
    /// only once it is used, off deletes the file first, and nil leaves the switch.
    @Test func theSheetsCheckboxAppliesWithTheSample() async throws {
        defer { cleanUp() }
        let gate = AsyncStream<Void>.makeStream()
        let speech = makeSpeech(remembers: false, transcribeVoice: { _ in
            for await _ in gate.stream { break }
            return "We met at noon."
        })
        let first = Task { await speech.useVoice(Self.threeSeconds) }
        gate.continuation.yield()
        #expect(await first.value == .used)
        #expect(speech.voiceSeconds == 3)

        let second = Task { await speech.useVoice(Self.fourSeconds, remember: true) }
        for _ in 0..<400 where !speech.isListeningToVoice {
            try await Task.sleep(for: .milliseconds(5))
        }
        // The sample before it is never written.
        await speech.waitForVoiceFile()
        #expect(!speech.remembersVoice)
        #expect(!file.exists)
        gate.continuation.yield()
        #expect(await second.value == .used)
        await speech.waitForVoiceFile()
        #expect(speech.remembersVoice)
        #expect(try await saved() == Self.fourSeconds)

        let third = Task { await speech.useVoice(Self.threeSeconds, remember: false) }
        for _ in 0..<400 where !speech.isListeningToVoice {
            try await Task.sleep(for: .milliseconds(5))
        }
        await speech.waitForVoiceFile()
        #expect(!speech.remembersVoice)
        #expect(!file.exists)
        gate.continuation.yield()
        #expect(await third.value == .used)
        #expect(speech.voiceSeconds == 3)

        let fourth = Task { await speech.useVoice(Self.fourSeconds, remember: nil) }
        gate.continuation.yield()
        #expect(await fourth.value == .used)
        await speech.waitForVoiceFile()
        #expect(!speech.remembersVoice)
        #expect(!file.exists)
        #expect(speech.voiceSeconds == 4)
    }

    /// The switch turned on and off again in Settings while the sheet's sample is written
    /// down ends where it started, and still wins over the sheet's checkbox.
    @Test func aSwitchTurnedOnAndOffMeanwhileWinsOverTheCheckbox() async throws {
        defer { cleanUp() }
        let gate = AsyncStream<Void>.makeStream()
        let speech = makeSpeech(remembers: false, transcribeVoice: { _ in
            for await _ in gate.stream { break }
            return "We met at noon."
        })
        let use = Task { await speech.useVoice(Self.fourSeconds, remember: true) }
        for _ in 0..<400 where !speech.isListeningToVoice {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(speech.isListeningToVoice)
        speech.setRemembersVoice(true)
        speech.setRemembersVoice(false)
        gate.continuation.yield()
        #expect(await use.value == .used)
        await speech.waitForVoiceFile()
        #expect(!speech.remembersVoice)
        #expect(!file.exists)
        #expect(speech.voiceSeconds == 4)
    }

    @Test func theFolderAndFileAreForTheUserAloneAndOutOfBackups() async throws {
        defer { cleanUp() }
        let speech = makeSpeech(remembers: true)
        await speech.useVoice(Self.threeSeconds)
        await speech.useVoice(Self.fourSeconds)
        await speech.waitForVoiceFile()
        let fileManager = FileManager.default
        let folder = try fileManager.attributesOfItem(atPath: file.folder.path)
        let saved = try fileManager.attributesOfItem(atPath: file.url.path)
        #expect((folder[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((saved[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let values = try file.folder.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    /// A folder made earlier with wider permissions is narrowed on the next save.
    @Test func anExistingFolderIsNarrowed() async throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: file.folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try await file.save(Self.threeSeconds)
        let folder = try FileManager.default.attributesOfItem(atPath: file.folder.path)
        #expect((folder[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    /// What a write cut short by a crash left behind is deleted by the next write, and at
    /// launch with the switch on.
    @Test func leftoversOfACutWriteAreDeleted() async throws {
        defer { cleanUp() }
        try await file.save(Self.threeSeconds)
        let leftover = file.folder.appendingPathComponent(VoiceSampleFile.temporaryPrefix + "cut", isDirectory: false)
        try Data([1, 2, 3]).write(to: leftover)
        try await file.save(Self.fourSeconds)
        #expect(!FileManager.default.fileExists(atPath: leftover.path))

        try Data([1, 2, 3]).write(to: leftover)
        let speech = makeSpeech(remembers: true, isOn: false)
        speech.restoreVoice()
        await speech.waitForVoiceRestore()
        await speech.waitForVoiceFile()
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
        #expect(try await saved() == Self.fourSeconds)
    }

    /// Remove or the switch turned off right before Quit: the file is deleted at once, not
    /// by the queued task. With the last change a save, Quit leaves the file.
    @Test(arguments: [false, true])
    func aDeletionRightBeforeQuitIsDoneAtOnce(_ turnsTheSwitchOff: Bool) async throws {
        defer { cleanUp() }
        let speech = makeSpeech(remembers: true)
        await speech.useVoice(Self.threeSeconds)
        await speech.waitForVoiceFile()
        speech.removeVoiceFileBeforeQuit()
        #expect(file.exists)
        if turnsTheSwitchOff {
            speech.setRemembersVoice(false)
        } else {
            speech.forgetVoice()
        }
        speech.removeVoiceFileBeforeQuit()
        #expect(!file.exists)
        #expect(!FileManager.default.fileExists(atPath: file.folder.path))
        await speech.waitForVoiceFile()
    }

    // MARK: Launch

    /// At launch the saved sample waits for the speech model, then is used as a new
    /// recording, written down again by the speech model.
    @Test func theSavedSampleIsLoadedAtLaunchOnceTheSpeechModelIsReady() async throws {
        defer { cleanUp() }
        try await file.save(Self.threeSeconds)
        var heard: [VoiceSample] = []
        let speech = makeSpeech(remembers: true, transcribeVoice: { sample in
            heard.append(sample)
            return "We met at noon."
        })
        let gate = SpeechModelGate()
        gate.install(on: speech)
        speech.restoreVoice()
        try await gate.untilWaiting()
        #expect(heard.isEmpty)
        #expect(speech.voiceSeconds == nil)
        // Settings shows the sample as saved, with Remove, while it waits.
        #expect(speech.voiceIsSaved)
        gate.open()
        await speech.waitForVoiceRestore()
        #expect(heard == [Self.threeSeconds])
        #expect(speech.voiceSeconds == 3)
        #expect(speech.problem == nil)
        #expect(speech.voiceFileProblem == nil)
        await speech.waitForVoiceFile()
        #expect(try await saved() == Self.threeSeconds)
        #expect(speech.voiceIsSaved)

        speech.speak("We have a meeting next Tuesday.", in: .english)
        await speech.waitUntilDone()
    }

    /// With the switch off nothing is read, and a file left behind is deleted.
    @Test func nothingIsLoadedWhileOffAndAStrayFileIsDeleted() async throws {
        defer { cleanUp() }
        try await file.save(Self.threeSeconds)
        var heard = 0
        let speech = makeSpeech(remembers: false, transcribeVoice: { _ in
            heard += 1
            return "We met at noon."
        })
        speech.restoreVoice()
        await speech.waitForVoiceRestore()
        await speech.waitForVoiceFile()
        #expect(heard == 0)
        #expect(speech.voiceSeconds == nil)
        #expect(!speech.voiceIsSaved)
        #expect(!file.exists)
    }

    @Test func nothingHappensAtLaunchWithoutAFile() async throws {
        defer { cleanUp() }
        let speech = makeSpeech(remembers: true)
        speech.restoreVoice()
        await speech.waitForVoiceRestore()
        await speech.waitForVoiceFile()
        #expect(speech.voiceSeconds == nil)
        #expect(!speech.voiceIsSaved)
        #expect(speech.problem == nil)
        #expect(speech.voiceFileProblem == nil)
        #expect(speech.remembersVoice)
    }

    /// A file that is not a voice sample, or one that is too short, is deleted, Settings
    /// says so once, whether Speak translations is on or off, and nothing else changes.
    @Test(arguments: [
        Data("not a voice sample".utf8),
        VoiceSampleFile.encoded(VoiceSample(samples: [Float](repeating: 0.1, count: 16_000), sampleRate: 16_000)),
    ])
    func anUnreadableFileIsDeletedAtLaunch(_ contents: Data) async throws {
        defer { cleanUp() }
        try await file.save(Self.threeSeconds)
        try contents.write(to: file.url)
        var heard = 0
        let speech = makeSpeech(remembers: true, transcribeVoice: { _ in
            heard += 1
            return "We met at noon."
        })
        speech.restoreVoice()
        await speech.waitForVoiceRestore()
        await speech.waitForVoiceFile()
        #expect(heard == 0)
        #expect(!file.exists)
        #expect(speech.voiceSeconds == nil)
        #expect(!speech.voiceIsSaved)
        let message = "Orra could not read the voice sample saved on this Mac and deleted it. Record it again."
        #expect(speech.voiceFileProblem == message)
        #expect(speech.problem == nil)
        #expect(speech.remembersVoice)
        #expect(speech.isOn)
        // Turning Speak translations off and on, which clears `problem`, keeps it.
        speech.setOn(false)
        #expect(speech.voiceFileProblem == message)
        speech.setOn(true)
        await speech.waitForVoiceRestore()
        #expect(speech.voiceFileProblem == message)
        speech.setOn(false)
        await speech.waitUntilDone()
    }

    /// A saved sample the speech model hears no speech in is deleted and Settings says so,
    /// so it is not read again at every launch while the row says there is no sample.
    @Test func aSavedSampleWithoutSpeechIsDeletedAtLaunch() async throws {
        defer { cleanUp() }
        try await file.save(Self.threeSeconds)
        let speech = makeSpeech(remembers: true, transcribeVoice: { _ in " " })
        speech.restoreVoice()
        await speech.waitForVoiceRestore()
        await speech.waitForVoiceFile()
        #expect(!file.exists)
        #expect(speech.voiceSeconds == nil)
        #expect(!speech.voiceIsSaved)
        #expect(speech.voiceFileProblem == "Orra could not read the voice sample saved on this Mac and deleted it. Record it again.")
        #expect(speech.problem == nil)
        #expect(speech.remembersVoice)
    }

    /// Remember my voice turned off and on again while the saved sample waits for the
    /// speech model: the load ends for good, and nothing comes back.
    @Test func turningTheSwitchOffEndsTheLoadForGood() async throws {
        defer { cleanUp() }
        try await file.save(Self.threeSeconds)
        var heard = 0
        let speech = makeSpeech(remembers: true, transcribeVoice: { _ in
            heard += 1
            return "We met at noon."
        })
        let gate = SpeechModelGate()
        gate.install(on: speech)
        speech.restoreVoice()
        try await gate.untilWaiting()
        speech.setRemembersVoice(false)
        await speech.waitForVoiceFile()
        speech.setRemembersVoice(true)
        await speech.waitForVoiceFile()
        gate.open()
        await speech.waitForVoiceRestore()
        await speech.waitForVoiceFile()
        #expect(heard == 0)
        #expect(speech.voiceSeconds == nil)
        #expect(!speech.voiceIsSaved)
        #expect(!file.exists)
    }

    /// Remove while the saved sample waits for the speech model deletes it, and it does
    /// not come back.
    @Test func removeWhileTheSavedSampleWaits() async throws {
        defer { cleanUp() }
        try await file.save(Self.threeSeconds)
        let speech = makeSpeech(remembers: true)
        let gate = SpeechModelGate()
        gate.install(on: speech)
        speech.restoreVoice()
        try await gate.untilWaiting()
        #expect(speech.voiceIsSaved)
        speech.forgetVoice()
        #expect(!speech.voiceIsSaved)
        gate.open()
        await speech.waitForVoiceRestore()
        await speech.waitForVoiceFile()
        #expect(speech.voiceSeconds == nil)
        #expect(!file.exists)
        #expect(speech.remembersVoice)
    }

    /// A sample the user picks while the saved one waits for the speech model wins.
    @Test func aSamplePickedAtLaunchWins() async throws {
        defer { cleanUp() }
        try await file.save(Self.threeSeconds)
        let speech = makeSpeech(remembers: true)
        let gate = SpeechModelGate()
        gate.install(on: speech)
        speech.restoreVoice()
        try await gate.untilWaiting()
        await speech.useVoice(Self.fourSeconds)
        gate.open()
        await speech.waitForVoiceRestore()
        await speech.waitForVoiceFile()
        #expect(speech.voiceSeconds == 4)
        #expect(try await saved() == Self.fourSeconds)
    }

    /// A sample picked while the saved one waits, which the speech model could not take
    /// because it was not ready, does not end the load: the saved one is used after.
    @Test func aSampleThatFailsWhileTheSavedOneWaitsLetsItLoad() async throws {
        defer { cleanUp() }
        try await file.save(Self.threeSeconds)
        var ready = false
        let speech = makeSpeech(remembers: true, transcribeVoice: { _ in
            guard ready else { throw TranscriptionError.modelMissing }
            return "We met at noon."
        })
        let gate = SpeechModelGate()
        gate.install(on: speech)
        speech.restoreVoice()
        try await gate.untilWaiting()
        #expect(await speech.useVoice(Self.fourSeconds) == .failed)
        #expect(speech.voiceSeconds == nil)
        ready = true
        gate.open()
        await speech.waitForVoiceRestore()
        await speech.waitForVoiceFile()
        #expect(speech.voiceSeconds == 3)
        #expect(speech.problem == nil)
        #expect(try await saved() == Self.threeSeconds)
    }

    // MARK: The format

    @Test func theFormatRoundTripsAndRefusesOtherData() throws {
        let data = VoiceSampleFile.encoded(Self.fourSeconds)
        #expect(Array(data.prefix(4)) == Array("ORVS".utf8))
        #expect(try VoiceSampleFile.decoded(data) == Self.fourSeconds)
        #expect(throws: VoiceSample.ReadError.unreadable) { try VoiceSampleFile.decoded(data.dropLast()) }
        #expect(throws: VoiceSample.ReadError.unreadable) { try VoiceSampleFile.decoded(Data()) }
        var other = data
        other[4] = 2
        #expect(throws: VoiceSample.ReadError.unreadable) { try VoiceSampleFile.decoded(other) }
        let nan = VoiceSampleFile.encoded(VoiceSample(samples: [Float](repeating: .nan, count: 48_000), sampleRate: 16_000))
        #expect(throws: VoiceSample.ReadError.unreadable) { try VoiceSampleFile.decoded(nan) }
        let long = VoiceSampleFile.encoded(VoiceSample(samples: [Float](repeating: 0.1, count: 16_000 * 30), sampleRate: 16_000))
        #expect(throws: VoiceSample.ReadError.unreadable) { try VoiceSampleFile.decoded(long) }
    }

    @Test func theSwitchIsSavedAsABoolOnly() throws {
        try withTestDefaults("remembers-voice") { defaults in
            #expect(!TranslationSpeech.Settings.load(from: defaults).remembersVoice)
            var settings = TranslationSpeech.Settings()
            settings.remembersVoice = true
            settings.save(to: defaults)
            #expect(TranslationSpeech.Settings.load(from: defaults).remembersVoice)
            #expect(defaults.object(forKey: SpeechPreference.remembersVoiceKey) as? Bool == true)
        }
    }

    // MARK: Nothing logged

    /// The code that keeps the sample on disk has no logger and prints nothing, and the
    /// log lines of Speak Translation name lengths and reasons, never the audio or the words.
    @Test func neitherTheAudioNorTheWordsAreLogged() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Orra")
        let fileSource = try String(contentsOf: folder.appendingPathComponent("VoiceSampleFile.swift"), encoding: .utf8)
        for call in ["Logger", "logger", "print(", "NSLog", "os_log", "ProblemReport"] {
            #expect(!fileSource.contains(call), "VoiceSampleFile.swift uses \(call)")
        }
        let speech = try String(contentsOf: folder.appendingPathComponent("TranslationSpeech.swift"), encoding: .utf8)
        #expect(!speech.contains("print("))
        let logLines = speech.split(separator: "\n").filter { $0.contains("logger.") && $0.contains("(\"") }
        #expect(!logLines.isEmpty)
        for line in logLines {
            for word in [".samples", "transcript", "voice)", "sample)", "heard"] {
                #expect(!line.contains(word), "\(line)")
            }
        }
    }
}
