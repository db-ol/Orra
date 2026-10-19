import SwiftUI

/// Translation, a page of Settings: the switch of the translation key, what it translates
/// into, and where the model stands while it downloads or loads. The key itself is chosen
/// under Keys on General, next to the talk key, since picking one can swap the two.
struct TranslationSettings: View {
    let pushToTalk: PushToTalkController
    let cleanup: TextCleanup

    var body: some View {
        Form {
            Section {
                TranslationRow(cleanup: cleanup)
                // The choices of the dictation language. A choice saved for another language
                // shows as Automatic, which is what it does, and comes back with its language.
                Picker(selection: Binding(
                    get: { cleanup.translationDirection.effective(for: pushToTalk.dictationLanguage) },
                    set: { cleanup.setTranslationDirection($0) }
                )) {
                    ForEach(TranslationDirection.choices(for: pushToTalk.dictationLanguage), id: \.self) { direction in
                        Text(direction.title).tag(direction)
                    }
                } label: {
                    DescribedLabel(
                        title: "Translate into",
                        detail: cleanup.translationDirection.effective(for: pushToTalk.dictationLanguage).detail(for: pushToTalk.dictationLanguage),
                        systemImage: "arrow.left.arrow.right"
                    )
                }
                .pickerStyle(.radioGroup)
                .disabled(!cleanup.translationIsOn)
                // Where the model stands while translation is on, with its buttons. Its text
                // starts where the names of the rows above do.
                if cleanup.translationIsOn, CleanupLabels.status(cleanup.models.state, engine: cleanup.engineState, total: cleanup.models.manifest.totalBytes, use: .translation) != nil {
                    Label {
                        LocalModelStatus(cleanup: cleanup, use: .translation)
                    } icon: {
                        Image(systemName: "translate")
                            .hidden()
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Translation uses the local model of Clean Up Text on this Mac, with about 4 GB of memory, also while cleanup is off. A dictation that is too long, or a translation that fails Orra's checks, is pasted as you said it.")
                    Text("Live Captions on the Meeting Interpretation page translate the same way.")
                }
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Translation")
    }
}

/// The switch for translation with the translation key. While the model is on its way,
/// the row under the target picker says where it stands.
private struct TranslationRow: View {
    @Bindable var cleanup: TextCleanup

    var body: some View {
        let models = cleanup.models
        let total = models.manifest.totalBytes
        Toggle(isOn: Binding(
            get: { cleanup.translationIsOn },
            set: { $0 ? cleanup.turnOnTranslation() : cleanup.turnOffTranslation() }
        )) {
            DescribedLabel(
                title: "Translation",
                detail: "Hold the translation key, speak, and let go. Orra pastes what you said in another language.",
                systemImage: "translate"
            )
        }
        // Off while Orra looks for the model on disk, a moment at launch.
        .disabled(!cleanup.translationIsOn && !cleanup.canTurnOn)
        .help(Text("Dictations over \(TranslationStep.maximumLength) characters are pasted without translation, and so is a translation that fails Orra's checks or takes too long, so nothing you say is lost.") + Text(verbatim: "\n") + Text("Paste Original Text in the Orra menu brings back the text from before the translation, and Copy Last Dictation copies the translation.") + Text(verbatim: "\n") + Text("Orra never learns corrections from a translated paste."))
        .alert("Download the model for translation?", isPresented: $cleanup.isConfirmingTranslationDownload) {
            Button(CleanupLabels.downloadButton(models.state, total: total)) {
                cleanup.confirmTranslationDownload()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The model comes from Hugging Face or a mirror. Your text stays on this Mac.")
        }
    }
}

extension TranslationDirection {
    /// The name in the picker.
    var title: LocalizedStringKey {
        switch self {
        case .automatic: "Automatic"
        case .english: "English"
        case .chinese: "Chinese"
        case .japanese: "Japanese"
        case .spanish: "Spanish"
        }
    }

    /// What the choice does for a user who dictates in Chinese, under the picker.
    var detail: LocalizedStringKey {
        detail(for: .chinese)
    }

    /// What the choice does for a user who dictates in `language`, under the picker.
    func detail(for language: DictationLanguage) -> LocalizedStringKey {
        switch (self, language) {
        case (.automatic, .japanese): "Japanese is translated into English, and English into Japanese. Mixed text goes by the language most of it is in, and text in another script, such as Korean, is translated into English."
        case (.automatic, .spanish): "Spanish is translated into English, and English into Spanish. Mixed text goes by the language most of it is in, and text in another script, such as Korean, is translated into English."
        case (.automatic, _): "Chinese is translated into English, and English into Chinese. Mixed text goes by the language most of it is in."
        case (.english, _): "Everything you say is pasted in English."
        case (.chinese, _): "Everything you say is pasted in Chinese. Common English terms, such as PR or iPhone, may stay in English."
        case (.japanese, _): "Everything you say is pasted in Japanese. Common English terms, such as PR or iPhone, may stay in English."
        case (.spanish, _): "Everything you say is pasted in Spanish. Common English terms, such as PR or iPhone, may stay in English."
        }
    }
}
