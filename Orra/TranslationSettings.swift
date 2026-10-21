import SwiftUI

/// Translation, a page of Settings: the switch of the translation key, how the key works
/// in its mode, what it translates into, and where the model stands while it downloads or
/// loads. The key itself is chosen under Keys on General, next to the talk key, since
/// picking one can swap the two. Change… here leads there.
struct TranslationSettings: View {
    let pushToTalk: PushToTalkController
    let cleanup: TextCleanup

    var body: some View {
        Form {
            Section {
                TranslationRow(cleanup: cleanup)
                TranslationKeyRow(pushToTalk: pushToTalk)
                    // The key does nothing while translation is off, and its field under Keys
                    // is off too.
                    .disabled(!cleanup.translationIsOn)
                // Automatic, English and the dictation language, then the two outside the
                // pair as Beta.
                Picker(selection: Binding(
                    get: { cleanup.translationDirection },
                    set: { cleanup.setTranslationDirection($0) }
                )) {
                    ForEach(TranslationDirection.choices(for: pushToTalk.dictationLanguage), id: \.self) { direction in
                        direction.choiceTitle(for: pushToTalk.dictationLanguage).tag(direction)
                    }
                } label: {
                    DescribedLabel(
                        title: "Translate into",
                        detail: cleanup.translationDirection.detail(for: pushToTalk.dictationLanguage),
                        systemImage: "arrow.left.arrow.right"
                    )
                }
                .pickerStyle(.radioGroup)
                .disabled(!cleanup.translationIsOn)
                if cleanup.translationIsOn {
                    ModelStatusRow(cleanup: cleanup, use: .translation, symbol: "translate")
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Translation uses the local model of Clean Up Text on this Mac, with about 4 GB of memory, also while cleanup is off. A dictation that is too long, or a translation that fails Orra's checks, is pasted as you said it.")
                    Text("Live Captions have their own language, on the Meeting Interpretation page.")
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
                detail: "Orra pastes what you said in another language.",
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

/// The translation key with how it works in its mode, such as "Press right Option to
/// translate, and again to finish", and Change…, which opens General at Keys, where the
/// key and its mode are set.
private struct TranslationKeyRow: View {
    let pushToTalk: PushToTalkController
    @Environment(\.interfaceLocale) private var interfaceLocale

    var body: some View {
        LabeledContent {
            Button("Change…") {
                SettingsWindow.show(.general, section: .keys)
            }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Translation key")
                    Text(verbatim: pushToTalk.translateHint(in: interfaceLocale))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "character.bubble")
            }
        }
    }
}

extension TranslationTarget {
    /// The name in the pickers of Translate into, of the caption window and of Translate
    /// captions into.
    var title: LocalizedStringKey {
        switch self {
        case .english: "English"
        case .chinese: "Chinese"
        case .japanese: "Japanese"
        case .spanish: "Spanish"
        }
    }
}

extension TranslationDirection {
    /// The name in the picker, Automatic or the language, see TranslationTarget.title.
    var title: LocalizedStringKey {
        switch self {
        case .automatic: "Automatic"
        case .english: TranslationTarget.english.title
        case .chinese: TranslationTarget.chinese.title
        case .japanese: TranslationTarget.japanese.title
        case .spanish: TranslationTarget.spanish.title
        }
    }

    /// The name in the picker for a user who dictates in `language`, with Beta for a
    /// target outside the pair, see TranslationDirection.fits(_:).
    func choiceTitle(for language: DictationLanguage) -> Text {
        fits(language) ? Text(title) : Text("\(Text(title)) (Beta)")
    }

    /// What the choice does for a user who dictates in Chinese, under the picker.
    var detail: LocalizedStringKey {
        detail(for: .chinese)
    }

    /// What the choice does for a user who dictates in `language`, under the picker. A
    /// target outside the pair says that the dictation language goes through English, see
    /// TranslationPlan.
    func detail(for language: DictationLanguage) -> LocalizedStringKey {
        switch (self, language) {
        case (.automatic, .japanese): "Japanese is translated into English, and English into Japanese. Mixed text goes by the language most of it is in, and text in another script, such as Korean, is translated into English."
        case (.automatic, .spanish): "Spanish is translated into English, and English into Spanish. Mixed text goes by the language most of it is in, and text in another script, such as Korean, is translated into English."
        case (.automatic, _): "Chinese is translated into English, and English into Chinese. Mixed text goes by the language most of it is in."
        case (.english, _): "Everything you say is pasted in English."
        case (.chinese, .japanese): "Everything you say is pasted in Chinese. Japanese goes into English first and then into Chinese, which takes about twice as long. Common English terms, such as PR or iPhone, may stay in English."
        case (.chinese, .spanish): "Everything you say is pasted in Chinese. Spanish goes into English first and then into Chinese, which takes about twice as long. Common English terms, such as PR or iPhone, may stay in English."
        case (.chinese, _): "Everything you say is pasted in Chinese. Common English terms, such as PR or iPhone, may stay in English."
        case (.japanese, .chinese): "Everything you say is pasted in Japanese. Chinese goes into English first and then into Japanese, which takes about twice as long. Common English terms, such as PR or iPhone, may stay in English."
        case (.japanese, .spanish): "Everything you say is pasted in Japanese. Spanish goes into English first and then into Japanese, which takes about twice as long. Common English terms, such as PR or iPhone, may stay in English."
        case (.japanese, _): "Everything you say is pasted in Japanese. Common English terms, such as PR or iPhone, may stay in English."
        case (.spanish, .chinese): "Everything you say is pasted in Spanish. Chinese goes into English first and then into Spanish, which takes about twice as long. Common English terms, such as PR or iPhone, may stay in English."
        case (.spanish, .japanese): "Everything you say is pasted in Spanish. Japanese goes into English first and then into Spanish, which takes about twice as long. Common English terms, such as PR or iPhone, may stay in English."
        case (.spanish, _): "Everything you say is pasted in Spanish. Common English terms, such as PR or iPhone, may stay in English."
        }
    }
}
