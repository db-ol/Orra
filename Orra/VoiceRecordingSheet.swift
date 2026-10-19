import SwiftUI
import UniformTypeIdentifiers

/// The sheet that records a voice sample: a script to read aloud, a big Record and Stop
/// button with a meter and the time, then Play Back, Re-record and Use This Recording.
/// Import an Audio File stays as a smaller way for a clip the user already has.
struct VoiceRecordingSheet: View {
    let recording: VoiceRecording
    /// Why recording cannot start now, nil when it can.
    let blocker: LocalizedStringKey?
    /// Remember my voice as it is in Settings, nil to hide the checkbox. The checkbox
    /// applies only with Use This Recording or an imported file, so Cancel changes
    /// nothing.
    let remembersVoice: Bool?
    /// Takes the recorded sample and the checkbox, nil while it is hidden, then the sheet
    /// closes.
    let use: (VoiceSample, Bool?) -> Void
    /// Takes an audio file the user picked and the checkbox, then the sheet closes.
    let importFile: (URL, Bool?) -> Void
    let close: () -> Void
    @State private var isImporting = false
    @State private var remember: Bool

    init(
        recording: VoiceRecording,
        blocker: LocalizedStringKey?,
        remembersVoice: Bool?,
        use: @escaping (VoiceSample, Bool?) -> Void,
        importFile: @escaping (URL, Bool?) -> Void,
        close: @escaping () -> Void
    ) {
        self.recording = recording
        self.blocker = blocker
        self.remembersVoice = remembersVoice
        self.use = use
        self.importFile = importFile
        self.close = close
        _remember = State(initialValue: remembersVoice ?? false)
    }

    /// The checkbox, nil while it is hidden.
    private var chosenRemember: Bool? {
        remembersVoice.map { _ in remember }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Record a Voice Sample")
                .font(.headline)
            Text("Read this aloud in your usual voice, in a quiet place. Orra uses up to \(Int(VoiceSample.maximumSeconds)) seconds.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Script language", selection: Binding(
                get: { recording.scriptLanguage },
                set: { recording.scriptLanguage = $0 }
            )) {
                ForEach(recording.scriptLanguages, id: \.self) { language in
                    Text(verbatim: VoiceScript.name(of: language)).tag(language)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(recording.isRecording)
            Text(verbatim: recording.script)
                .font(.title3)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.6)))
            HStack(spacing: 14) {
                recordButton
                if recording.phase == .recorded {
                    Button {
                        recording.togglePlayback()
                    } label: {
                        if recording.isPlaying {
                            Label("Stop", systemImage: "stop.fill")
                        } else {
                            Label("Play Back", systemImage: "play.fill")
                        }
                    }
                    .controlSize(.large)
                    .disabled(!recording.canPlayBack)
                }
                Spacer()
                IndicatorBars(heights: IndicatorBars.heights(level: recording.level), color: recording.phase == .recording ? .red : .secondary)
                    .animation(.linear(duration: 0.08), value: recording.level)
                    .accessibilityHidden(true)
                Text(verbatim: Self.clock(recording.elapsed))
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(recording.isRecording ? .primary : .secondary)
            }
            status
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 32, alignment: .topLeading)
            if remembersVoice != nil {
                Toggle(isOn: $remember) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Remember my voice")
                        Text(RememberVoiceText.detail(on: remember))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.checkbox)
            }
            HStack {
                Button("Import an Audio File…") {
                    isImporting = true
                }
                .buttonStyle(.link)
                .disabled(recording.isRecording)
                Spacer()
                Button("Cancel", role: .cancel) {
                    close()
                }
                .keyboardShortcut(.cancelAction)
                Button("Use This Recording") {
                    if let sample = recording.take() {
                        use(sample, chosenRemember)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(recording.phase != .recorded)
            }
        }
        .padding(20)
        .frame(width: 480)
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.audio]) { result in
            guard case .success(let url) = result else { return }
            importFile(url, chosenRemember)
        }
    }

    /// Record while nothing is recorded, Stop while recording, Re-record after.
    @ViewBuilder private var recordButton: some View {
        if recording.isRecording {
            Button {
                recording.stop()
            } label: {
                Label("Stop", systemImage: "stop.circle.fill")
                    .frame(minWidth: 110)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .disabled(recording.phase != .recording)
        } else {
            Button {
                recording.start()
            } label: {
                Group {
                    if hasTaken {
                        Label("Re-record", systemImage: "record.circle")
                    } else {
                        Label("Record", systemImage: "record.circle")
                    }
                }
                .frame(minWidth: 110)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(blocker != nil)
        }
    }

    /// Whether a recording was made, so the button offers to make another.
    private var hasTaken: Bool {
        switch recording.phase {
        case .idle, .starting, .recording, .stopping: false
        case .recorded, .tooShort, .failed: true
        }
    }

    @ViewBuilder private var status: some View {
        if let blocker, !recording.isRecording {
            Text(blocker)
        } else {
            switch recording.phase {
            case .idle:
                Text("Click Record, then read the text above.")
            case .starting, .recording:
                Text("Recording. Click Stop when you have read it all. Recording stops by itself after \(Int(VoiceRecording.maximumSeconds)) seconds.")
            case .stopping:
                Text(verbatim: "")
            case .recorded:
                if recording.stoppedAtLimit {
                    Text("Recording stopped after \(Int(VoiceRecording.maximumSeconds)) seconds. Play it back to check it, then use it.")
                } else {
                    Text("Play it back to check it, then use it.")
                }
            case .tooShort:
                Text("The voice sample must be at least \(Int(VoiceSample.minimumSeconds)) seconds long.")
            case .failed(let message):
                Text(verbatim: message)
            }
        }
    }

    /// Minutes and seconds, such as 0:07.
    static func clock(_ seconds: Double) -> String {
        let whole = max(Int(seconds), 0)
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}
