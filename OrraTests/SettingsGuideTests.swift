import AppKit
import Testing
@testable import Orra

/// The card beside System Settings: where it goes, when it shows, hides and goes away, and
/// its panel.
struct SettingsGuideTests {
    // MARK: Placement

    private let size = CGSize(width: 274, height: 200)
    /// A 1440 by 900 primary screen with a 25 point menu bar and a 70 point Dock.
    private let primary = SettingsGuidePlacement.Screen(
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visible: CGRect(x: 0, y: 70, width: 1440, height: 805)
    )

    @Test func cgCoordinatesBecomeCocoaOnes() {
        let cg = CGRect(x: 100, y: 50, width: 700, height: 600)
        #expect(SettingsGuidePlacement.cocoaRect(fromCG: cg, primaryHeight: 900) == CGRect(x: 100, y: 250, width: 700, height: 600))
        // A screen above the primary one has negative CG y and Cocoa y above its height.
        let above = CGRect(x: 0, y: -800, width: 600, height: 500)
        #expect(SettingsGuidePlacement.cocoaRect(fromCG: above, primaryHeight: 900) == CGRect(x: 0, y: 1200, width: 600, height: 500))
    }

    @Test func theCardGoesOnTheRightWithRoom() {
        let window = CGRect(x: 200, y: 175, width: 700, height: 600)
        let frame = SettingsGuidePlacement.frame(size: size, beside: window, screens: [primary])
        #expect(frame.minX == window.maxX + SettingsGuidePlacement.gap)
        #expect(frame.maxY == window.maxY - SettingsGuidePlacement.topInset)
        #expect(frame.size == size)
    }

    @Test func theCardGoesOnTheLeftWithoutRoomOnTheRight() {
        let window = CGRect(x: 600, y: 175, width: 700, height: 600)
        let frame = SettingsGuidePlacement.frame(size: size, beside: window, screens: [primary])
        #expect(frame.maxX == window.minX - SettingsGuidePlacement.gap)
        #expect(frame.maxY == window.maxY - SettingsGuidePlacement.topInset)
    }

    @Test func theCardOverlapsTheLowerRightCornerWithoutRoomOnEitherSide() {
        let window = CGRect(x: 100, y: 100, width: 1240, height: 700)
        let frame = SettingsGuidePlacement.frame(size: size, beside: window, screens: [primary])
        #expect(frame.maxX == window.maxX - SettingsGuidePlacement.cornerInset)
        #expect(frame.minY == window.minY + SettingsGuidePlacement.cornerInset)
        #expect(window.contains(frame))
    }

    @Test func theCardStaysInsideTheVisibleFrame() {
        // A short window low on the screen: the card would reach below the Dock.
        let low = CGRect(x: 200, y: 40, width: 700, height: 220)
        let raised = SettingsGuidePlacement.frame(size: size, beside: low, screens: [primary])
        #expect(raised.minY == primary.visible.minY)
        // A window under the menu bar: the card stays below it.
        let high = CGRect(x: 200, y: 400, width: 700, height: 560)
        let lowered = SettingsGuidePlacement.frame(size: size, beside: high, screens: [primary])
        #expect(lowered.maxY <= primary.visible.maxY)
        // A window reaching past the screen's right edge, with no room on the left either.
        let wide = CGRect(x: 100, y: 100, width: 1500, height: 700)
        let inside = SettingsGuidePlacement.frame(size: size, beside: wide, screens: [primary])
        #expect(inside.maxX == primary.visible.maxX)
        #expect(primary.visible.contains(inside))
    }

    @Test func theCardFollowsTheWindowsScreen() {
        // A second screen to the left of the primary one and lower, with its own Dock.
        let second = SettingsGuidePlacement.Screen(
            frame: CGRect(x: -1920, y: -300, width: 1920, height: 1080),
            visible: CGRect(x: -1920, y: -230, width: 1920, height: 1080 - 70)
        )
        let screens = [primary, second]
        // Right of the window, still on the second screen.
        let window = CGRect(x: -1700, y: 100, width: 800, height: 600)
        let frame = SettingsGuidePlacement.frame(size: size, beside: window, screens: screens)
        #expect(frame.minX == window.maxX + SettingsGuidePlacement.gap)
        #expect(second.visible.contains(frame))
        // Against the second screen's right edge: the primary screen's room on the right
        // does not count, so the card goes on the left.
        let edge = CGRect(x: -800, y: 100, width: 790, height: 600)
        let left = SettingsGuidePlacement.frame(size: size, beside: edge, screens: screens)
        #expect(left.maxX == edge.minX - SettingsGuidePlacement.gap)
        // Low on the second screen: clamped to its visible frame, which starts at -230.
        let low = CGRect(x: -1700, y: -290, width: 800, height: 300)
        let clamped = SettingsGuidePlacement.frame(size: size, beside: low, screens: screens)
        #expect(clamped.minY == second.visible.minY)
        // Across both screens, with 500 points on the primary one and 300 on the second:
        // the primary screen has more of it, so the card goes on its right.
        let across = CGRect(x: -300, y: 100, width: 800, height: 600)
        let straddling = SettingsGuidePlacement.frame(size: size, beside: across, screens: screens)
        #expect(straddling.minX == 512)
        #expect(straddling.maxY == 648)
        // On no screen: the nearest one, the primary, keeps the card inside.
        let away = CGRect(x: 3000, y: 100, width: 800, height: 600)
        let nearest = SettingsGuidePlacement.frame(size: size, beside: away, screens: screens)
        #expect(nearest.maxX == primary.visible.maxX)
        #expect(primary.visible.contains(nearest))
    }

    @Test func theCardFindsTheWindowFromCGCoordinatesOnAnotherScreen() {
        // A screen above the primary one: its windows have negative CG y.
        let above = SettingsGuidePlacement.Screen(
            frame: CGRect(x: 0, y: 900, width: 1440, height: 900),
            visible: CGRect(x: 0, y: 900, width: 1440, height: 900)
        )
        let cg = CGRect(x: 100, y: -800, width: 700, height: 600)
        let window = SettingsGuidePlacement.cocoaRect(fromCG: cg, primaryHeight: primary.frame.height)
        let frame = SettingsGuidePlacement.frame(size: size, beside: window, screens: [primary, above])
        #expect(above.visible.contains(frame))
        #expect(frame.minX == 812)
        #expect(frame.maxY == window.maxY - SettingsGuidePlacement.topInset)
    }

    @Test func theCardFindsTheWindowOnATallerScreenBelowAndToTheRight() {
        let below = SettingsGuidePlacement.Screen(
            frame: CGRect(x: 1440, y: -1000, width: 2560, height: 1440),
            visible: CGRect(x: 1440, y: -1000, width: 2560, height: 1415)
        )
        let cg = CGRect(x: 1500, y: 1000, width: 700, height: 600)
        let window = SettingsGuidePlacement.cocoaRect(fromCG: cg, primaryHeight: primary.frame.height)
        #expect(window == CGRect(x: 1500, y: -700, width: 700, height: 600))
        let frame = SettingsGuidePlacement.frame(size: size, beside: window, screens: [primary, below])
        #expect(below.visible.contains(frame))
        #expect(frame.minX == window.maxX + SettingsGuidePlacement.gap)
    }

    // MARK: Window list

    private func info(pid: Int, layer: Int = 0, _ bounds: CGRect) -> [String: Any] {
        [
            kCGWindowOwnerPID as String: pid,
            kCGWindowLayer as String: layer,
            kCGWindowBounds as String: bounds.dictionaryRepresentation as NSDictionary,
        ]
    }

    @Test func theLargestNormalWindowOfSystemSettingsCounts() {
        let main = CGRect(x: 100, y: 100, width: 715, height: 600)
        let onScreen = [
            info(pid: 7, CGRect(x: 0, y: 0, width: 1440, height: 900)),
            info(pid: 42, layer: 25, CGRect(x: 0, y: 0, width: 2000, height: 2000)),
            info(pid: 42, CGRect(x: 300, y: 300, width: 40, height: 40)),
            info(pid: 42, CGRect(x: 50, y: 50, width: 400, height: 300)),
            info(pid: 42, main),
        ]
        #expect(SettingsGuideTracker.window(onScreen: onScreen, all: onScreen, pid: 42) == .onScreen(main))
    }

    @Test func aWindowOnlyInTheFullListIsOffScreen() {
        let main = info(pid: 42, CGRect(x: 100, y: 100, width: 715, height: 600))
        #expect(SettingsGuideTracker.window(onScreen: [], all: [main], pid: 42) == .offScreen)
        #expect(SettingsGuideTracker.window(onScreen: [], all: [], pid: 42) == .none)
        #expect(SettingsGuideTracker.window(onScreen: [main], all: [main], pid: 43) == .none)
    }

    // MARK: Showing and going away

    private let bounds = CGRect(x: 100, y: 100, width: 715, height: 600)

    @Test func theCardWaitsForTheWindowThenFollowsIt() {
        var tracker = SettingsGuideTracker()
        // The Accessibility prompt comes first.
        #expect(tracker.next(at: 0, granted: false, running: false, window: .none, active: false) == .hide)
        #expect(tracker.next(at: 30, granted: false, running: true, window: .none, active: true) == .hide)
        #expect(tracker.next(at: 31, granted: false, running: true, window: .onScreen(bounds), active: true) == .show(bounds))
        let moved = bounds.offsetBy(dx: 80, dy: 20)
        #expect(tracker.next(at: 31.4, granted: false, running: true, window: .onScreen(moved), active: true) == .show(moved))
    }

    @Test func theCardGivesUpWhenTheWindowNeverAppears() {
        var tracker = SettingsGuideTracker()
        #expect(tracker.next(at: 59, granted: false, running: false, window: .none, active: false) == .hide)
        #expect(tracker.next(at: 60, granted: false, running: false, window: .none, active: false) == .dismiss)
    }

    @Test func theCardHidesWhileSystemSettingsIsAwayAndComesBack() {
        var tracker = SettingsGuideTracker()
        #expect(tracker.next(at: 1, granted: false, running: true, window: .onScreen(bounds), active: true) == .show(bounds))
        // Minimized or on another Space.
        #expect(tracker.next(at: 2, granted: false, running: true, window: .offScreen, active: true) == .hide)
        #expect(tracker.next(at: 20, granted: false, running: true, window: .offScreen, active: false) == .hide)
        // Behind another app.
        #expect(tracker.next(at: 21, granted: false, running: true, window: .onScreen(bounds), active: false) == .hide)
        #expect(tracker.next(at: 22, granted: false, running: true, window: .onScreen(bounds), active: true) == .show(bounds))
    }

    @Test func theCardGoesAwayOnceAccessIsGiven() {
        var tracker = SettingsGuideTracker()
        _ = tracker.next(at: 1, granted: false, running: true, window: .onScreen(bounds), active: true)
        #expect(tracker.next(at: 5, granted: true, running: true, window: .onScreen(bounds), active: true) == .dismiss)
    }

    @Test func theCardGoesAwayWhenSystemSettingsQuitsOrItsWindowIsGone() {
        var quits = SettingsGuideTracker()
        _ = quits.next(at: 1, granted: false, running: true, window: .onScreen(bounds), active: true)
        #expect(quits.next(at: 2, granted: false, running: false, window: .none, active: false) == .dismiss)

        var closes = SettingsGuideTracker()
        _ = closes.next(at: 1, granted: false, running: true, window: .onScreen(bounds), active: true)
        #expect(closes.next(at: 2, granted: false, running: true, window: .none, active: true) == .hide)
        #expect(closes.next(at: 4.6, granted: false, running: true, window: .none, active: true) == .hide)
        #expect(closes.next(at: 5, granted: false, running: true, window: .none, active: true) == .dismiss)

        // A window that comes back in time starts the count again.
        var back = SettingsGuideTracker()
        _ = back.next(at: 1, granted: false, running: true, window: .onScreen(bounds), active: true)
        _ = back.next(at: 2, granted: false, running: true, window: .none, active: true)
        #expect(back.next(at: 4, granted: false, running: true, window: .onScreen(bounds), active: true) == .show(bounds))
        #expect(back.next(at: 6, granted: false, running: true, window: .none, active: true) == .hide)
    }

    @Test func theCardStaysWhileSystemSettingsIsOpen() {
        // No time limit: only access or closing System Settings ends the card.
        var tracker = SettingsGuideTracker()
        #expect(tracker.next(at: 1, granted: false, running: true, window: .onScreen(bounds), active: true) == .show(bounds))
        #expect(tracker.next(at: 600, granted: false, running: true, window: .onScreen(bounds), active: true) == .show(bounds))
        #expect(tracker.next(at: 3600, granted: false, running: true, window: .offScreen, active: false) == .hide)
        #expect(tracker.next(at: 3601, granted: false, running: true, window: .onScreen(bounds), active: true) == .show(bounds))
    }

    // MARK: Panel

    @MainActor
    @Test func thePanelFloatsWithoutTakingTheFocus() {
        let panel = SettingsGuidePanel().makePanel()
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.level == .floating)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(!panel.hidesOnDeactivate)
        #expect(!panel.isVisible)
    }
}
