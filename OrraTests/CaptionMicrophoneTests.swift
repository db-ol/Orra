import Foundation
import Testing
@testable import Orra

/// The rules of the caption microphone that need no device: which input it listens to, and
/// when it starts again. Made up inputs only. No test starts CaptionMicrophone, sets up its
/// unit or asks for microphone access.
struct CaptionMicrophoneTests {
    private static let builtIn = AudioInput(id: 1, uid: "built-in", name: "MacBook Pro Microphone", isInternalMicrophone: true)
    private static let usb = AudioInput(id: 2, uid: "usb-1", name: "USB Microphone", isInternalMicrophone: false)

    private func resolve(_ preferred: String?, connected: [AudioInput], systemDefault: AudioInput?) -> AudioInput? {
        CaptionMicrophone.resolve(
            preferredInput: preferred,
            connected: { uid in connected.first { $0.uid == uid } },
            systemDefault: { systemDefault }
        )
    }

    /// The microphone a dictation would record from: the chosen one while it is connected,
    /// otherwise the system default.
    @Test func captionsListenToTheChosenMicrophoneWhileItIsConnected() {
        #expect(resolve("usb-1", connected: [Self.builtIn, Self.usb], systemDefault: Self.builtIn) == Self.usb)
        #expect(resolve("usb-1", connected: [Self.builtIn], systemDefault: Self.builtIn) == Self.builtIn)
        #expect(resolve(nil, connected: [Self.builtIn, Self.usb], systemDefault: Self.usb) == Self.usb)
        #expect(resolve("usb-1", connected: [], systemDefault: nil) == nil)
        #expect(resolve(nil, connected: [], systemDefault: nil) == nil)
    }

    /// A device that went away or changed, or another input to listen to, starts the
    /// microphone again. A change of the list that leaves the same input does not.
    @Test func onlyAMoveOfTheInputStartsTheMicrophoneAgain() {
        #expect(CaptionMicrophone.hasMoved(interrupted: true, listensTo: "built-in", resolved: "built-in"))
        #expect(CaptionMicrophone.hasMoved(interrupted: false, listensTo: "built-in", resolved: "usb-1"))
        #expect(CaptionMicrophone.hasMoved(interrupted: false, listensTo: "usb-1", resolved: nil))
        #expect(!CaptionMicrophone.hasMoved(interrupted: false, listensTo: "built-in", resolved: "built-in"))
    }

    /// Captions that never chose the microphone have none to use, and never ask.
    @Test func theUnavailableMicrophoneHasNoAccessAndNeverStarts() {
        let microphone = MicrophoneCaptionSource.unavailable
        #expect(microphone.access() == .notConfigured)
        #expect(throws: MicrophoneCaptionProblem.access(.notConfigured)) {
            _ = try microphone.start(nil, { _ in }, {})
        }
        #expect(microphone.watchInputs({}) == nil)
    }
}
