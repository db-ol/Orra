import Observation
import Synchronization
import Testing
@testable import Orra

/// A stand in for the system's login items. Tests never touch the real ones.
@MainActor
final class FakeLoginItems {
    var status: OpenAtLogin.Status = .off
    var error: (any Error)?
    private(set) var changes: [Bool] = []
    private(set) var settingsOpened = 0

    var openAtLogin: OpenAtLogin {
        OpenAtLogin(
            readStatus: { self.status },
            register: { on in
                self.changes.append(on)
                if let error = self.error { throw error }
                self.status = on ? .on : .off
            },
            openLoginItemsSettings: { self.settingsOpened += 1 }
        )
    }
}

@MainActor
struct OpenAtLoginTests {
    let items = FakeLoginItems()

    @Test func readsTheStatusWhenAskedTo() {
        let openAtLogin = items.openAtLogin
        #expect(openAtLogin.status == .off)
        // Changed in System Settings. The menu calls refresh whenever it opens.
        items.status = .on
        openAtLogin.refresh()
        #expect(openAtLogin.status == .on)
        #expect(openAtLogin.isOn)
    }

    /// Records whether an observed property changed.
    final class ChangeFlag: Sendable {
        let fired = Mutex(false)
    }

    @Test func theMenuIsToldAboutEveryStatusChange() {
        let openAtLogin = items.openAtLogin
        let flag = ChangeFlag()
        withObservationTracking { _ = openAtLogin.status } onChange: { flag.fired.withLock { $0 = true } }
        openAtLogin.setOn(true)
        #expect(flag.fired.withLock { $0 })

        let second = ChangeFlag()
        withObservationTracking { _ = openAtLogin.status } onChange: { second.fired.withLock { $0 = true } }
        items.status = .needsApproval
        openAtLogin.refresh()
        #expect(second.fired.withLock { $0 })
    }

    @Test func turningOnAndOffRegistersAndUnregisters() {
        let openAtLogin = items.openAtLogin
        openAtLogin.setOn(true)
        #expect(openAtLogin.status == .on)
        openAtLogin.setOn(false)
        #expect(openAtLogin.status == .off)
        #expect(items.changes == [true, false])
        #expect(openAtLogin.problem == nil)
    }

    @Test func aProblemClearsWhenTheStatusMatchesTheRequestLater() {
        let openAtLogin = items.openAtLogin
        items.error = TestError()
        openAtLogin.setOn(true)
        #expect(openAtLogin.problem != nil)
        // The user turned Orra on in System Settings instead.
        items.status = .on
        openAtLogin.refresh()
        #expect(openAtLogin.problem == nil)
    }

    @Test func aFailedChangeShowsAProblemUntilAChangeSucceeds() {
        let openAtLogin = items.openAtLogin
        items.error = TestError()
        openAtLogin.setOn(true)
        #expect(openAtLogin.status == .off)
        #expect(openAtLogin.problem != nil)
        items.error = nil
        openAtLogin.setOn(true)
        #expect(openAtLogin.status == .on)
        #expect(openAtLogin.problem == nil)
    }

    @Test func anItemWaitingForApprovalShowsAsOnAndOffersTheSettings() {
        items.status = .needsApproval
        let openAtLogin = items.openAtLogin
        #expect(openAtLogin.isOn)
        #expect(openAtLogin.needsApproval)
        openAtLogin.openSettings()
        #expect(items.settingsOpened == 1)
        #expect(items.changes.isEmpty)
        // Turning it off from there unregisters.
        openAtLogin.setOn(false)
        #expect(items.changes == [false])
        #expect(openAtLogin.isOn == false)
        #expect(openAtLogin.needsApproval == false)
    }
}
