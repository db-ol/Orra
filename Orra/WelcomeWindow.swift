import AppKit
import SwiftUI

/// Where a new user stands with the three things Orra needs before the first dictation:
/// the speech model, microphone access and Accessibility access.
nonisolated struct SetupChecklist: Equatable, Sendable {
    nonisolated enum Status: Equatable, Sendable {
        case todo
        case inProgress
        case done
    }

    var model: Status
    var microphone: Status
    var accessibility: Status

    /// - Parameter modelState: Whether the installed model loaded. A model that is
    ///   installed but still loading counts as done, so launch does not show the welcome
    ///   window while the model loads.
    init(installer: ModelInstaller.State, modelState: PushToTalkController.ModelState, microphone: MicrophoneAccess, hotkeyActive: Bool) {
        switch installer {
        case .installed:
            if case .unavailable = modelState {
                model = .todo
            } else {
                model = .done
            }
        case .checking, .downloading, .verifying:
            model = .inProgress
        case .missing, .failed:
            model = .todo
        }
        self.microphone = microphone == .authorized ? .done : .todo
        accessibility = hotkeyActive ? .done : .todo
    }

    @MainActor
    init(_ pushToTalk: PushToTalkController, _ models: ModelInstaller) {
        self.init(installer: models.state, modelState: pushToTalk.modelState, microphone: pushToTalk.microphoneAccess, hotkeyActive: pushToTalk.isHotkeyActive)
    }

    var isComplete: Bool {
        model == .done && microphone == .done && accessibility == .done
    }
}

/// The welcome window. AppDelegate shows it at launch until Orra has its model and both
/// permissions, and the menu's Setup Guide shows it again. AppKit, because an accessory
/// app cannot open a SwiftUI window at launch.
final class WelcomeWindow {
    private let pushToTalk: PushToTalkController
    private let models: ModelInstaller
    private var window: NSWindow?
    private var refresh: Task<Void, Never>?
    private var closeObserver: (any NSObjectProtocol)?

    init(pushToTalk: PushToTalkController, models: ModelInstaller) {
        self.pushToTalk = pushToTalk
        self.models = models
    }

    /// Brings the window to the front, from behind the app the user is in too.
    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
        watchMicrophoneAccess()
    }

    private func makeWindow() -> NSWindow {
        let view = WelcomeView(pushToTalk: pushToTalk, models: models) { [weak self] in
            self?.window?.close()
        }
        let controller = NSHostingController(rootView: view)
        // The window grows when a step shows more, such as the download's progress.
        controller.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: controller)
        window.title = String(localized: "Welcome to Orra")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh?.cancel()
                self?.refresh = nil
            }
        }
        return window
    }

    /// While the window is open, microphone access is read every second, so a change in
    /// System Settings shows without a relaunch. Reading never shows a prompt.
    /// Accessibility is not read here: the controller watches it, see
    /// PushToTalkController.watchAccess().
    private func watchMicrophoneAccess() {
        guard refresh == nil else { return }
        refresh = Task { [pushToTalk] in
            while !Task.isCancelled {
                pushToTalk.refreshMicrophoneAccess()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
