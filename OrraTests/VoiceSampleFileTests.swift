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
        transcribeVoice: @escaping (VoiceSample) async throws -> String = { _ in "We met at noon." }
    ) -> TranslationSpeech {
        let speech = TranslationSpeech(
            engines: .only(synthesizer),
            playback: FakePlayback(),
            outputs: { [] },
            folders: { nil },
            settings: TranslationSpeech.Settings(isOn: true, remembersVoice: remembers),
            voiceFile: file,
            dictationPoll: .milliseconds(1)
        )
        speech.transcribeVoice = transcribeVoice
        return speech
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
    }

    @Test func nothingIsWrittenWhileOff() async throws {
        defer { cleanUp() }
        let speech = makeSpeech(remembers: false)
        await speech.useVoice(Self.threeSeconds)
        await speech.waitForVoiceFile()
        #expect(speech.voiceSeconds == 3)
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
        speech.setRemembersVoice(false)
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
        await speech.waitForVoiceFile()
        #expect(!file.exists)
        #expect(speech.remembersVoice)
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
        let names = try FileManager.default.contentsOfDirectory(atPath: file.folder.path)
        #expect(names == [VoiceSampleFile.name])
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
        let ready = AsyncStream<Void>.makeStream()
        var waited = false
        speech.waitForSpeechModel = {
            waited = true
            for await _ in ready.stream { break }
        }
        let restoring = Task { await speech.restoreVoice() }
        for _ in 0..<200 where !waited {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(waited)
        #expect(heard.isEmpty)
        #expect(speech.voiceSeconds == nil)
        ready.continuation.yield()
        await restoring.value
        #expect(heard == [Self.threeSeconds])
        #expect(speech.voiceSeconds == 3)
        #expect(speech.problem == nil)
        await speech.waitForVoiceFile()
        #expect(try await saved() == Self.threeSeconds)

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
        await speech.restoreVoice()
        await speech.waitForVoiceFile()
        #expect(heard == 0)
        #expect(speech.voiceSeconds == nil)
        #expect(!file.exists)
    }

    @Test func nothingHappensAtLaunchWithoutAFile() async throws {
        defer { cleanUp() }
        let speech = makeSpeech(remembers: true)
        await speech.restoreVoice()
        await speech.waitForVoiceFile()
        #expect(speech.voiceSeconds == nil)
        #expect(speech.problem == nil)
        #expect(speech.remembersVoice)
    }

    /// A file that is not a voice sample, or one that is too short, is deleted, Settings
    /// says so once, and nothing else changes.
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
        await speech.restoreVoice()
        await speech.waitForVoiceFile()
        #expect(heard == 0)
        #expect(!file.exists)
        #expect(speech.voiceSeconds == nil)
        #expect(speech.problem == "Orra could not read the voice sample saved on this Mac and deleted it. Record it again.")
        #expect(speech.remembersVoice)
        #expect(speech.isOn)
    }

    /// A sample the user picks while the saved one waits for the speech model wins.
    @Test func aSamplePickedAtLaunchWins() async throws {
        defer { cleanUp() }
        try await file.save(Self.threeSeconds)
        let speech = makeSpeech(remembers: true)
        let ready = AsyncStream<Void>.makeStream()
        var waited = false
        speech.waitForSpeechModel = {
            waited = true
            for await _ in ready.stream { break }
        }
        let restoring = Task { await speech.restoreVoice() }
        for _ in 0..<200 where !waited {
            try await Task.sleep(for: .milliseconds(5))
        }
        await speech.useVoice(Self.fourSeconds)
        ready.continuation.yield()
        await restoring.value
        await speech.waitForVoiceFile()
        #expect(speech.voiceSeconds == 4)
        #expect(try await saved() == Self.fourSeconds)
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
        let name = "VoiceSampleFileTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(!TranslationSpeech.Settings.load(from: defaults).remembersVoice)
        var settings = TranslationSpeech.Settings()
        settings.remembersVoice = true
        settings.save(to: defaults)
        #expect(TranslationSpeech.Settings.load(from: defaults).remembersVoice)
        #expect(defaults.object(forKey: SpeechPreference.remembersVoiceKey) as? Bool == true)
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
