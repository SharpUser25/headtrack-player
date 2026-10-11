import Foundation
import HeadTrackCore

/// Persists `PlayerSettings` as one JSON blob in UserDefaults.
struct SettingsStore {
    var defaults: UserDefaults = .standard
    var key = "HeadTrackPlayer.settings.v1"

    func load() -> PlayerSettings {
        PlayerSettings.decode(defaults.data(forKey: key))
    }

    func save(_ s: PlayerSettings) {
        if let data = s.encoded() { defaults.set(data, forKey: key) }
    }
}
