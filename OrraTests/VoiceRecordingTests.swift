import Foundation
import Testing
@testable import Orra

/// A stand in for the microphone of the voice sample sheet.
@MainActor
final class FakeVoiceRecorder {
    var recording = AudioRecording(samples: FakeMicrophone.tone(count: 16_000 * 5), sampleRate: 16_000)
    var startError: (any Error)?
    var startDelay: Duration = .zero
    var level: Float = 0
    private(set) var calls: [String] = []

    var recorder: VoiceRecorder {
        VoiceRecorder(
            start: {
                self.calls.append("start")
                if self.startDelay > .zero {
                    try? await Task.sleep(for: self.startDelay)
                }
                if let error = self.startError {
                    throw error
                }
            },
            stop: {
                self.calls.append("stop")
                return self.recording
            },
            cancel: { self.calls.append("cancel") },
            level: { self.level }
        )
    }
}

@MainActor
struct VoiceRecordingTests {
    let mic = FakeVoiceRecorder()
    let playback = FakePlayback()
    static let speakers = AudioOutput(id: 1, uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers")

    private func makeRecording(maximum: Duration = .seconds(VoiceRecording.maximumSeconds), output: AudioOutput? = speakers) -> VoiceRecording {
        VoiceRecording(recorder: mic.recorder, playback: playback, output: { output }, scriptLanguage: .english, maximum: maximum, tick: .milliseconds(5))
    }

    // MARK: The script

    @Test func theScriptIsInTheLanguageTheUserSpeaksInMeetings() {
        // A fixed direction names the language the user does not speak.
        #expect(VoiceScript.language(direction: .english, interface: Locale(identifier: "en")) == .chinese)
        #expect(VoiceScript.language(direction: .chinese, interface: Locale(identifier: "zh-Hans")) == .english)
        // The automatic direction goes by the language Orra shows.
        #expect(VoiceScript.language(direction: .automatic, interface: Locale(identifier: "zh-Hans")) == .chinese)
        #expect(VoiceScript.language(direction: .automatic, interface: Locale(identifier: "en")) == .english)
    }

    @Test func eachScriptIsInItsOwnLanguageAndFitsTheSample() {
        let english = VoiceScript.text(in: .english)
        let chinese = VoiceScript.text(in: .chinese)
        #expect(TranslationDirection.sourceLanguage(of: english) == .english)
        #expect(TranslationDirection.sourceLanguage(of: chinese) == .chinese)
        #expect(!chinese.unicodeScalars.contains { ("a"..."z").contains($0) || ("A"..."Z").contains($0) })
        // About 10 seconds read aloud: some 2.5 English words or 4 Chinese characters a
        // second, well above the shortest sample and within what Orra keeps.
        let words = english.split(separator: " ").count
        let han = chinese.unicodeScalars.filter(TranslationDirection.isHan).count
        #expect((20...32).contains(words))
        #expect((32...50).contains(han))
    }

    /// For Japanese and Spanish the scripts follow the same rule, with the language of the
    /// pair, and the picker offers English and that language.
    @Test func japaneseAndSpanishHaveScriptsOfTheirOwn() {
        #expect(VoiceScript.language(direction: .english, language: .japanese, interface: Locale(identifier: "en")) == .japanese)
        #expect(VoiceScript.language(direction: .japanese, language: .japanese, interface: Locale(identifier: "ja")) == .english)
        #expect(VoiceScript.language(direction: .automatic, language: .japanese, interface: Locale(identifier: "ja")) == .japanese)
        #expect(VoiceScript.language(direction: .automatic, language: .spanish, interface: Locale(identifier: "es-419")) == .spanish)
        #expect(VoiceScript.language(direction: .automatic, language: .spanish, interface: Locale(identifier: "en")) == .english)
        // A choice saved for Chinese acts as Automatic.
        #expect(VoiceScript.language(direction: .chinese, language: .spanish, interface: Locale(identifier: "es-419")) == .spanish)
        let japanese = VoiceScript.text(in: .japanese)
        let spanish = VoiceScript.text(in: .spanish)
        #expect(TranslationDirection.source(of: japanese, in: .japanese) == .partner)
        #expect(TranslationDirection.source(of: spanish, in: .spanish) == .partner)
        // About 10 seconds read aloud, as the other scripts.
        #expect((50...75).contains(japanese.count))
        #expect((20...32).contains(spanish.split(separator: " ").count))
        #expect(VoiceScript.name(of: .japanese) == "日本語")
        #expect(VoiceScript.name(of: .spanish) == "Español")
        #expect(DictationLanguage.spanish.translationTargets == [.english, .spanish])
        let recording = VoiceRecording(recorder: mic.recorder, playback: playback, output: { nil }, scriptLanguage: .japanese, scriptLanguages: DictationLanguage.japanese.translationTargets)
        #expect(recording.scriptLanguages == [.english, .japanese])
        #expect(recording.script == japanese)
    }

    @Test func aNewRecordingShowsTheScriptOfItsLanguage() {
        let recording = makeRecording()
        #expect(recording.script == VoiceScript.text(in: .english))
        recording.scriptLanguage = .chinese
        #expect(recording.script == VoiceScript.text(in: .chinese))
    }

    // MARK: The states

    @Test func recordingAndStoppingGivesASample() async throws {
        let recording = makeRecording()
        #expect(recording.phase == .idle)
        mic.level = 0.1
        recording.start()
        #expect(recording.phase == .starting)
        try await eventually { recording.phase == .recording }
        try await eventually { recording.level > 0 && recording.elapsed > 0 }
        recording.stop()
        try await eventually { recording.phase == .recorded }
        #expect(mic.calls == ["start", "stop"])
        #expect(recording.elapsed == 5)
        #expect(recording.stoppedAtLimit == false)
        #expect(recording.level == 0)
        let sample = try #require(recording.take())
        #expect(sample.seconds == 5)
        #expect(sample.sampleRate == 16_000)
        // Handed over once, and gone from the sheet.
        #expect(recording.take() == nil)
        #expect(recording.sample == nil)
        #expect(recording.phase == .idle)
    }

    @Test func aShortRecordingIsTooShort() async throws {
        mic.recording = AudioRecording(samples: FakeMicrophone.tone(count: 16_000), sampleRate: 16_000)
        let recording = makeRecording()
        recording.start()
        try await eventually { recording.phase == .recording }
        recording.stop()
        try await eventually { recording.phase == .tooShort }
        #expect(recording.sample == nil)
        #expect(recording.take() == nil)
    }

    @Test func aRecordingStopsByItselfAtTheLimit() async throws {
        let recording = makeRecording(maximum: .milliseconds(60))
        recording.start()
        try await eventually { recording.phase == .recorded }
        #expect(mic.calls == ["start", "stop"])
        #expect(recording.stoppedAtLimit)
        #expect(recording.sample != nil)
    }

    @Test func aMicrophoneThatFailsToStartSaysSo() async throws {
        mic.startError = TestError()
        let recording = makeRecording()
        recording.start()
        try await eventually { recording.phase != .starting }
        #expect(recording.phase == .failed("The microphone could not start"))
        #expect(!recording.isRecording)
    }

    /// A dictation or the last recording still holding the microphone is not a failure of
    /// the microphone.
    @Test func aBusyMicrophoneSaysToTryAgain() async throws {
        mic.startError = VoiceSampleCaptureError.busy
        let recording = makeRecording()
        recording.start()
        try await eventually { recording.phase != .starting }
        #expect(recording.phase == .failed("The microphone is busy. Try again in a moment."))
    }

    @Test func aFinishedRecordingIsJudged() {
        let long = FakeMicrophone.tone(count: 16_000 * 3)
        #expect(VoiceRecording.judge(AudioRecording(samples: long, sampleRate: 16_000)) == .recorded)
        #expect(VoiceRecording.judge(AudioRecording(samples: Array(long.prefix(16_000)), sampleRate: 16_000)) == .tooShort)
        #expect(VoiceRecording.judge(AudioRecording(samples: [Float](repeating: 0, count: 16_000 * 3), sampleRate: 16_000)) == .failed("No sound came from the microphone"))
        #expect(VoiceRecording.judge(AudioRecording(samples: long, sampleRate: 16_000, wasCut: true)) == .failed("The microphone changed during the recording. Try again."))
    }

    @Test func cancelStopsTheMicrophoneAndDropsTheSample() async throws {
        let recording = makeRecording()
        recording.start()
        try await eventually { recording.phase == .recording }
        recording.cancel()
        try await eventually { mic.calls == ["start", "cancel"] }
        #expect(recording.phase == .idle)

        recording.start()
        try await eventually { recording.phase == .recording }
        recording.stop()
        try await eventually { recording.phase == .recorded }
        recording.cancel()
        #expect(recording.sample == nil)
        #expect(recording.phase == .idle)
    }

    @Test func aCancelWhileTheMicrophoneStartsStopsItOnceStarted() async throws {
        mic.startDelay = .milliseconds(50)
        let recording = makeRecording()
        recording.start()
        recording.cancel()
        try await eventually { mic.calls == ["start", "cancel"] }
        try await Task.sleep(for: .milliseconds(30))
        #expect(recording.phase == .idle)
        #expect(mic.calls == ["start", "cancel"])
    }

    @Test func reRecordingReplacesTheSample() async throws {
        let recording = makeRecording()
        recording.start()
        try await eventually { recording.phase == .recording }
        recording.stop()
        try await eventually { recording.phase == .recorded }
        mic.recording = AudioRecording(samples: FakeMicrophone.tone(count: 16_000 * 4), sampleRate: 16_000)
        recording.start()
        #expect(recording.sample == nil)
        try await eventually { recording.phase == .recording }
        recording.stop()
        try await eventually { recording.phase == .recorded }
        #expect(recording.sample?.seconds == 4)
    }

    @Test func playBackPlaysTheSampleOnTheDefaultOutput() async throws {
        let recording = makeRecording()
        #expect(!recording.canPlayBack)
        recording.start()
        try await eventually { recording.phase == .recording }
        recording.stop()
        try await eventually { recording.phase == .recorded }
        #expect(recording.canPlayBack)
        recording.togglePlayback()
        try await eventually { !recording.isPlaying }
        #expect(playback.calls == ["start MacBook Pro Speakers", "play 80000", "finish", "stop"])
    }

    @Test func withoutAnOutputThereIsNoPlayBack() async throws {
        let recording = makeRecording(output: nil)
        recording.start()
        try await eventually { recording.phase == .recording }
        recording.stop()
        try await eventually { recording.phase == .recorded }
        #expect(!recording.canPlayBack)
        recording.togglePlayback()
        #expect(playback.calls.isEmpty)
    }

    // MARK: The sample

    @Test func aLongRecordingIsCutAtAQuietMomentBeforeTheLimit() {
        let rate = 16_000
        var samples = FakeMicrophone.tone(count: rate * 15)
        // A pause 11 seconds in.
        let pause = Int(11.0 * Double(rate))
        for index in pause..<(pause + rate / 5) {
            samples[index] = 0
        }
        let sample = VoiceSample(recorded: samples, sampleRate: rate)
        #expect(sample.seconds <= VoiceSample.maximumSeconds)
        #expect(sample.seconds > 11 && sample.seconds < 11.2)
        // A short one is kept whole.
        let short = VoiceSample(recorded: Array(samples.prefix(rate * 8)), sampleRate: rate)
        #expect(short.samples.count == rate * 8)
    }

    // MARK: Memory only

    @Test func theRecordingCodeHasNoWayToWriteAFile() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Orra")
        for name in ["VoiceRecording.swift", "VoiceRecordingSheet.swift"] {
            let source = try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
            for call in ["FileManager", "write(to", "AVAudioFile", "createFile", "UserDefaults", "FileHandle", "NSTemporaryDirectory", "temporaryDirectory"] {
                #expect(!source.contains(call), "\(name) uses \(call)")
            }
        }
    }

    @Test func recordingAndUsingASampleLeavesNoAudioFileBehind() async throws {
        let folders = [FileManager.default.temporaryDirectory, URL.cachesDirectory, URL.applicationSupportDirectory]
        let before = folders.map(Self.files)
        let recording = makeRecording()
        recording.start()
        try await eventually { recording.phase == .recording }
        recording.stop()
        try await eventually { recording.phase == .recorded }
        recording.togglePlayback()
        try await eventually { !recording.isPlaying }
        _ = recording.take()
        let after = folders.map(Self.files)
        for (old, new) in zip(before, after) {
            #expect(new.subtracting(old).isEmpty)
        }
    }

    /// The audio files at the top of a folder. Other tests running at the same time write
    /// other files to the same folders.
    private static func files(in folder: URL) -> Set<String> {
        let audio: Set<String> = ["wav", "caf", "aif", "aiff", "m4a", "mp3", "flac"]
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return Set(names.filter { audio.contains(($0 as NSString).pathExtension.lowercased()) })
    }

    // MARK: The microphone of dictation

    @Test func theControllerRecordsTheChosenMicrophoneAndBlocksAHold() async throws {
        let microphone = FakeMicrophone()
        let speech = FakeSpeech()
        let choice = MicrophoneChoice(uid: "usb", name: "USB Microphone")
        let controller = PushToTalkController(capture: microphone.capture, transcription: speech.transcription, insert: FakeInserter().insert, minimumHold: .zero, releaseTail: .zero, listeningCueDelay: .zero, microphone: choice)
        await controller.loadModel()
        let cues = CueRecorder(controller)
        try await controller.startVoiceSample()
        #expect(controller.isRecordingVoiceSample)
        #expect(microphone.preferredInputs == ["usb"])
        // A press of the talk key meanwhile records nothing and says why.
        controller.handle(.pressed(isRepeat: false))
        #expect(controller.state == .idle)
        #expect(cues.list == [.finished(message: "Orra is recording a voice sample in Settings")])
        #expect(microphone.calls == ["start"])
        let recorded = await controller.stopVoiceSample()
        #expect(recorded == microphone.recording)
        #expect(!controller.isRecordingVoiceSample)
        #expect(microphone.calls == ["start", "stop"])
    }

    @Test func theControllerRecordsNoSampleWithoutAccessOrDuringADictation() async throws {
        let microphone = FakeMicrophone()
        microphone.access = .denied
        let controller = PushToTalkController(capture: microphone.capture, transcription: FakeSpeech().transcription, insert: FakeInserter().insert)
        await #expect(throws: VoiceSampleCaptureError.busy) {
            try await controller.startVoiceSample()
        }
        #expect(microphone.calls.isEmpty)
        #expect(!controller.isRecordingVoiceSample)

        microphone.access = .authorized
        await controller.loadModel()
        controller.handle(.pressed(isRepeat: false))
        #expect(controller.state != .idle)
        await #expect(throws: VoiceSampleCaptureError.busy) {
            try await controller.startVoiceSample()
        }
        controller.handle(.cancelled)
    }

    @Test func aCancelledSampleStopsTheMicrophone() async throws {
        let microphone = FakeMicrophone()
        let controller = PushToTalkController(capture: microphone.capture, transcription: FakeSpeech().transcription, insert: FakeInserter().insert)
        try await controller.startVoiceSample()
        await controller.cancelVoiceSample()
        #expect(microphone.calls == ["start", "cancel"])
        #expect(!controller.isRecordingVoiceSample)
    }

    @Test func theClockShowsMinutesAndSeconds() {
        #expect(VoiceRecordingSheet.clock(0) == "0:00")
        #expect(VoiceRecordingSheet.clock(7.9) == "0:07")
        #expect(VoiceRecordingSheet.clock(75) == "1:15")
    }
}
