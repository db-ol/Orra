import AppKit
import Foundation
import Testing
@testable import Orra

@MainActor
struct DockIconTests {
    private final class Fakes {
        var policies: [NSApplication.ActivationPolicy] = []
        var saved: [Bool] = []
        var windowOpen = false
    }

    private func makeDockIcon(_ fakes: Fakes, showsInDock: Bool) -> DockIcon {
        DockIcon(
            showsInDock: showsInDock,
            save: { fakes.saved.append($0) },
            setPolicy: { fakes.policies.append($0) },
            hasOpenWindow: { fakes.windowOpen }
        )
    }

    @Test func orraIsInTheDockUntilTurnedOff() throws {
        let fakes = Fakes()
        let dock = makeDockIcon(fakes, showsInDock: true)
        dock.update()
        #expect(fakes.policies == [.regular])
        dock.showsInDock = false
        #expect(fakes.policies == [.regular, .accessory])
        #expect(fakes.saved == [false])

        let suite = "io.github.db-ol.OrraTests.dock-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(DockIcon.live(defaults: defaults).showsInDock)
        defaults.set(false, forKey: DockIcon.defaultsKey)
        #expect(!DockIcon.live(defaults: defaults).showsInDock)
    }

    @Test func whileOffAnOpenWindowShowsTheIcon() {
        let fakes = Fakes()
        let dock = makeDockIcon(fakes, showsInDock: false)
        dock.update()
        fakes.windowOpen = true
        dock.update()
        fakes.windowOpen = false
        dock.update()
        #expect(fakes.policies == [.accessory, .regular, .accessory])
    }

    @Test func turningItOffWithSettingsOpenKeepsTheIconUntilTheWindowCloses() {
        let fakes = Fakes()
        fakes.windowOpen = true
        let dock = makeDockIcon(fakes, showsInDock: true)
        dock.update()
        dock.showsInDock = false
        #expect(fakes.policies == [.regular])
        fakes.windowOpen = false
        dock.update()
        #expect(fakes.policies == [.regular, .accessory])
    }
}
