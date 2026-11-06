import Foundation
import os
import Synchronization
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

    /// Made up devices for the move check, which it reads on the capture's queue, and the
    /// moves it reported.
    private final class Devices: Sendable {
        private struct State {
            var connected: [AudioInput]
            var systemDefault: AudioInput?
            var moves = 0
        }

        private let state: OSAllocatedUnfairLock<State>

        init(connected: [AudioInput], systemDefault: AudioInput?) {
            state = OSAllocatedUnfairLock(initialState: State(connected: connected, systemDefault: systemDefault))
        }

        var moves: Int {
            state.withLock { $0.moves }
        }

        func set(connected: [AudioInput], systemDefault: AudioInput?) {
            state.withLock {
                $0.connected = connected
                $0.systemDefault = systemDefault
            }
        }

        func check(listensTo bound: AudioInput, preferredInput: String?) -> MicrophoneMoveCheck {
            MicrophoneMoveCheck(
                listensTo: bound,
                preferredInput: preferredInput,
                connected: { [self] uid in state.withLock { $0.connected.first { $0.uid == uid } } },
                systemDefault: { [self] in state.withLock { $0.systemDefault } },
                moved: { [self] in state.withLock { $0.moves += 1 } }
            )
        }
    }

    /// The device captions listen to went away, changed its rate or lost its inputs: the
    /// microphone starts again, once, however often the drain timer looks.
    @Test func anInterruptedDeviceIsOneMove() {
        let devices = Devices(connected: [Self.builtIn], systemDefault: Self.builtIn)
        let check = devices.check(listensTo: Self.builtIn, preferredInput: nil)
        check.look()
        #expect(devices.moves == 0)
        check.interrupted.set()
        check.look()
        check.look()
        #expect(devices.moves == 1)
    }

    /// A change of the devices is a move only when it changes the input to listen to, and
    /// the devices are read only after a change.
    @Test func onlyAChangeOfTheInputToListenToIsAMove() {
        let devices = Devices(connected: [Self.builtIn], systemDefault: Self.builtIn)
        let check = devices.check(listensTo: Self.builtIn, preferredInput: nil)
        // A device that comes and leaves the default input as it was, such as the private
        // aggregate device of dictation's engine.
        devices.set(connected: [Self.builtIn, Self.usb], systemDefault: Self.builtIn)
        check.devicesChanged.store(true, ordering: .releasing)
        check.look()
        #expect(devices.moves == 0)
        // A new default input, but no change reported yet.
        devices.set(connected: [Self.builtIn, Self.usb], systemDefault: Self.usb)
        check.look()
        #expect(devices.moves == 0)
        check.devicesChanged.store(true, ordering: .releasing)
        check.look()
        check.devicesChanged.store(true, ordering: .releasing)
        check.look()
        #expect(devices.moves == 1)
    }

    /// Captions on the system default because the chosen microphone was missing go to it
    /// once it is plugged in, and captions on the chosen one go to the default once it is
    /// unplugged.
    @Test func theChosenMicrophoneComingOrGoingIsAMove() {
        let devices = Devices(connected: [Self.builtIn], systemDefault: Self.builtIn)
        let waiting = devices.check(listensTo: Self.builtIn, preferredInput: "usb-1")
        devices.set(connected: [Self.builtIn, Self.usb], systemDefault: Self.builtIn)
        waiting.devicesChanged.store(true, ordering: .releasing)
        waiting.look()
        #expect(devices.moves == 1)
        let chosen = devices.check(listensTo: Self.usb, preferredInput: "usb-1")
        devices.set(connected: [Self.builtIn], systemDefault: Self.builtIn)
        chosen.devicesChanged.store(true, ordering: .releasing)
        chosen.look()
        #expect(devices.moves == 2)
        // No input left at all is a move too.
        let alone = devices.check(listensTo: Self.builtIn, preferredInput: nil)
        devices.set(connected: [], systemDefault: nil)
        alone.devicesChanged.store(true, ordering: .releasing)
        alone.look()
        #expect(devices.moves == 3)
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
