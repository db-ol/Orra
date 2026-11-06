import CoreGraphics
import Foundation
import Testing
@testable import Orra

/// How captions tell a locked screen from the window server's session and from the notes
/// of a lock, with made up sessions only.
struct ScreenLockTests {
    private static let screenIsLocked = "CGSSessionScreenIsLocked"
    private static let onConsole = kCGSessionOnConsoleKey
    private static var unlocked: [String: Any] {
        [onConsole: true]
    }

    private static var locked: [String: Any] {
        [screenIsLocked: true, onConsole: true]
    }

    @Test func theSessionTellsALockedScreenAndASessionSwitchedAway() {
        #expect(ScreenLock.screenIsLocked(Self.locked))
        #expect(ScreenLock.isOnConsole(Self.locked))
        #expect(ScreenLock.isLocked(Self.locked))
        // Another user's session in front, or the login window.
        let away: [String: Any] = [Self.onConsole: false]
        #expect(!ScreenLock.screenIsLocked(away))
        #expect(!ScreenLock.isOnConsole(away))
        #expect(ScreenLock.isLocked(away))
        #expect(!ScreenLock.isLocked(Self.unlocked))
        #expect(!ScreenLock.isLocked([Self.screenIsLocked: false, Self.onConsole: true]))
        // The window server gives booleans as NSNumber.
        #expect(ScreenLock.isLocked([Self.screenIsLocked: NSNumber(value: true), Self.onConsole: NSNumber(value: true)]))
        #expect(!ScreenLock.isLocked([Self.screenIsLocked: NSNumber(value: false), Self.onConsole: NSNumber(value: true)]))
        // A session without the keys, and none at all, count as unlocked and in front.
        #expect(ScreenLock.isOnConsole([:]))
        #expect(!ScreenLock.isLocked([:]))
        #expect(ScreenLock.isOnConsole(nil))
        #expect(!ScreenLock.isLocked(nil))
    }

    /// The watch follows the notes in the order they come. A switch of the session counts
    /// as locked, and a locked screen stays locked until its own unlock. A switch back reads
    /// the session again, but only to clear the lock.
    @Test func theWatchFollowsTheNotesInTheOrderTheyCome() {
        // A lock and an unlock.
        var flags = ScreenLockFlags(session: Self.unlocked)
        #expect(!flags.isLocked)
        flags.screenDidLock()
        #expect(flags.isLocked)
        flags.screenDidUnlock()
        #expect(!flags.isLocked)
        // A lock, a switch away, the unlock and the switch back.
        flags.screenDidLock()
        flags.sessionDidResignActive()
        #expect(flags.isLocked)
        flags.screenDidUnlock()
        #expect(flags.isLocked)
        flags.sessionDidBecomeActive(session: Self.unlocked)
        #expect(!flags.isLocked)
        // A switch back to a screen that is still locked, then the unlock.
        flags.screenDidLock()
        flags.sessionDidResignActive()
        flags.sessionDidBecomeActive(session: Self.locked)
        #expect(flags.isLocked)
        flags.screenDidUnlock()
        #expect(!flags.isLocked)
        // The unlock just before a switch back whose read still says locked stays unlocked.
        flags.screenDidLock()
        flags.sessionDidResignActive()
        flags.screenDidUnlock()
        flags.sessionDidBecomeActive(session: Self.locked)
        #expect(!flags.isLocked)
        // A switch back that comes without an unlock note, which the read ends.
        flags.screenDidLock()
        flags.sessionDidResignActive()
        flags.sessionDidBecomeActive(session: Self.unlocked)
        #expect(!flags.isLocked)
        // A switch away with no note of a lock.
        flags.sessionDidResignActive()
        #expect(flags.isLocked)
        flags.sessionDidBecomeActive(session: Self.unlocked)
        #expect(!flags.isLocked)
    }

    /// The watch starts from the session as it is, so captions made while the screen is
    /// locked or the session is switched away start out locked.
    @Test func theWatchStartsFromTheSession() {
        #expect(ScreenLockFlags(session: Self.locked).isLocked)
        #expect(!ScreenLockFlags(session: Self.unlocked).isLocked)
        #expect(!ScreenLockFlags(session: nil).isLocked)
        var away = ScreenLockFlags(session: [Self.onConsole: false])
        #expect(away.isLocked)
        away.sessionDidBecomeActive(session: Self.unlocked)
        #expect(!away.isLocked)
    }
}
