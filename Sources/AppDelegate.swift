import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var preferences: Preferences!
    private var diagnostics: Diagnostics!
    private var lockService: KeyboardLockService!
    private var permissionGate: PermissionGate!
    private var hotkey: HotkeyManager!
    private var statusBar: StatusBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ensureSingleInstance() else { return }

        preferences = Preferences()
        diagnostics = Diagnostics()
        lockService = KeyboardLockService(preferences: preferences, diagnostics: diagnostics)
        permissionGate = PermissionGate(diagnostics: diagnostics)

        hotkey = HotkeyManager(diagnostics: diagnostics)
        hotkey.onTrigger = { [weak self] in
            self?.lockService.lockFromHotkey()
        }
        hotkey.setEnabled(preferences.hotkeyEnabled)

        statusBar = StatusBarController(
            service: lockService,
            preferences: preferences,
            diagnostics: diagnostics,
            gate: permissionGate,
            hotkey: hotkey
        )

        permissionGate.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        lockService?.shutdown()
    }

    /// 同一个 bundle id 只允许一个实例，避免两个 tap 互相打架。
    private func ensureSingleInstance() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return true }
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .filter { $0 != NSRunningApplication.current }
        guard let existing = others.first else { return true }

        if #available(macOS 14.0, *) {
            existing.activate()
        } else {
            existing.activate(options: [.activateIgnoringOtherApps])
        }
        NSApp.terminate(nil)
        return false
    }
}
