import Foundation

/// Persists each app's chosen volume/mute keyed by bundle ID, so a level you set
/// (e.g. Spotify at 40%) is remembered the next time that app plays.
enum AppPrefs {
    private static let volKey = "appVolumes"
    private static let muteKey = "appMutes"
    private static let defaults = UserDefaults.standard

    static func volume(for bundleID: String?) -> Float? {
        guard let bundleID, let dict = defaults.dictionary(forKey: volKey) as? [String: Double],
              let v = dict[bundleID] else { return nil }
        return Float(v)
    }

    static func setVolume(_ value: Float, for bundleID: String?) {
        guard let bundleID else { return }
        var dict = (defaults.dictionary(forKey: volKey) as? [String: Double]) ?? [:]
        dict[bundleID] = Double(value)
        defaults.set(dict, forKey: volKey)
    }

    static func muted(for bundleID: String?) -> Bool? {
        guard let bundleID, let dict = defaults.dictionary(forKey: muteKey) as? [String: Bool] else { return nil }
        return dict[bundleID]
    }

    static func setMuted(_ muted: Bool, for bundleID: String?) {
        guard let bundleID else { return }
        var dict = (defaults.dictionary(forKey: muteKey) as? [String: Bool]) ?? [:]
        dict[bundleID] = muted
        defaults.set(dict, forKey: muteKey)
    }
}
