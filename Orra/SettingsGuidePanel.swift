import AppKit
import SwiftUI

/// A small card beside the System Settings window, with the picture of the switch to turn
/// on, after a button in the welcome window opened System Settings. It has no close
/// button: it goes away once the permission is given or System Settings closes.
/// WelcomeWindow owns it and also closes it with the window.
///
/// System Settings is found by its windows' owner, layer and bounds only, which need no
/// permission. Window titles would need Screen Recording, so they are never read.
final class SettingsGuidePanel {
    static let settingsBundleID = "com.apple.systempreferences"

    private var panel: NoticePanel?
    private var watch: Task<Void, Never>?

    /// Shows the card for `kind` once the System Settings window is on screen, and keeps it
    /// beside that window until `isGranted` says yes or another rule of
    /// SettingsGuideTracker ends it. A second call replaces the first.
    func show(_ kind: PermissionDemo.Kind, localization: String, isGranted: @escaping () -> Bool) {
        dismiss()
        let panel = makePanel()
        let locale = Locale(identifier: localization)
        let view = NSHostingView(rootView: AnyView(
            SettingsGuideCard(kind: kind)
                .environment(\.locale, locale)
                .environment(\.interfaceLocale, locale)
        ))
        panel.contentView = view
        panel.setContentSize(view.fittingSize)
        self.panel = panel
        watch = Task { [weak self] in
            var tracker = SettingsGuideTracker()
            let clock = ContinuousClock()
            let start = clock.now
            while !Task.isCancelled {
                let elapsed = (clock.now - start) / .seconds(1)
                guard let self, follow(&tracker, at: elapsed, isGranted: isGranted) else { return }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    /// Closes the card and stops watching.
    func dismiss() {
        watch?.cancel()
        watch = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }

    /// One look at System Settings. False once the card is gone.
    private func follow(_ tracker: inout SettingsGuideTracker, at elapsed: Double, isGranted: () -> Bool) -> Bool {
        guard let panel else { return false }
        let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.settingsBundleID)
            .first { !$0.isTerminated }
        let window = app.map { Self.settingsWindow(pid: $0.processIdentifier) } ?? .none
        let active = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.settingsBundleID
        switch tracker.next(at: elapsed, granted: isGranted(), running: app != nil, window: window, active: active) {
        case .dismiss:
            dismiss()
            return false
        case .hide:
            if panel.isVisible { panel.orderOut(nil) }
        case .show(let bounds):
            place(panel, beside: bounds)
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
        return true
    }

    /// The System Settings window: its bounds while on screen, or whether it is only
    /// minimized, hidden or on another Space. The list of all windows still has it then,
    /// and loses it once it is closed.
    private static func settingsWindow(pid: pid_t) -> SettingsGuideTracker.Window {
        let options: CGWindowListOption = [.excludeDesktopElements]
        let onScreen = CGWindowListCopyWindowInfo(options.union(.optionOnScreenOnly), kCGNullWindowID) as? [[String: Any]] ?? []
        let all = CGWindowListCopyWindowInfo(options.union(.optionAll), kCGNullWindowID) as? [[String: Any]] ?? []
        return SettingsGuideTracker.window(onScreen: onScreen, all: all, pid: pid)
    }

    private func place(_ panel: NSPanel, beside bounds: CGRect) {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return }
        let window = SettingsGuidePlacement.cocoaRect(fromCG: bounds, primaryHeight: primary.frame.height)
        let frame = SettingsGuidePlacement.frame(
            size: panel.frame.size,
            beside: window,
            screens: screens.map { SettingsGuidePlacement.Screen(frame: $0.frame, visible: $0.visibleFrame) }
        )
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
        }
    }

    /// Internal so tests can check the panel without showing it.
    func makePanel() -> NoticePanel {
        let panel = NoticePanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        return panel
    }
}

/// When the card shows, hides and goes away, from one look at System Settings every
/// 0.4 s.
nonisolated struct SettingsGuideTracker: Sendable {
    /// The System Settings window, in CG coordinates.
    enum Window: Equatable, Sendable {
        case onScreen(CGRect)
        /// Minimized, hidden or on another Space.
        case offScreen
        case none
    }

    enum Action: Equatable, Sendable {
        case show(CGRect)
        case hide
        case dismiss
    }

    /// How long to wait for the window at first. The Accessibility prompt from macOS may
    /// come before it.
    static let waitForWindow = 60.0
    /// How long the window may be gone once it was there.
    static let goneLimit = 3.0
    /// Smaller windows of System Settings, such as a sheet's, are not the settings window.
    static let smallestWindow = CGSize(width: 300, height: 200)

    private(set) var appeared = false
    private var goneSince: Double?

    /// What to do at `time` seconds after the click. The card goes away once access is
    /// given or System Settings closes, and shows only while System Settings is the active
    /// app, so it never floats over another one.
    mutating func next(at time: Double, granted: Bool, running: Bool, window: Window, active: Bool) -> Action {
        if granted { return .dismiss }
        if appeared, !running { return .dismiss }
        switch window {
        case .onScreen(let bounds):
            appeared = true
            goneSince = nil
            return active ? .show(bounds) : .hide
        case .offScreen:
            appeared = true
            goneSince = nil
            return .hide
        case .none:
            guard appeared else {
                return time >= Self.waitForWindow ? .dismiss : .hide
            }
            let since = goneSince ?? time
            goneSince = since
            return time - since >= Self.goneLimit ? .dismiss : .hide
        }
    }

    /// The settings window of the app with `pid` in the lists from
    /// CGWindowListCopyWindowInfo: the largest of its normal windows on screen, or
    /// `.offScreen` when it has one only in the list of all windows.
    static func window(onScreen: [[String: Any]], all: [[String: Any]], pid: pid_t) -> Window {
        if let largest = bounds(in: onScreen, pid: pid).max(by: { $0.width * $0.height < $1.width * $1.height }) {
            return .onScreen(largest)
        }
        return bounds(in: all, pid: pid).isEmpty ? .none : .offScreen
    }

    private static func bounds(in list: [[String: Any]], pid: pid_t) -> [CGRect] {
        list.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? Int).map({ pid_t($0) }) == pid,
                  info[kCGWindowLayer as String] as? Int == 0,
                  let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
                  bounds.width >= smallestWindow.width, bounds.height >= smallestWindow.height
            else { return nil }
            return bounds
        }
    }
}

/// Where the card goes beside the System Settings window, in Cocoa coordinates.
nonisolated enum SettingsGuidePlacement {
    struct Screen: Equatable, Sendable {
        var frame: CGRect
        var visible: CGRect
    }

    static let gap: CGFloat = 12
    /// How far below the window's top edge the card starts, past its title bar.
    static let topInset: CGFloat = 52
    /// How far inside the window's lower right corner the card sits when neither side has
    /// room.
    static let cornerInset: CGFloat = 16

    /// A rectangle in CG global coordinates, with the origin at the top left of the primary
    /// screen and y going down, in Cocoa's, with the origin at its bottom left and y going
    /// up. The same on every screen, since both are measured from the primary one.
    static func cocoaRect(fromCG rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// On the window's right when its screen has room there, else on its left, else over
    /// its lower right corner. Near the window's top, and always inside the visible part
    /// of the window's screen.
    static func frame(size: CGSize, beside window: CGRect, screens: [Screen]) -> CGRect {
        let visible = screen(of: window, in: screens)?.visible ?? window
        var origin: CGPoint
        let right = window.maxX + gap
        let left = window.minX - gap - size.width
        let top = window.maxY - topInset - size.height
        if right + size.width <= visible.maxX {
            origin = CGPoint(x: right, y: top)
        } else if left >= visible.minX {
            origin = CGPoint(x: left, y: top)
        } else {
            origin = CGPoint(x: window.maxX - cornerInset - size.width, y: window.minY + cornerInset)
        }
        origin.x = max(visible.minX, min(origin.x, visible.maxX - size.width))
        origin.y = max(visible.minY, min(origin.y, visible.maxY - size.height))
        return CGRect(origin: origin, size: size)
    }

    /// The screen with most of the window, or the nearest one when it is on none.
    private static func screen(of window: CGRect, in screens: [Screen]) -> Screen? {
        func overlap(_ screen: Screen) -> CGFloat {
            let common = screen.frame.intersection(window)
            return common.isNull ? 0 : common.width * common.height
        }
        func distance(_ screen: Screen) -> CGFloat {
            hypot(screen.frame.midX - window.midX, screen.frame.midY - window.midY)
        }
        if let best = screens.max(by: { overlap($0) < overlap($1) }), overlap(best) > 0 {
            return best
        }
        return screens.min { distance($0) < distance($1) }
    }
}

/// The card: the guide and one line above the picture of the list with Orra's switch.
struct SettingsGuideCard: View {
    let kind: PermissionDemo.Kind

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                OrraGuide()
                    .frame(width: 40, height: 40)
                Text("Find Orra in this list and turn on its switch.")
                    .font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            PermissionDemo(kind: kind)
        }
        .padding(12)
        .frame(width: PermissionDemoFrame.size.width + 24)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }
}
