/// Whether this build shows Projects at all. Every build shows it since Projects ships as a
/// preview, with the Preview label on its page in Settings (decision 12 of the phase 1
/// plan). Before the preview, only Debug builds showed it, and release builds hid its page
/// and kept it off.
///
/// Code that decides what shows takes the value as a parameter, with this as its default, so
/// tests cover both values, and hiding Projects again is a change of this one line.
nonisolated enum ProjectsAvailability {
    static let isVisible = true
}
