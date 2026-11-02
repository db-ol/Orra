import AppKit
import CoreGraphics
import Foundation
import os

/// Whether the screen is locked, for Live Captions, which let go of the microphone while it
/// is. Closures, so tests pass a fake and never read or watch the real lock. MeetingCaptions
/// calls both on the main actor.
///
/// Locked means that the screen is locked, or that the user's session is switched away, as
/// with fast user switching or Switch to Login Window, since the user is not in front of it
/// then either.
nonisolated struct ScreenLockSource: Sendable {
    /// Whether the window server's session says now that the screen is locked, see
    /// `ScreenLock.isLocked(_:)`. A session that does not tell a lock reads as unlocked.
    var isLocked: @Sendable () -> Bool
    /// Calls its argument on the main actor with whether the screen is locked, after each
    /// note of a lock, an unlock or a switch of the session, until the object it returns is
    /// released. Two calls in a row may say the same.
    var watch: @Sendable (_ onChange: @escaping @MainActor (Bool) -> Void) -> AnyObject?

    static func live() -> ScreenLockSource {
        ScreenLockSource(
            isLocked: { ScreenLock.isLocked(ScreenLock.session()) },
            watch: { onChange in
                MainActor.assumeIsolated {
                    ScreenLockWatch(onChange: onChange)
                }
            }
        )
    }

    /// A screen that never locks, for tests and previews, and for the copy of Orra that
    /// hosts the tests.
    static let unlocked = ScreenLockSource(isLocked: { false }, watch: { _ in nil })
}

/// What tells a locked screen: two notes macOS posts, and the window server's session.
/// Pure functions of the session, so tests read made up ones.
nonisolated enum ScreenLock {
    /// Posted by macOS to every app when the screen locks and when it unlocks. Not
    /// documented, and used by many apps for years. Any process can post them, so captions
    /// take an unlock only once the session agrees, see MeetingCaptions.
    static let didLock = Notification.Name("com.apple.screenIsLocked")
    static let didUnlock = Notification.Name("com.apple.screenIsUnlocked")

    /// The window server's dictionary of the current session, nil without one.
    static func session() -> [String: Any]? {
        CGSessionCopyCurrentDictionary() as? [String: Any]
    }

    /// Whether the session says that the screen is locked. CGSSessionScreenIsLocked is not
    /// documented, like the kCGSSessionSecureInputPID that SecureInput reads. It was true
    /// while the screen was locked on macOS 27.2. A session without it reads as unlocked.
    static func screenIsLocked(_ session: [String: Any]?) -> Bool {
        session?["CGSSessionScreenIsLocked"] as? Bool == true
    }

    /// Whether the session is the one in front, by the documented kCGSessionOnConsoleKey.
    /// A session without the key counts as in front.
    static func isOnConsole(_ session: [String: Any]?) -> Bool {
        session?[kCGSessionOnConsoleKey] as? Bool != false
    }

    /// Whether captions take the screen as locked: the screen is locked, or the session is
    /// switched away. No session reads as unlocked.
    static func isLocked(_ session: [String: Any]?) -> Bool {
        screenIsLocked(session) || !isOnConsole(session)
    }
}

/// What the watch knows of the lock, from the notes in the order they come: whether the
/// screen is locked and whether the user's session is in front. Pure, so tests feed it the
/// notes in any order.
nonisolated struct ScreenLockFlags: Equatable, Sendable {
    private(set) var screenLocked: Bool
    private(set) var onConsole: Bool

    /// As the session is now, so captions made while the screen is locked, or in a session
    /// that is switched away, start out locked.
    init(session: [String: Any]?) {
        screenLocked = ScreenLock.screenIsLocked(session)
        onConsole = ScreenLock.isOnConsole(session)
    }

    /// Whether captions take the screen as locked.
    var isLocked: Bool {
        screenLocked || !onConsole
    }

    mutating func screenDidLock() {
        screenLocked = true
    }

    mutating func screenDidUnlock() {
        screenLocked = false
    }

    /// The session was switched away, for another user or the login window.
    mutating func sessionDidResignActive() {
        onConsole = false
    }

    /// The session is in front again. A switch back may come without an unlock note, so
    /// the session is read again, only to clear the lock: a read that still says locked
    /// right after an unlock note never locks again what the note unlocked.
    mutating func sessionDidBecomeActive(session: [String: Any]?) {
        onConsole = true
        if !ScreenLock.screenIsLocked(session) {
            screenLocked = false
        }
    }
}

/// Watches the notes of a lock and of a switch of the session, and reports after each one
/// whether captions take the screen as locked, until it is released. Each note and what it
/// gives go to the log, so a note that never came can be told from a start that failed.
///
/// The lock and the unlock come as distributed notifications. AppKit holds those back while
/// the app is not active unless the observer asks for immediate delivery, and Orra, a menu
/// bar app whose caption panel does not activate it, is almost never active, so both ask
/// for `.deliverImmediately`. Apple's DistributedNotificationCenter says that they arrive on
/// the main thread, and that they may come late or be dropped, which is why MeetingCaptions
/// also looks at the session. A switch of the session comes from NSWorkspace.
final class ScreenLockWatch: NSObject {
    private let onChange: @MainActor (Bool) -> Void
    private var flags: ScreenLockFlags
    /// Unsafe only so deinit can remove them. Set once, in init on the main actor.
    nonisolated(unsafe) private var observers: [any NSObjectProtocol] = []

    init(onChange: @escaping @MainActor (Bool) -> Void) {
        self.onChange = onChange
        flags = ScreenLockFlags(session: ScreenLock.session())
        super.init()
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(self, selector: #selector(screenDidLock(_:)), name: ScreenLock.didLock, object: nil, suspensionBehavior: .deliverImmediately)
        distributed.addObserver(self, selector: #selector(screenDidUnlock(_:)), name: ScreenLock.didUnlock, object: nil, suspensionBehavior: .deliverImmediately)
        let workspace = NSWorkspace.shared.notificationCenter
        observers = [
            workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.note("the session was switched away") { $0.sessionDidResignActive() }
                }
            },
            workspace.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.note("the session is back") { $0.sessionDidBecomeActive(session: ScreenLock.session()) }
                }
            },
        ]
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    @objc private func screenDidLock(_ notification: Notification) {
        note("the screen locked") { $0.screenDidLock() }
    }

    @objc private func screenDidUnlock(_ notification: Notification) {
        note("the screen unlocked") { $0.screenDidUnlock() }
    }

    private func note(_ name: String, _ change: (inout ScreenLockFlags) -> Void) {
        change(&flags)
        Logger.captions.notice("Screen lock note: \(name, privacy: .public), locked \(self.flags.isLocked, privacy: .public)")
        onChange(flags.isLocked)
    }
}
