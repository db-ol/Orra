import SwiftUI

/// Dictation, a page of Settings: the language the user speaks, Clean Up Text with its two
/// rules, and the two features that help recognition by reading what is on screen. The
/// model and the rules of Clean Up Text sit on the page itself, so turning one on or off
/// takes one click.
struct DictationSettings: View {
    let pushToTalk: PushToTalkController
    let cleanup: TextCleanup
    @Bindable var learning: CorrectionLearning

    var body: some View {
        Form {
            Section {
                DictationLanguageRow(pushToTalk: pushToTalk)
            } header: {
                Text("Language")
            }
            Section {
                CleanupToggle(cleanup: cleanup, language: pushToTalk.dictationLanguage)
                // Where the model stands while cleanup is on, with its buttons. Its text
                // starts where the names of the rows do.
                if cleanup.isOn, CleanupLabels.status(cleanup.models.state, engine: cleanup.engineState, total: cleanup.models.manifest.totalBytes, use: .cleanup) != nil {
                    Label {
                        LocalModelStatus(cleanup: cleanup, use: .cleanup)
                    } icon: {
                        Image(systemName: "wand.and.sparkles")
                            .hidden()
                    }
                }
                Toggle(isOn: Binding(
                    get: { pushToTalk.removesFillerWords },
                    set: { pushToTalk.setRemovesFillerWords($0) }
                )) {
                    DescribedLabel(
                        title: "Remove filler words such as um and uh",
                        detail: "Removes um, uh and erm where they only fill a pause, and the same sounds in Chinese. Words that carry meaning stay as you said them.",
                        systemImage: "text.badge.minus"
                    )
                }
                Toggle(isOn: Binding(
                    get: { pushToTalk.writesNumbersAsDigits },
                    set: { pushToTalk.setWritesNumbersAsDigits($0) }
                )) {
                    DescribedLabel(
                        title: "Write numbers as digits",
                        detail: "Numbers spoken in Chinese, such as dates, times, prices and percentages, are written as digits. Small counts, rough numbers and idioms stay in words.",
                        systemImage: "number"
                    )
                }
            } header: {
                Text("Clean Up Text")
            } footer: {
                Text("The rules run on every dictation, with or without the local model, and before it.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle(isOn: $learning.isOn) {
                    DescribedLabel(
                        title: "Learn from my corrections",
                        detail: "Reads the field you dictated into for 3 minutes after a paste and adds a misheard word you fix to your vocabulary.",
                        systemImage: "character.cursor.ibeam"
                    )
                }
                .help(Text("When this is on, Orra reads the text of the field you dictated into for up to 3 minutes after each paste, while you are in that field, never a password field. When you fix a misheard word, Orra adds the right spelling to your vocabulary and shows a notice where you can undo it. Orra keeps only the word pairs, on this Mac. It works in apps that let macOS read their text, such as Notes, Mail and Safari, but not in some editors and terminals. There, copy the right word and add it from the Orra menu."))
                if !learning.store.entries.isEmpty {
                    Button("Forget Learned Corrections") {
                        learning.removeAll()
                    }
                }
                Toggle(isOn: Binding(
                    get: { pushToTalk.usesScreenNames },
                    set: { pushToTalk.setUsesScreenNames($0) }
                )) {
                    DescribedLabel(
                        title: "Use names on screen (Beta)",
                        detail: "Reads the text before the cursor and the window title when you start a dictation, and gives the speech model the names in them.",
                        systemImage: "text.viewfinder"
                    )
                }
                .help(Text("When this is on, each time you start a dictation, Orra reads up to 1,000 characters before the cursor in the field you dictate into and the title of its window, never a password field or a password manager. It gives the speech model up to 40 names and rare words from that text along with your vocabulary, never the text itself. The text stays in memory for that dictation only and is never saved or logged. A known risk: when a name on screen sounds like the name you say, Orra may write the name on screen instead. It works in apps that let macOS read their text."))
            } header: {
                Text("Recognition")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Dictation")
    }
}

/// The switch for cleanup with the local model, with what it does, and for Japanese and
/// Spanish that it works on English sentences only. Turning it on without the model asks
/// before the download.
private struct CleanupToggle: View {
    @Bindable var cleanup: TextCleanup
    let language: DictationLanguage

    var body: some View {
        let models = cleanup.models
        let total = models.manifest.totalBytes
        let size = ModelInstaller.State.size(total)
        Toggle(isOn: Binding(
            get: { cleanup.isOn },
            set: { $0 ? cleanup.turnOn() : cleanup.turnOff() }
        )) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clean up with a local model")
                    Group {
                        Text("Removes fillers and applies spoken self corrections, such as “三点，哦不对，四点”. It needs a \(size) download and about 4 GB of memory, adds under a second to a short dictation and more to a long one, and runs on this Mac. Paste Original Text in the Orra menu brings back the text from before the cleanup.")
                        if language != .chinese {
                            Text("Clean Up Text works on English sentences only for now.")
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "wand.and.sparkles")
            }
        }
        // Off while Orra looks for the model on disk, a moment at launch.
        .disabled(!cleanup.isOn && !cleanup.canTurnOn)
        .alert("Download the cleanup model?", isPresented: $cleanup.isConfirmingDownload) {
            Button(CleanupLabels.downloadButton(models.state, total: total)) {
                cleanup.confirmDownload()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The model comes from Hugging Face or a mirror. Your text stays on this Mac.")
        }
    }
}

/// Dictation language: Chinese, Japanese or Spanish, each with English. The line under the
/// name says the two mix. For Japanese and Spanish, the switch of Clean Up Text says that
/// it takes English only.
private struct DictationLanguageRow: View {
    let pushToTalk: PushToTalkController

    var body: some View {
        Picker(selection: Binding(
            get: { pushToTalk.dictationLanguage },
            set: { pushToTalk.setDictationLanguage($0) }
        )) {
            ForEach(DictationLanguage.allCases) { language in
                language.title.tag(language)
            }
        } label: {
            DescribedLabel(
                title: "Dictation language",
                detail: "You can mix the two languages in one sentence.",
                systemImage: "character.bubble"
            )
        }
    }
}

extension DictationLanguage {
    /// The choice as Settings and the welcome window show it: its own name, which is never
    /// translated, and for a beta the word Beta in the interface language.
    var title: Text {
        isBeta ? Text("\(name) (Beta)") : Text(verbatim: name)
    }
}
