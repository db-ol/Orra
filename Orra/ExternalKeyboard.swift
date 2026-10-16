import Foundation
import IOKit

/// Tells an external keyboard from the Mac's own by the properties of a HID device in the
/// IOKit registry. Reading the registry needs no permission, unlike opening the device,
/// which Orra never does. Which key comes from which keyboard is never asked.
nonisolated enum ExternalKeyboard {
    /// The transports of keyboards that plug in or pair, as `ioreg -r -c IOHIDDevice -l`
    /// shows them. The Mac's own keyboard uses FIFO or SPI, and other built in devices
    /// Audio, SPU or AID. A virtual keyboard, such as one a key remapping app creates, has
    /// none of these and does not count either.
    static let externalTransports: Set<String> = ["usb", "bluetooth", "bluetooth low energy", "bluetoothlowenergy"]

    /// Whether a HID device with these registry properties is an external keyboard: its
    /// primary usage is Keyboard (page 1, usage 6) of the Generic Desktop page, it is not
    /// marked Built-In, and it is connected by USB or Bluetooth. A mouse that also reports
    /// a keyboard usage among its other usages has a pointer as its primary usage and does
    /// not count. A receiver that reports a keyboard as its primary usage counts, even when
    /// only a mouse is paired to it, since the registry cannot tell.
    static func isExternalKeyboard(_ properties: [String: Any]) -> Bool {
        guard (properties["PrimaryUsagePage"] as? Int) == 1, (properties["PrimaryUsage"] as? Int) == 6 else { return false }
        if (properties["Built-In"] as? Bool) == true { return false }
        let transport = (properties["Transport"] as? String ?? "").lowercased()
        guard externalTransports.contains(transport) else { return false }
        // MacBooks with an Intel processor connect their own keyboard over USB, and some do
        // not mark it Built-In.
        if let product = properties["Product"] as? String, product.localizedCaseInsensitiveContains("Apple Internal") {
            return false
        }
        return true
    }

    /// The properties `isExternalKeyboard(_:)` reads, from the registry entry of one HID
    /// device.
    static func properties(of service: io_service_t) -> [String: Any] {
        var properties: [String: Any] = [:]
        for key in ["PrimaryUsagePage", "PrimaryUsage", "Built-In", "Transport", "Product"] {
            if let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() {
                properties[key] = value
            }
        }
        return properties
    }
}

/// Follows whether an external keyboard is connected, at launch and when one is connected
/// or removed later, through IOKit registry notifications on the main run loop. Reads
/// registry properties only and never opens a device, so it needs no permission and never
/// sees a key press.
final class ExternalKeyboardMonitor {
    /// Whether at least one external keyboard is connected.
    private(set) var isConnected = false
    /// Called on the main thread after `isConnected` changed.
    var onChange: () -> Void = {}
    /// The registry entry IDs of the external keyboards connected now.
    private var keyboards: Set<UInt64> = []
    /// Unsafe only so deinit can release it. It is used on the main thread alone.
    nonisolated(unsafe) private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []

    /// Starts following the keyboards and reads the ones connected now. Calling it again
    /// does nothing.
    func start() {
        guard port == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let notifications: [(String, IOServiceMatchingCallback)] = [
            (kIOFirstMatchNotification, externalKeyboardAdded),
            (kIOTerminatedNotification, externalKeyboardRemoved),
        ]
        for (notification, callback) in notifications {
            var iterator: io_iterator_t = 0
            guard IOServiceAddMatchingNotification(port, notification, IOServiceMatching("IOHIDDevice"), callback, context, &iterator) == KERN_SUCCESS else { continue }
            iterators.append(iterator)
            // Reading the devices there now also arms the notification.
            if notification == kIOFirstMatchNotification {
                added(iterator)
            } else {
                removed(iterator)
            }
        }
    }

    /// Devices that appeared. Internal for the callback.
    func added(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard ExternalKeyboard.isExternalKeyboard(ExternalKeyboard.properties(of: service)) else { continue }
            var id: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS {
                keyboards.insert(id)
            }
        }
        update()
    }

    /// Devices that went away. Internal for the callback.
    func removed(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var id: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS {
                keyboards.remove(id)
            }
        }
        update()
    }

    /// Stops following the keyboards, once the tip is answered and nothing needs them any
    /// more. `isConnected` keeps its last value. Calling it again does nothing.
    func stop() {
        Self.release(port: port, iterators: iterators)
        port = nil
        iterators = []
    }

    deinit {
        Self.release(port: port, iterators: iterators)
    }

    /// Removes the notifications, so the callbacks never reach a monitor that is gone.
    /// Destroying the port also removes its run loop source.
    nonisolated private static func release(port: IONotificationPortRef?, iterators: [io_iterator_t]) {
        for iterator in iterators {
            IOObjectRelease(iterator)
        }
        if let port {
            IONotificationPortDestroy(port)
        }
    }

    private func update() {
        let connected = !keyboards.isEmpty
        guard connected != isConnected else { return }
        isConnected = connected
        onChange()
    }
}

/// The C callbacks of the registry notifications. Their run loop source is on the main run
/// loop, so they run on the main thread, which `assumeIsolated` checks.
nonisolated private func externalKeyboardAdded(context: UnsafeMutableRawPointer?, iterator: io_iterator_t) {
    guard let context else { return }
    let monitor = Unmanaged<ExternalKeyboardMonitor>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated {
        monitor.added(iterator)
    }
}

nonisolated private func externalKeyboardRemoved(context: UnsafeMutableRawPointer?, iterator: io_iterator_t) {
    guard let context else { return }
    let monitor = Unmanaged<ExternalKeyboardMonitor>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated {
        monitor.removed(iterator)
    }
}

/// The tip that offers a second talk key once an external keyboard is connected: "Some
/// external keyboards never send fn to the Mac. Talk with right Control too?" with Add and
/// No Thanks. Shown once ever. Add, No Thanks, closing it or letting it run out all mean it
/// never comes back. Orra offers it only while the talk key uses fn, no second key is set,
/// setup is complete and the welcome window is closed.
final class ExternalKeyboardTip {
    static let defaultsKey = "externalKeyboardTipShown"

    /// What decides whether the tip shows now.
    nonisolated struct Situation: Equatable, Sendable {
        var talkKey: Hotkey
        var translationKey: Hotkey
        var secondTalkKey: TalkKey?
        var externalKeyboard: Bool
        var setupComplete: Bool
        var welcomeOpen: Bool
    }

    /// The key the tip offers in this situation, or nil when it does not show. Answered or
    /// offered before, see `answered` and `offered`, it never shows.
    nonisolated static func key(for situation: Situation) -> TalkKey? {
        guard situation.talkKey.modifiers.contains(.fn), situation.secondTalkKey == nil, situation.externalKeyboard,
              situation.setupComplete, !situation.welcomeOpen else { return nil }
        return SecondTalkKey.suggested(talkKey: situation.talkKey, translationKey: situation.translationKey)
    }

    /// The text of the tip, such as "Some external keyboards never send fn to the Mac." and
    /// "Talk with right Control too?".
    nonisolated static func lines(for key: TalkKey, in locale: Locale = .interface) -> (reason: String, question: String) {
        let name = key.sentenceName(in: locale)
        return (
            String(localized: LocalizedStringResource("Some external keyboards never send fn to the Mac.", locale: locale)),
            String(localized: LocalizedStringResource("Talk with \(name) too?", locale: locale))
        )
    }

    private let defaults: UserDefaults
    private let offer: (TalkKey) -> Void
    /// Whether the tip was offered in this launch, so it shows once even before it is
    /// answered.
    private(set) var offered = false

    /// - Parameters:
    ///   - defaults: Where the tip remembers that it was answered.
    ///   - offer: Shows the tip with the key it offers.
    init(defaults: UserDefaults = .standard, offer: @escaping (TalkKey) -> Void) {
        self.defaults = defaults
        self.offer = offer
    }

    /// Whether the user has answered or closed the tip, in this launch or an earlier one.
    var answered: Bool {
        defaults.bool(forKey: Self.defaultsKey)
    }

    /// Shows the tip when the situation calls for it and it has not shown before.
    func check(_ situation: Situation) {
        guard !offered, !answered, let key = Self.key(for: situation) else { return }
        offered = true
        offer(key)
    }

    /// Whether the tip that offers `key` still fits the situation, checked again when a tip
    /// that waited is about to show and when the user clicks Add. Meanwhile the user may
    /// have set a second key, changed the talk key or removed the keyboard. A tip that no
    /// longer fits is dropped unanswered, so it may come back at a later launch.
    func stillOffers(_ key: TalkKey, in situation: Situation) -> Bool {
        !answered && Self.key(for: situation) == key
    }

    /// The user added the key, said No Thanks, closed the tip or let it run out. It never
    /// shows again.
    func answer() {
        defaults.set(true, forKey: Self.defaultsKey)
    }
}
