import SwiftUI

/// Meeting Interpretation, its own page in Settings: a meeting where each side speaks
/// another language. Live captions show what the other side says, translated into the
/// caption target. Speak translations to others speaks what the translation key
/// translated, so the other side hears it, in the voice of a sample the user recorded if
/// they like. Each part shows only where the page has it.
struct MeetingInterpretationSettings: View {
    let pushToTalk: PushToTalkController
    let captions: MeetingCaptions?
    let speech: TranslationSpeech?
    let voiceModels: VoiceModels?
    /// Whether translation is on, the caption target, and the translation key's direction,
    /// which sets the language the voice sample's script is in at first, see VoiceScript.
    let cleanup: TextCleanup
    /// Watches the devices only while Settings shows this page.
    @State private var outputList = AudioOutputList.live()
    /// The voice sample sheet's recording while the sheet is open.
    @State private var voiceRecording: VoiceRecording?

    var body: some View {
        Form {
            Section {
                if let captions {
                    LiveCaptionRows(captions: captions, cleanup: cleanup, shortcut: pushToTalk.liveCaptionsShortcut)
                }
            } header: {
                Text("For meetings across languages. Read what others say in your language, and let them hear you in theirs, even in your own voice.")
                    .font(.subheadline)
                    .fontWeight(.regular)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let speech, let voiceModels {
                Section {
                    SpeakTranslationRows(speech: speech, models: voiceModels, translationIsOn: cleanup.translationIsOn, outputs: outputList.outputs, record: openRecording)
                } footer: {
                    Group {
                        if speech.remembersVoice {
                            Text("Record your own voice only. Orra writes down what you said with its speech model and keeps the words in memory until it quits. With Remember my voice on, it saves the recording on this Mac until you remove it. The other side hears a synthesized voice, so let them know.")
                        } else {
                            Text("Record your own voice only. Orra writes down what you said with its speech model and keeps the recording and the words in memory until it quits. The other side hears a synthesized voice, so let them know.")
                        }
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Meeting Interpretation")
        .onAppear {
            if speech != nil { outputList.start() }
        }
        .onDisappear { outputList.stop() }
        .sheet(item: $voiceRecording) { recording in
            VoiceRecordingSheet(
                recording: recording,
                blocker: recordingBlocker,
                remembersVoice: speech?.remembersVoice,
                use: { sample, remember in
                    closeRecording()
                    guard let speech else { return }
                    Task { await speech.useVoice(sample, remember: remember) }
                },
                importFile: { url, remember in
                    closeRecording()
                    importVoice(from: url, remember: remember)
                },
                close: closeRecording
            )
            .onAppear { pushToTalk.refreshMicrophoneAccess() }
            // Also when the sheet closes some other way, so the microphone never stays on.
            .onDisappear { recording.cancel() }
        }
    }

    private func openRecording() {
        voiceRecording = VoiceRecording(
            recorder: .live(pushToTalk),
            playback: SpeechPlayer(),
            output: { AudioOutput.systemDefault() },
            scriptLanguage: VoiceScript.language(direction: cleanup.translationDirection, language: pushToTalk.dictationLanguage),
            scriptLanguages: VoiceScript.languages(direction: cleanup.translationDirection, language: pushToTalk.dictationLanguage)
        )
    }

    /// Stops what the sheet records or plays and drops what it recorded.
    private func closeRecording() {
        voiceRecording?.cancel()
        voiceRecording = nil
    }

    /// Why the sheet cannot record now. A dictation and live captions keep the speech
    /// model and the microphone busy.
    private var recordingBlocker: LocalizedStringKey? {
        if pushToTalk.microphoneAccess != .authorized {
            // Without microphone access setup is not complete, so the menu item reads Setup
            // Guide, see SetupChecklist.menuTitle(locale:).
            "Orra needs microphone access to record. Setup Guide in the Orra menu can turn it on."
        } else if captions?.isOn == true {
            "Turn off Live captions to record."
        } else if pushToTalk.state != .idle {
            "Wait until the dictation is done."
        } else if pushToTalk.isRecordingVoiceSample, voiceRecording?.isRecording != true {
            // A recording cancelled while the microphone was starting stops once it has
            // started.
            "Orra is still stopping the last recording."
        } else {
            nil
        }
    }

    /// Reads a voice sample from an audio file the user picked, the smaller way next to
    /// recording one. `remember` is the sheet's Remember my voice, which applies only when
    /// the file holds a sample.
    private func importVoice(from url: URL, remember: Bool?) {
        guard let speech else { return }
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let sample = try await VoiceSample.read(from: url)
                await speech.useVoice(sample, remember: remember)
            } catch VoiceSample.ReadError.tooShort {
                speech.reportVoiceProblem(String(localized: "The voice sample must be at least \(Int(VoiceSample.minimumSeconds)) seconds long."))
            } catch {
                speech.reportVoiceProblem(String(localized: "Orra could not read this audio file."))
            }
        }
    }
}

/// Live captions: the switch, what the caption window shows and the language it
/// translates into. The window has the same choices.
private struct LiveCaptionRows: View {
    let captions: MeetingCaptions
    /// The caption target and the dictation language, whose choices it offers.
    let cleanup: TextCleanup
    /// The Live Captions shortcut, which the switch's help names, or nil for none.
    let shortcut: KeyCombination?

    /// One string with the shortcut, so each language joins the sentences its own way.
    private var help: Text {
        guard let shortcut else {
            return Text("Live captions are off each time Orra starts. Closing the caption window turns them off.")
        }
        return Text("Live captions are off each time Orra starts. Closing the caption window turns them off. Press \(shortcut.title()) in any app to turn them on or off.")
    }

    var body: some View {
        Toggle(isOn: Binding(
            get: { captions.isOn },
            set: { captions.setOn($0) }
        )) {
            DescribedLabel(
                title: "Live captions",
                detail: "Orra translates the sound the Mac plays into captions, in a floating window.",
                systemImage: "captions.bubble"
            )
        }
        .help(help)
        Picker(selection: Binding(
            get: { captions.displayMode },
            set: { captions.setDisplayMode($0) }
        )) {
            ForEach(CaptionDisplayMode.allCases, id: \.self) { mode in
                CaptionModeChoice(mode: mode).tag(mode)
            }
        } label: {
            Label("Captions show", systemImage: "text.bubble")
        }
        // A target saved for another dictation language shows as the one it acts as, and
        // comes back with its language.
        Picker(selection: Binding(
            get: { cleanup.effectiveCaptionTarget },
            set: { cleanup.pickCaptionTarget($0) }
        )) {
            ForEach(CaptionTarget.choices(for: cleanup.dictationLanguage), id: \.self) { target in
                Text(target.title).tag(target)
            }
        } label: {
            DescribedLabel(
                title: "Translate captions into",
                detail: "The language you read in the caption window. The translation key has its own setting, on the Translation page.",
                systemImage: "translate"
            )
        }
        // Original does not translate.
        .disabled(!captions.displayMode.translates)
    }
}

/// Speak translations to others: the switch, the voice model when the build has two,
/// where the voice goes, whether the text is pasted too, whether the words are checked,
/// the voice sample and the voice model's download.
private struct SpeakTranslationRows: View {
    let speech: TranslationSpeech
    let models: VoiceModels
    let translationIsOn: Bool
    let outputs: [AudioOutput]
    /// Opens the sheet that records a voice sample.
    let record: () -> Void

    var body: some View {
        Group {
            Toggle(isOn: Binding(
                get: { speech.isOn },
                set: { speech.setOn($0) }
            )) {
                // The caption target shows right above, so the line says which language the
                // voice speaks.
                DescribedLabel(
                    title: "Speak translations to others",
                    detail: "Orra speaks your translations through the device below.",
                    systemImage: "speaker.wave.2.bubble",
                    note: "Speaks in the language the translation key translates into (Translate into, on the Translation page)."
                )
            }
            // Stays usable while on, so it can be turned off after Translation was.
            .disabled(!speech.canSpeak || (!translationIsOn && !speech.isOn))
            .help(Text("Choose Orra Microphone as the microphone in the meeting app. Orra speaks one translation after another, and waits while you dictate."))
            if !speech.canSpeak {
                note(Text("This build of Orra has no voice model."))
            } else if !translationIsOn {
                note(Text("Turn on Translation on the Translation page to use this."))
            }
            if !speech.engineChoices.isEmpty {
                Picker(selection: Binding(
                    get: { speech.engine ?? VoiceEngineChoice.preferred },
                    set: { speech.setEngine($0) }
                )) {
                    ForEach(speech.engineChoices) { kind in
                        Text(verbatim: kind.name).tag(kind)
                    }
                } label: {
                    DescribedLabel(
                        title: "Voice model",
                        detail: "Qwen3-TTS starts speaking sooner. CosyVoice3 sounds more like the voice sample and needs a larger download.",
                        systemImage: "waveform"
                    )
                }
                .disabled(!speech.isOn)
            }
            Picker(selection: Binding(
                get: { speech.output?.uid ?? "" },
                set: { uid in speech.setOutput(choice(forUID: uid)) }
            )) {
                Text(automaticLabel).tag("")
                ForEach(outputs, id: \.uid) { output in
                    Text(verbatim: output.name).tag(output.uid)
                }
                if let chosen = speech.output, !outputs.contains(where: { $0.uid == chosen.uid }) {
                    Text("\(chosen.name) (not connected)").tag(chosen.uid)
                }
            } label: {
                Label("Speak into", systemImage: "hifispeaker")
            }
            .disabled(!speech.isOn)
            .help(Text("Orra never speaks into the speakers on its own. Without Orra Microphone, pick a device here, such as a loopback device a meeting app can use as its microphone."))
            Toggle(isOn: Binding(
                get: { speech.alsoPastes },
                set: { speech.setAlsoPastes($0) }
            )) {
                Label("Also paste the translated text", systemImage: "doc.on.clipboard")
            }
            .disabled(!speech.isOn)
            Toggle(isOn: Binding(
                get: { speech.checksWords },
                set: { speech.setChecksWords($0) }
            )) {
                DescribedLabel(
                    title: "Check the words before speaking",
                    detail: "With a voice sample, Orra's speech model listens to each sentence before it plays, and makes it again when it hears other words. Each sentence then starts a moment later.",
                    systemImage: "text.badge.checkmark"
                )
            }
            .disabled(!speech.isOn)
            VoiceSampleRow(speech: speech, record: record)
            // Whether Speak translations is on or off, like Remove.
            if let problem = speech.voiceFileProblem {
                note(Text(verbatim: problem))
            }
            if speech.isOn, let line = models.status.line {
                note(Text(verbatim: line))
            }
            if speech.isOn, let title = models.status.buttonTitle {
                Button(title) {
                    if case .downloading = models.status {
                        models.cancel()
                    } else {
                        models.download()
                    }
                }
            }
            if speech.isOn, let problem = speech.problem {
                note(Text(verbatim: problem))
            }
        }
    }

    private var automaticLabel: String {
        if let device = AudioOutput.orraMicrophone(in: outputs) {
            return String(localized: "Automatic (\(device.name))")
        }
        return String(localized: "Automatic (Orra Microphone is not installed)")
    }

    private func choice(forUID uid: String) -> SpeechOutputChoice? {
        guard !uid.isEmpty else { return nil }
        if let output = outputs.first(where: { $0.uid == uid }) {
            return SpeechOutputChoice(uid: output.uid, name: output.name)
        }
        return speech.output?.uid == uid ? speech.output : nil
    }

    private func note(_ text: Text) -> some View {
        text
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The voice sample: its length while one is in memory, the buttons to record or remove
/// one, and Remember my voice. While Speak translations is off, only Record… is disabled
/// and Remember my voice can only be turned off, so a sample, saved or not, can always be
/// removed.
private struct VoiceSampleRow: View {
    let speech: TranslationSpeech
    let record: () -> Void

    var body: some View {
        sample
        Toggle(isOn: Binding(
            get: { speech.remembersVoice },
            set: { speech.setRemembersVoice($0) }
        )) {
            DescribedLabel(
                title: "Remember my voice",
                detail: RememberVoiceText.detail(on: speech.remembersVoice),
                systemImage: "internaldrive"
            )
        }
        .disabled(!speech.isOn && !speech.remembersVoice)
    }

    private var sample: some View {
        LabeledContent {
            HStack {
                if speech.voiceSeconds != nil || speech.voiceIsSaved {
                    Button("Remove") {
                        speech.forgetVoice()
                    }
                }
                Button("Record…") {
                    record()
                }
                .disabled(!speech.isOn || speech.isListeningToVoice)
            }
        } label: {
            DescribedLabel(
                title: "Voice sample",
                detail: detail,
                systemImage: "waveform.badge.mic"
            )
        }
    }

    private var detail: LocalizedStringKey {
        if speech.isListeningToVoice {
            "Listening to the voice sample…"
        } else if let seconds = speech.voiceSeconds, speech.voiceIsSaved {
            "\(Int(seconds.rounded())) seconds, saved on this Mac."
        } else if let seconds = speech.voiceSeconds {
            "\(Int(seconds.rounded())) seconds, in memory until Orra quits."
        } else if speech.voiceIsSaved {
            "Saved on this Mac, not loaded yet."
        } else {
            "None. The voice model speaks in its own voice."
        }
    }
}

/// What Remember my voice does, under the switch in Settings and the checkbox in the
/// recording sheet.
enum RememberVoiceText {
    static func detail(on: Bool) -> LocalizedStringKey {
        on ? "Saved on this Mac until you remove it, and loaded when Orra starts." : "Kept in memory until Orra quits."
    }
}
