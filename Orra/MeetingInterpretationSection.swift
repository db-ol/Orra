import SwiftUI
import UniformTypeIdentifiers

/// Meeting Interpretation in Settings, after Features: a meeting where each side speaks
/// another language. Live captions show what the other side says, translated. Speak
/// translations to others speaks what the translation key translated, so the other side
/// hears it. Each part shows only where the page has it.
struct MeetingInterpretationSection: View {
    let captions: MeetingCaptions?
    let speech: TranslationSpeech?
    let voiceModels: VoiceModels?
    let translationIsOn: Bool
    /// Watches the devices only while Settings shows the speak rows.
    @State private var outputList = AudioOutputList.live()
    @State private var isChoosingVoice = false

    var body: some View {
        Section {
            if let captions {
                LiveCaptionRows(captions: captions)
            }
            if let speech, let voiceModels {
                SpeakTranslationRows(speech: speech, models: voiceModels, translationIsOn: translationIsOn, outputs: outputList.outputs, isChoosingVoice: $isChoosingVoice)
            }
        } header: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Meeting Interpretation")
                Text("For a meeting in two languages. Live captions show what the other side says in your language, and Orra can speak your translated words to them.")
                    .font(.subheadline)
                    .fontWeight(.regular)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            if speech != nil, voiceModels != nil {
                Text("Use a recording of your own voice only. Orra writes down what the voice sample says with its speech model, keeps both in memory until it quits and never saves them. The other side hears a synthesized voice, so let them know.")
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            if speech != nil { outputList.start() }
        }
        .onDisappear { outputList.stop() }
        .fileImporter(isPresented: $isChoosingVoice, allowedContentTypes: [.audio]) { result in
            guard case .success(let url) = result, let speech else { return }
            Task {
                let scoped = url.startAccessingSecurityScopedResource()
                defer {
                    if scoped { url.stopAccessingSecurityScopedResource() }
                }
                do {
                    let sample = try await VoiceSample.read(from: url)
                    await speech.useVoice(sample)
                } catch VoiceSample.ReadError.tooShort {
                    speech.reportVoiceProblem(String(localized: "The voice sample must be at least \(Int(VoiceSample.minimumSeconds)) seconds long."))
                } catch {
                    speech.reportVoiceProblem(String(localized: "Orra could not read this audio file."))
                }
            }
        }
    }
}

/// Live captions: the switch and what the caption window shows. The window has the same
/// picker.
private struct LiveCaptionRows: View {
    let captions: MeetingCaptions

    var body: some View {
        Toggle(isOn: Binding(
            get: { captions.isOn },
            set: { captions.setOn($0) }
        )) {
            DescribedLabel(
                title: "Live captions",
                detail: "Listen to the other side. Orra transcribes and translates the sound the Mac plays, in a floating window.",
                systemImage: "captions.bubble"
            )
        }
        .help(Text("Live captions are off each time Orra starts. Closing the caption window turns them off."))
        Picker(selection: Binding(
            get: { captions.displayMode },
            set: { captions.setDisplayMode($0) }
        )) {
            ForEach(CaptionDisplayMode.allCases, id: \.self) { mode in
                Text(mode.title).tag(mode)
            }
        } label: {
            Label("Captions show", systemImage: "text.bubble")
        }
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
    @Binding var isChoosingVoice: Bool

    var body: some View {
        Group {
            Toggle(isOn: Binding(
                get: { speech.isOn },
                set: { speech.setOn($0) }
            )) {
                DescribedLabel(
                    title: "Speak translations to others",
                    detail: "Orra also speaks what the translation key translated, into the device below, so the other side of a call hears it.",
                    systemImage: "speaker.wave.2.bubble"
                )
            }
            // Stays usable while on, so it can be turned off after Translation was.
            .disabled(!speech.canSpeak || (!translationIsOn && !speech.isOn))
            .help(Text("Choose Orra Microphone as the microphone in the meeting app. Orra speaks one translation after another, and waits while you dictate."))
            if !speech.canSpeak {
                note(Text("This build of Orra has no voice model."))
            } else if !translationIsOn {
                note(Text("Turn on Translation to use this."))
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
                    detail: "Orra's speech model listens to each sentence before it plays, and makes it again when it hears other words. Each sentence starts a moment later.",
                    systemImage: "text.badge.checkmark"
                )
            }
            .disabled(!speech.isOn)
            VoiceSampleRow(speech: speech, isChoosing: $isChoosingVoice)
                .disabled(!speech.isOn)
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

/// The voice sample: its length while one is in memory, and the buttons to choose or
/// remove one.
private struct VoiceSampleRow: View {
    let speech: TranslationSpeech
    @Binding var isChoosing: Bool

    var body: some View {
        LabeledContent {
            HStack {
                if speech.voiceSeconds != nil {
                    Button("Remove") {
                        speech.forgetVoice()
                    }
                }
                Button("Choose…") {
                    isChoosing = true
                }
                .disabled(speech.isListeningToVoice)
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
        } else if let seconds = speech.voiceSeconds {
            "\(Int(seconds.rounded())) seconds, in memory until Orra quits."
        } else {
            "None. The voice model speaks in its own voice."
        }
    }
}
