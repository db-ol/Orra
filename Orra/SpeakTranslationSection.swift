import SwiftUI
import UniformTypeIdentifiers

/// Speak Translation in Settings, under Features: the switch, where the voice goes,
/// whether the text is pasted too, the voice sample and the voice model's download.
struct SpeakTranslationSection: View {
    let speech: TranslationSpeech
    let models: VoiceModels
    let translationIsOn: Bool
    @State private var outputs: [AudioOutput] = []
    @State private var isChoosingVoice = false

    var body: some View {
        Section {
            Toggle(isOn: Binding(
                get: { speech.isOn },
                set: { speech.setOn($0) }
            )) {
                DescribedLabel(
                    title: "Speak translation",
                    detail: "Orra also speaks what the translation key translated, into the device below, so the other side of a call hears it.",
                    systemImage: "speaker.wave.2.bubble"
                )
            }
            .disabled(!speech.canSpeak || !translationIsOn)
            .help(Text("Choose Orra Voice as the microphone in the meeting app. Orra speaks one translation after another, and waits while you dictate."))
            if !speech.canSpeak {
                note(Text("This build of Orra has no voice model."))
            } else if !translationIsOn {
                note(Text("Turn on Translation to use this."))
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
            .help(Text("Orra never speaks into the speakers on its own. Without Orra Voice, pick a device here, such as a loopback device a meeting app can use as its microphone."))
            Toggle(isOn: Binding(
                get: { speech.alsoPastes },
                set: { speech.setAlsoPastes($0) }
            )) {
                Label("Also paste the translated text", systemImage: "doc.on.clipboard")
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
        } header: {
            Text("Speak Translation")
        } footer: {
            Text("Use a recording of your own voice only. Orra keeps the voice sample in memory until it quits and never saves it. The other side hears a synthesized voice, so let them know.")
                .foregroundStyle(.secondary)
        }
        .onAppear { outputs = AudioOutput.all() }
        .fileImporter(isPresented: $isChoosingVoice, allowedContentTypes: [.audio]) { result in
            guard case .success(let url) = result else { return }
            Task {
                let scoped = url.startAccessingSecurityScopedResource()
                defer {
                    if scoped { url.stopAccessingSecurityScopedResource() }
                }
                do {
                    speech.useVoice(try await VoiceSample.read(from: url))
                } catch VoiceSample.ReadError.tooShort {
                    speech.reportVoiceProblem(String(localized: "The voice sample must be at least \(Int(VoiceSample.minimumSeconds)) seconds long."))
                } catch {
                    speech.reportVoiceProblem(String(localized: "Orra could not read this audio file."))
                }
            }
        }
    }

    /// The first choice: Orra Voice when it is installed, nothing otherwise.
    private var automaticLabel: String {
        outputs.contains(where: \.isOrraVoice)
            ? String(localized: "Automatic (\(AudioOutput.orraVoiceName))")
            : String(localized: "Automatic (Orra Voice is not installed)")
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
        if let seconds = speech.voiceSeconds {
            "\(Int(seconds.rounded())) seconds, in memory until Orra quits."
        } else {
            "None. The voice model speaks in its own voice."
        }
    }
}
