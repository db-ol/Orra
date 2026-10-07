import AppKit
import Observation

/// The microphone the user picked for Orra, remembered by Core Audio's persistent UID.
/// The name is kept as well, so the menu can still name the device while it is unplugged.
nonisolated struct MicrophoneChoice: Equatable, Sendable {
    var uid: String
    var name: String
}

/// Keeps the user's microphone in UserDefaults. No choice means the system default input.
nonisolated enum MicrophonePreference {
    static let uidKey = "microphoneUID"
    static let nameKey = "microphoneName"

    static func load(from defaults: UserDefaults = .standard) -> MicrophoneChoice? {
        guard let uid = defaults.string(forKey: uidKey), !uid.isEmpty else { return nil }
        return MicrophoneChoice(uid: uid, name: defaults.string(forKey: nameKey) ?? uid)
    }

    static func save(_ choice: MicrophoneChoice?, to defaults: UserDefaults = .standard) {
        if let choice {
            defaults.set(choice.uid, forKey: uidKey)
            defaults.set(choice.name, forKey: nameKey)
        } else {
            defaults.removeObject(forKey: uidKey)
            defaults.removeObject(forKey: nameKey)
        }
    }
}

/// The text of the microphone menu.
nonisolated enum MicrophoneLabels {
    static func systemDefault(_ input: AudioInput?, lidClosed: Bool) -> String {
        guard let input else { return String(localized: "System Default") }
        if lidClosed && input.isInternalMicrophone {
            return String(localized: "System Default (\(input.name), lid closed)")
        }
        return String(localized: "System Default (\(input.name))")
    }

    static func device(_ input: AudioInput, lidClosed: Bool) -> String {
        lidClosed && input.isInternalMicrophone ? String(localized: "\(input.name) (lid closed)") : input.name
    }

    static func missing(_ choice: MicrophoneChoice) -> String {
        String(localized: "\(choice.name) (not connected)")
    }

    /// The warning at the top of the menu, or nil. Shown when the microphone Orra would
    /// record from is the internal one and the lid is closed. Orra records from the chosen
    /// microphone while it is connected, and from the system default otherwise.
    static func lidWarning(choice: MicrophoneChoice?, inputs: [AudioInput], defaultInput: AudioInput?, lidClosed: Bool) -> String? {
        guard lidClosed else { return nil }
        let inUse = choice.flatMap { choice in inputs.first { $0.uid == choice.uid } } ?? defaultInput
        return inUse?.isInternalMicrophone == true ? String(localized: "The lid is closed, so the built in microphone is off") : nil
    }
}

/// The input devices, the system default and the lid, as the menu shows them. Read again
/// whenever a menu opens, because devices come and go and the lid opens and closes. The
/// readings are a closure, so tests never depend on this Mac's devices.
@Observable
final class AudioInputList {
    nonisolated struct Reading: Equatable, Sendable {
        var inputs: [AudioInput]
        var defaultInput: AudioInput?
        var lidClosed: Bool
    }

    private(set) var inputs: [AudioInput] = []
    private(set) var defaultInput: AudioInput?
    private(set) var lidClosed = false

    @ObservationIgnored private let read: () -> Reading
    @ObservationIgnored private var menuObserver: (any NSObjectProtocol)?

    init(read: @escaping () -> Reading) {
        self.read = read
        refresh()
    }

    static func live() -> AudioInputList {
        AudioInputList {
            Reading(inputs: AudioInput.all(), defaultInput: AudioInput.systemDefault(), lidClosed: Lid.isClosed())
        }
    }

    func refresh() {
        let reading = read()
        inputs = reading.inputs
        defaultInput = reading.defaultInput
        lidClosed = reading.lidClosed
    }

    /// Reads again each time a menu opens, Orra's menu bar menu included, so the open
    /// menu shows the current devices.
    func refreshWhenMenusOpen() {
        guard menuObserver == nil else { return }
        menuObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }
}
