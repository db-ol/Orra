import Foundation
import Testing
@testable import Orra

/// Xcode hosts the tests in Orra.app, so Bundle.main is the app with its merged Info.plist.
@MainActor
struct AppUpdaterTests {
    @Test func theAppPointsSparkleAtTheSignedGitHubFeed() throws {
        let info = try #require(Bundle.main.infoDictionary)
        #expect(info["SUFeedURL"] as? String == "https://github.com/db-ol/Orra/releases/latest/download/appcast.xml")
        let key = try #require(info["SUPublicEDKey"] as? String)
        #expect(Data(base64Encoded: key)?.count == 32)
        #expect(info["SURequireSignedFeed"] as? Bool == true)
        #expect(info["SUVerifyUpdateBeforeExtraction"] as? Bool == true)
        #expect(info["SUEnableSystemProfiling"] as? Bool == false)
        #expect(info["SUAllowsAutomaticUpdates"] as? Bool == false)
        // Sparkle asks the user before the first automatic check.
        #expect(info["SUEnableAutomaticChecks"] == nil)
    }

    @Test func beforeSparkleStartsNothingCanBeChecked() {
        let updater = AppUpdater()
        #expect(!updater.canCheckForUpdates)
        #expect(!updater.checksAutomatically)
        #expect(updater.waitingUpdate == nil)
        // Does nothing, and reaches no network, until start().
        updater.checkForUpdates()
    }
}
