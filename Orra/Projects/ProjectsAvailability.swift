/// Whether this build shows Projects at all. Projects is still being built, so only Debug
/// builds, run from Xcode, show it. Release builds hide its page in Settings and keep it off,
/// whatever a Debug run saved, since both share the bundle ID and its preferences.
///
/// Code that decides what shows takes the value as a parameter, with this as its default, so
/// tests cover both values. The documentation of Projects changes it to true in release builds.
nonisolated enum ProjectsAvailability {
    #if DEBUG
    static let isVisible = true
    #else
    static let isVisible = false
    #endif
}
