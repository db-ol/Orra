import Foundation
import Observation
import Synchronization
import Testing
@testable import Orra

struct MicrophoneChoiceTests {
    static let builtIn = AudioInput(id: 1, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", isInternalMicrophone: true)
    static let webcam = AudioInput(id: 2, uid: "brio-uid", name: "Brio 500", isInternalMicrophone: false)

    @Test func labelsMarkTheBuiltInMicrophoneWhileTheLidIsClosed() {
        #expect(MicrophoneLabels.systemDefault(Self.builtIn, lidClosed: true) == "System Default (MacBook Pro Microphone, lid closed)")
        #expect(MicrophoneLabels.systemDefault(Self.builtIn, lidClosed: false) == "System Default (MacBook Pro Microphone)")
        #expect(MicrophoneLabels.systemDefault(nil, lidClosed: true) == "System Default")
        #expect(MicrophoneLabels.device(Self.builtIn, lidClosed: true) == "MacBook Pro Microphone (lid closed)")
        #expect(MicrophoneLabels.device(Self.webcam, lidClosed: true) == "Brio 500")
        #expect(MicrophoneLabels.missing(MicrophoneChoice(uid: "brio-uid", name: "Brio 500")) == "Brio 500 (not connected)")
    }

    @Test func theLidWarningShowsOnlyForTheBuiltInMicrophoneInUse() {
        let warning = "The lid is closed, so the built in microphone is off"
        let brio = MicrophoneChoice(uid: "brio-uid", name: "Brio 500")
        let inputs = [Self.builtIn, Self.webcam]
        // The system default is the built in microphone.
        #expect(MicrophoneLabels.lidWarning(choice: nil, inputs: inputs, defaultInput: Self.builtIn, lidClosed: true) == warning)
        #expect(MicrophoneLabels.lidWarning(choice: nil, inputs: inputs, defaultInput: Self.builtIn, lidClosed: false) == nil)
        // The webcam is chosen and connected.
        #expect(MicrophoneLabels.lidWarning(choice: brio, inputs: inputs, defaultInput: Self.builtIn, lidClosed: true) == nil)
        // The webcam is chosen but unplugged, so the built in microphone records.
        #expect(MicrophoneLabels.lidWarning(choice: brio, inputs: [Self.builtIn], defaultInput: Self.builtIn, lidClosed: true) == warning)
        // The default is already the webcam.
        #expect(MicrophoneLabels.lidWarning(choice: nil, inputs: inputs, defaultInput: Self.webcam, lidClosed: true) == nil)
    }

    /// Records whether an observed property changed.
    final class ChangeFlag: Sendable {
        let fired = Mutex(false)
    }

    @MainActor
    @Test func theListReadsAgainOnRefreshAndTellsTheMenu() {
        let reading = Mutex(AudioInputList.Reading(inputs: [Self.builtIn], defaultInput: Self.builtIn, lidClosed: false))
        let list = AudioInputList { reading.withLock { $0 } }
        #expect(list.inputs == [Self.builtIn])
        #expect(list.lidClosed == false)

        let flag = ChangeFlag()
        withObservationTracking { _ = list.inputs } onChange: { flag.fired.withLock { $0 = true } }
        // The webcam is plugged in and the lid closed.
        reading.withLock { $0 = AudioInputList.Reading(inputs: [Self.builtIn, Self.webcam], defaultInput: Self.builtIn, lidClosed: true) }
        list.refresh()
        #expect(flag.fired.withLock { $0 })
        #expect(list.inputs == [Self.builtIn, Self.webcam])
        #expect(list.lidClosed)
    }
}

/// Uses UserDefaults suites of its own, never Orra's real settings.
struct MicrophonePreferenceTests {
    private func withDefaults(_ name: String, _ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "io.github.db-ol.OrraTests.MicrophonePreference.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @Test func nothingSavedMeansTheSystemDefault() {
        withDefaults("nothingSaved") { defaults in
            #expect(MicrophonePreference.load(from: defaults) == nil)
        }
    }

    @Test func aChoiceComesBackAndCanBeCleared() {
        withDefaults("saved") { defaults in
            let brio = MicrophoneChoice(uid: "brio-uid", name: "Brio 500")
            MicrophonePreference.save(brio, to: defaults)
            #expect(MicrophonePreference.load(from: defaults) == brio)
            MicrophonePreference.save(nil, to: defaults)
            #expect(MicrophonePreference.load(from: defaults) == nil)
        }
    }
}
