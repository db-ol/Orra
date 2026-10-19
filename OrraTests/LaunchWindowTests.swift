import AppKit
import Testing
@testable import Orra

/// Which window launch opens, and how a launch at login is told apart.
struct LaunchWindowTests {
    @Test func theWelcomeWindowOpensWhileSetupNeedsTheUser() {
        for launchedAtLogin in [false, true] {
            for openAtLogin in [false, true] {
                #expect(LaunchWindow.choose(needsUser: true, launchedAtLogin: launchedAtLogin, openAtLogin: openAtLogin) == .welcome)
            }
        }
    }

    @Test func aLaunchByTheUserOpensSettingsOnceSetupIsDone() {
        #expect(LaunchWindow.choose(needsUser: false, launchedAtLogin: false, openAtLogin: false) == .settings)
    }

    @Test func aLaunchAtLoginOpensNoWindow() {
        #expect(LaunchWindow.choose(needsUser: false, launchedAtLogin: true, openAtLogin: true) == .noWindow)
        #expect(LaunchWindow.choose(needsUser: false, launchedAtLogin: true, openAtLogin: false) == .noWindow)
    }

    /// Until a real login shows that macOS marks the launch, Open at Login keeps every launch
    /// quiet once setup is done.
    @Test func withOpenAtLoginOnALaunchWithoutTheMarkOpensNoWindow() {
        #expect(LaunchWindow.choose(needsUser: false, launchedAtLogin: false, openAtLogin: true) == .noWindow)
    }

    private func openApplicationEvent() -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(
            eventClass: kCoreEventClass,
            eventID: kAEOpenApplication,
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
    }

    @Test func anOpenApplicationEventMarkedAsALoginItemReadsAsALoginLaunch() {
        let event = openApplicationEvent()
        event.setParam(NSAppleEventDescriptor(enumCode: keyAELaunchedAsLogInItem), forKeyword: keyAEPropData)
        #expect(LaunchWindow.isLoginLaunch(event))

        let keyed = openApplicationEvent()
        keyed.setParam(NSAppleEventDescriptor(boolean: true), forKeyword: keyAELaunchedAsLogInItem)
        #expect(LaunchWindow.isLoginLaunch(keyed))
    }

    @Test func otherLaunchesDoNotReadAsALoginLaunch() {
        #expect(!LaunchWindow.isLoginLaunch(nil))
        #expect(!LaunchWindow.isLoginLaunch(openApplicationEvent()))

        let otherProperty = openApplicationEvent()
        otherProperty.setParam(NSAppleEventDescriptor(enumCode: 0x6162_6364), forKeyword: keyAEPropData)
        #expect(!LaunchWindow.isLoginLaunch(otherProperty))

        // The mark counts only in the event that opens the app.
        let reopen = NSAppleEventDescriptor(
            eventClass: kCoreEventClass,
            eventID: kAEReopenApplication,
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        reopen.setParam(NSAppleEventDescriptor(enumCode: keyAELaunchedAsLogInItem), forKeyword: keyAEPropData)
        #expect(!LaunchWindow.isLoginLaunch(reopen))
    }

    @MainActor
    @Test func theSettingsWindowIsFoundByItsSceneID() {
        func window(named name: String?) -> NSWindow {
            let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
            window.identifier = name.map { NSUserInterfaceItemIdentifier($0) }
            return window
        }
        #expect(SettingsWindow.isSettings(window(named: "settings")))
        #expect(SettingsWindow.isSettings(window(named: "settings-AppWindow-1")))
        #expect(!SettingsWindow.isSettings(window(named: nil)))
        #expect(!SettingsWindow.isSettings(window(named: "settingsGuide")))
        #expect(!SettingsWindow.isSettings(window(named: "welcome")))
    }
}
