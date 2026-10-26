import AppKit
import SwiftUI

/// The Projects window, which Open Projects Window opens while Projects is on: in the menu
/// bar menu, the Dock menu and the Projects page of Settings. AppKit, like the welcome
/// window, since an accessory app cannot open a SwiftUI window from AppKit code.
///
/// While it is open it holds the cleanup model, and closing it lets the model go and ends
/// the background work, see ProjectsRuntime.windowOpened(). Orra shows in the Dock while it
/// is open, as for Settings, see DockIcon. It closes when Projects turns off. Closing it
/// saves the text the user typed into drafts, ends the requests of its email views and
/// lets go of the window with its lists and selection, so no mail it showed stays in
/// memory, and the next open builds it anew where it was last, with those drafts.
final class ProjectsWindow {
    /// The size the window first opens at.
    static let defaultSize = CGSize(width: 1_040, height: 640)
    /// The smallest size, at which the three columns still fit.
    static let minimumSize = CGSize(width: 760, height: 420)
    /// The name its frame is kept under between launches.
    private static let frameName = "ProjectsWindow"

    private let runtime: ProjectsRuntime
    /// Called before the window shows, see DockIcon.willShowWindow().
    private let willShow: () -> Void
    /// Opens Settings at the Projects page.
    private let openSettings: () -> Void
    private var window: NSWindow?
    /// What the open window shows, nil while it is closed.
    private var model: ProjectsWindowModel?
    private var closeObserver: (any NSObjectProtocol)?

    init(runtime: ProjectsRuntime, willShow: @escaping () -> Void, openSettings: @escaping () -> Void) {
        self.runtime = runtime
        self.willShow = willShow
        self.openSettings = openSettings
    }

    /// Brings the window to the front, while Projects is on, see
    /// ProjectsRuntime.canOpenWindow. It takes the model once Projects runs, see
    /// ProjectsRuntime.windowOpened().
    func show() {
        guard runtime.canOpenWindow else { return }
        let window = self.window ?? makeWindow()
        self.window = window
        willShow()
        runtime.windowOpened()
        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// Brings the window to the front with Edit Project open for a project, as Edit
    /// Project… beside a linked mailbox in Settings asks. A sheet or a dialog that shows
    /// there already stays as it is.
    func edit(_ project: UUID) {
        show()
        model?.edit(project)
    }

    /// Closes the window, such as when Projects turns off.
    func close() {
        window?.close()
    }

    /// Puts the words of a dictation into the change box of the email view, while Orra is
    /// in front, this window is its key window and the change box has the focus, and
    /// returns whether it took them. AppDelegate asks this before it pastes a dictation, so
    /// the talk key's words go straight into the box, with no clipboard and no Command V
    /// (decision 13). Text only flows in: nothing here reaches the dictation.
    func takeDictation(_ words: String) -> Bool {
        Self.takeDictation(words, into: model, appIsActive: NSApplication.shared.isActive, windowIsKey: window?.isKeyWindow == true)
    }

    /// The decision of `takeDictation(_:)`, apart from AppKit for tests. The change box keeps
    /// its focus when another window or app comes to the front, so its focus alone would
    /// take words meant for another app.
    static func takeDictation(_ words: String, into model: ProjectsWindowModel?, appIsActive: Bool, windowIsKey: Bool) -> Bool {
        guard let model, appIsActive, windowIsKey else { return false }
        return model.takeDictation(words)
    }

    private func makeWindow() -> NSWindow {
        let model = ProjectsWindowModel(runtime: runtime)
        self.model = model
        let view = ProjectsWindowView(runtime: runtime, model: model, openSettings: openSettings)
        let window = Self.window(hosting: view)
        if !window.setFrameUsingName(Self.frameName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.frameName)
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self, weak model] _ in
            MainActor.assumeIsolated {
                self?.runtime.windowClosed()
                // A change or a check the user can no longer see ends with the window, and
                // the text the user typed into drafts is saved.
                model?.forgetEmails()
                self?.letGo()
            }
        }
        return window
    }

    /// The window with `content` in it, at the size it first opens at. `makeWindow()` adds
    /// the frame it keeps between launches, which tests leave out, as they build it with a
    /// view of their own.
    static func window(hosting content: some View) -> NSWindow {
        let controller = NSHostingController(rootView: content)
        controller.sceneBridgingOptions = [.toolbars, .title]
        // Only the minimum size. With the default, content that grows in a scroll view, such
        // as a long email in the email view, sets the window's height, and the user could not
        // make it shorter.
        controller.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: controller)
        window.title = String(localized: "Projects")
        // The sidebar reaches the top of the window under one toolbar, as in Mail.
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.setContentSize(Self.defaultSize)
        window.contentMinSize = Self.minimumSize
        return window
    }

    /// Lets go of the closing window, so the next `show()` builds a new one. The window is
    /// kept until the close is done, since it may not go away inside its own notification.
    private func letGo() {
        let closing = window
        window = nil
        model = nil
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
        closeObserver = nil
        DispatchQueue.main.async {
            withExtendedLifetime(closing) {}
        }
    }
}
