import SwiftUI

/// The settings window: the talk keys and the microphone.
struct SettingsView: View {
    let pushToTalk: PushToTalkController
    let inputs: AudioInputList

    var body: some View {
        Form {
            Section {
                TalkKeyToggles(keys: pushToTalk.talkKeys, setKey: pushToTalk.setTalkKey)
            } header: {
                Text("Hold to talk")
            } footer: {
                Text("Hold one of these keys on its own, speak, and let go. Right Control suits most external keyboards, whose Fn key often does not reach the Mac. fn (Globe) is the key at the bottom left of a Mac keyboard. At least one key stays on.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("Microphone", selection: Binding(
                    get: { pushToTalk.microphone?.uid ?? "" },
                    set: { uid in pushToTalk.setMicrophone(choice(forUID: uid)) }
                )) {
                    Text(MicrophoneLabels.systemDefault(inputs.defaultInput, lidClosed: inputs.lidClosed)).tag("")
                    ForEach(inputs.inputs, id: \.uid) { input in
                        Text(MicrophoneLabels.device(input, lidClosed: inputs.lidClosed)).tag(input.uid)
                    }
                    if let chosen = pushToTalk.microphone, !inputs.inputs.contains(where: { $0.uid == chosen.uid }) {
                        Text(MicrophoneLabels.missing(chosen)).tag(chosen.uid)
                    }
                }
            } header: {
                Text("Microphone")
            } footer: {
                Text("Orra records from this microphone. While it is not connected, Orra uses the system default. With the lid closed, a MacBook's own microphone is off.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { inputs.refresh() }
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The choice for a UID from the picker. The empty tag is the system default.
    private func choice(forUID uid: String) -> MicrophoneChoice? {
        guard !uid.isEmpty else { return nil }
        if let input = inputs.inputs.first(where: { $0.uid == uid }) {
            return MicrophoneChoice(uid: input.uid, name: input.name)
        }
        return pushToTalk.microphone?.uid == uid ? pushToTalk.microphone : nil
    }
}

/// One item per microphone in the menu, with a check mark on the one in use for Orra.
/// Choosing the checked item again changes nothing. A chosen microphone that is not
/// connected stays listed, so the user sees why the system default records instead.
struct MicrophoneToggles: View {
    let inputs: AudioInputList
    let chosen: MicrophoneChoice?
    let choose: (MicrophoneChoice?) -> Void

    var body: some View {
        Toggle(MicrophoneLabels.systemDefault(inputs.defaultInput, lidClosed: inputs.lidClosed), isOn: Binding(
            get: { chosen == nil },
            set: { if $0 { choose(nil) } }
        ))
        Divider()
        ForEach(inputs.inputs, id: \.uid) { input in
            Toggle(MicrophoneLabels.device(input, lidClosed: inputs.lidClosed), isOn: Binding(
                get: { chosen?.uid == input.uid },
                set: { if $0 { choose(MicrophoneChoice(uid: input.uid, name: input.name)) } }
            ))
        }
        if let chosen, !inputs.inputs.contains(where: { $0.uid == chosen.uid }) {
            Toggle(MicrophoneLabels.missing(chosen), isOn: .constant(true))
                .disabled(true)
        }
    }
}

/// One switch per talk key, in the menu and in Settings. The last key that is on cannot be
/// turned off.
struct TalkKeyToggles: View {
    let keys: Set<TalkKey>
    let setKey: (TalkKey, Bool) -> Void

    var body: some View {
        ForEach(TalkKey.allCases) { key in
            Toggle(key.name, isOn: Binding(
                get: { keys.contains(key) },
                set: { setKey(key, $0) }
            ))
            .disabled(keys == [key])
        }
    }
}

#Preview {
    SettingsView(
        pushToTalk: PushToTalkController(
            capture: .live(),
            transcription: .qwen3(),
            insert: { _ in .nothingToInsert }
        ),
        inputs: AudioInputList { AudioInputList.Reading(inputs: [], defaultInput: nil, lidClosed: false) }
    )
}
