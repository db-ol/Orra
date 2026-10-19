import AppKit
import os

extension Logger {
    /// Which window launch opened and what it was decided from. States only.
    nonisolated static let launch = Logger(subsystem: ProblemReport.subsystem, category: "launch")
}

/// The window Orra opens when it starts. The welcome window while setup needs the user, at
/// login too. Once it does not, Settings when the user opened Orra, so the launch shows
/// more than a Dock icon, and no window when Orra may have opened at login.
nonisolated enum LaunchWindow: Equatable, Sendable {
    case welcome
    case settings
    case noWindow

    /// - Parameters:
    ///   - needsUser: Whether setup still needs the user, see SetupChecklist.needsUser.
    ///   - launchedAtLogin: Whether macOS marked the launch as a login item's, see
    ///     `isLoginLaunch(_:)`.
    ///   - openAtLogin: Whether Open at Login is on, also while it waits for approval. Orra
    ///     then opens no window even without the mark, since it has not been confirmed
    ///     that macOS sets it for Orra's kind of login item. A click on the Dock icon still
    ///     opens Settings.
    static func choose(needsUser: Bool, launchedAtLogin: Bool, openAtLogin: Bool) -> LaunchWindow {
        if needsUser { return .welcome }
        if launchedAtLogin || openAtLogin { return .noWindow }
        return .settings
    }

    /// Whether `event`, the Apple event that launched Orra, marks a launch at login. Only
    /// current in applicationDidFinishLaunching. The header says only that the key marks
    /// such a launch in an open application event, so both places it may be in are read.
    static func isLoginLaunch(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let event, event.eventID == kAEOpenApplication else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
            || event.paramDescriptor(forKeyword: keyAELaunchedAsLogInItem) != nil
    }

    /// Opens Settings at launch, and for a click on the Dock icon or a second open while
    /// Orra runs. It comes to the front even when macOS declines to make Orra active, as
    /// the welcome window does, for example when the user clicked another app while Orra
    /// was starting.
    @MainActor static func openSettings(dockIcon: DockIcon) {
        dockIcon.willShowWindow()
        guard DockIcon.openSettings() else {
            // No window opens, so the Dock icon follows the choice again.
            dockIcon.update()
            return
        }
        // SwiftUI may add the window after the menu item's action returns, so this looks
        // for it for up to a second.
        Task {
            for _ in 0..<10 {
                if let window = NSApplication.shared.windows.first(where: { SettingsWindow.isSettings($0) && $0.isVisible }) {
                    window.orderFrontRegardless()
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}
