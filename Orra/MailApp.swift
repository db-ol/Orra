import AppKit
import os

/// The Mail app, which Orra opens only when the user clicks Open Mail, on the Projects page
/// of Settings and in the Projects window. This is the one place in Orra that opens another
/// app (Tools/ci/check_rules.py, rule 11). It sits outside Orra/Projects, since code there
/// never uses NSWorkspace (rule 1), and gets it as a closure. Tests pass a fake closure and
/// never call it (rule 4).
///
/// Orra's code builds and sends Mail no Apple Event here, needs no Automation consent and
/// reads nothing. macOS sends Mail the same open or reopen event as a click on its Dock
/// icon, and Mail comes to the front. What follows is what follows when the user opens Mail
/// any other way: Settings lists the names of its mailboxes with events that never bring up
/// the prompt, and the scan reads mail only after Start Reading Mail confirmed the choice
/// and macOS allowed access.
enum MailApp {
    static let bundleIdentifier = "com.apple.mail"

    /// Opens Mail in front, or brings it to the front when it runs. Only on the user's
    /// click. Logs the click and an error code, never anything of Mail.
    static func open() {
        Logger.projectsMail.notice("Open Mail clicked")
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            Logger.projectsMail.error("Open Mail: Mail was not found")
            return
        }
        // Orra is in front after the click. Since macOS 14 it lets the app it opens take
        // the front, as ReplyHandoff does for Mail.
        NSApplication.shared.yieldActivation(toApplicationWithBundleIdentifier: bundleIdentifier)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                Logger.projectsMail.error("Open Mail failed: \((error as NSError).code, privacy: .public)")
            }
        }
    }
}
