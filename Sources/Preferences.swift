import Foundation

final class Preferences {

    private enum Key {
        static let autoUnlockMinutes = "autoUnlockMinutes"
        static let allowRemoteInput = "allowRemoteInput"
        static let lockTrackpad = "lockTrackpad"
        static let hotkeyEnabled = "hotkeyEnabled"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.autoUnlockMinutes: 10,
            Key.allowRemoteInput: true,
            Key.lockTrackpad: false,
            Key.hotkeyEnabled: true,
        ])
    }

    /// 0 表示永不自动解锁。
    var autoUnlockMinutes: Int {
        get { defaults.integer(forKey: Key.autoUnlockMinutes) }
        set { defaults.set(newValue, forKey: Key.autoUnlockMinutes) }
    }

    var allowRemoteInput: Bool {
        get { defaults.bool(forKey: Key.allowRemoteInput) }
        set { defaults.set(newValue, forKey: Key.allowRemoteInput) }
    }

    /// 预留：v1 不生效。
    var lockTrackpad: Bool {
        get { defaults.bool(forKey: Key.lockTrackpad) }
        set { defaults.set(newValue, forKey: Key.lockTrackpad) }
    }

    var hotkeyEnabled: Bool {
        get { defaults.bool(forKey: Key.hotkeyEnabled) }
        set { defaults.set(newValue, forKey: Key.hotkeyEnabled) }
    }
}
