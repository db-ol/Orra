import Foundation

nonisolated extension UserDefaults {
    /// The switch saved under `key`, or `defaultValue` while the user has not changed it.
    /// A value that is not a Bool counts as not saved.
    func bool(forKey key: String, default defaultValue: Bool) -> Bool {
        object(forKey: key) as? Bool ?? defaultValue
    }
}
