import AppKit

final class StatusBarController: NSObject, NSMenuDelegate {

    private let service: KeyboardLockService
    private let preferences: Preferences
    private let diagnostics: Diagnostics
    private let gate: PermissionGate
    private let hotkey: HotkeyManager

    private let statusItem: NSStatusItem
    private let menu = NSMenu(title: "KeyMute")

    private let statusLineItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let lockItem = NSMenuItem(title: "锁定键盘", action: nil, keyEquivalent: "")
    private let autoUnlockItem = NSMenuItem(title: "自动解锁", action: nil, keyEquivalent: "")
    private let autoUnlockMenu = NSMenu(title: "自动解锁")
    private let remoteItem = NSMenuItem(title: "允许远程输入（UU 远程）", action: nil, keyEquivalent: "")
    private let hotkeyItem = NSMenuItem(title: "全局快捷键 ⇧⌘K", action: nil, keyEquivalent: "")
    private let trackpadItem = NSMenuItem(title: "同时锁定触控板（即将支持）", action: nil, keyEquivalent: "")
    private let permissionItem = NSMenuItem(title: "⚠︎ 需要辅助功能权限…", action: nil, keyEquivalent: "")
    private let diagnosticsItem = NSMenuItem(title: "诊断日志…", action: nil, keyEquivalent: "")

    private var diagnosticsPanel: DiagnosticsPanel?

    init(
        service: KeyboardLockService,
        preferences: Preferences,
        diagnostics: Diagnostics,
        gate: PermissionGate,
        hotkey: HotkeyManager
    ) {
        self.service = service
        self.preferences = preferences
        self.diagnostics = diagnostics
        self.gate = gate
        self.hotkey = hotkey
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        buildMenu()
        statusItem.menu = menu
        menu.delegate = self

        service.onStateChange = { [weak self] in self?.refresh() }
        gate.onChange = { [weak self] in self?.refresh() }
        refresh()
    }

    // MARK: - 菜单

    private func buildMenu() {
        menu.autoenablesItems = false

        statusLineItem.isEnabled = false
        menu.addItem(statusLineItem)
        menu.addItem(.separator())

        lockItem.target = self
        lockItem.action = #selector(toggleLock)
        menu.addItem(lockItem)

        for minutes in [5, 10, 30, 0] {
            let item = NSMenuItem(
                title: minutes > 0 ? "\(minutes) 分钟" : "永不",
                action: #selector(selectAutoUnlock(_:)),
                keyEquivalent: ""
            )
            item.tag = minutes
            item.target = self
            autoUnlockMenu.addItem(item)
        }
        autoUnlockMenu.autoenablesItems = false
        autoUnlockItem.submenu = autoUnlockMenu
        menu.addItem(autoUnlockItem)

        remoteItem.target = self
        remoteItem.action = #selector(toggleAllowRemote)
        menu.addItem(remoteItem)

        hotkeyItem.target = self
        hotkeyItem.action = #selector(toggleHotkey)
        menu.addItem(hotkeyItem)

        trackpadItem.isEnabled = false
        menu.addItem(trackpadItem)

        menu.addItem(.separator())

        permissionItem.target = self
        permissionItem.action = #selector(handlePermissionItem)
        menu.addItem(permissionItem)

        diagnosticsItem.target = self
        diagnosticsItem.action = #selector(showDiagnostics)
        menu.addItem(diagnosticsItem)

        menu.addItem(.separator())

        let aboutItem = NSMenuItem(title: "关于 KeyMute", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
    }

    // MARK: - 刷新

    func refresh() {
        gate.refreshTrustState()
        updateIcon()
        statusLineItem.title = statusLineText()

        lockItem.title = service.isLocked ? "解锁键盘" : "锁定键盘"
        lockItem.state = service.isLocked ? .on : .off
        lockItem.keyEquivalent = service.isLocked ? "" : "k"
        lockItem.keyEquivalentModifierMask = [.command, .shift]

        for item in autoUnlockMenu.items {
            item.state = item.tag == preferences.autoUnlockMinutes ? .on : .off
        }
        remoteItem.state = preferences.allowRemoteInput ? .on : .off
        hotkeyItem.state = preferences.hotkeyEnabled ? .on : .off
        permissionItem.isHidden = gate.isTrusted

        statusItem.button?.toolTip = statusLineText()
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }

        let symbol: String
        if !gate.isTrusted {
            symbol = "exclamationmark.triangle"
        } else if service.isLocked {
            symbol = "lock.fill"
        } else {
            symbol = "keyboard"
        }

        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "KeyMute")
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageLeading

        if service.isLocked, let remaining = service.remainingSeconds, remaining < 60 {
            button.title = "\(remaining)s"
        } else {
            button.title = ""
        }
    }

    private func statusLineText() -> String {
        if !gate.isTrusted {
            return "需要辅助功能权限"
        }
        guard service.isLocked else {
            return "键盘未锁定"
        }
        var text = "键盘已锁定 · \(Self.formatDuration(service.lockedDuration))"
        if let remaining = service.remainingSeconds {
            text += " · \(Self.formatDuration(TimeInterval(remaining))) 后自动解锁"
        }
        return text
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    // MARK: - 动作

    @objc private func toggleLock() {
        if service.isLocked {
            service.unlock(reason: .manual)
        } else if !service.lock() {
            gate.requestAccess()
        }
        refresh()
    }

    @objc private func selectAutoUnlock(_ sender: NSMenuItem) {
        preferences.autoUnlockMinutes = sender.tag
        service.autoUnlockSettingChanged()
        refresh()
    }

    @objc private func toggleAllowRemote() {
        preferences.allowRemoteInput.toggle()
        refresh()
    }

    @objc private func toggleHotkey() {
        preferences.hotkeyEnabled.toggle()
        hotkey.setEnabled(preferences.hotkeyEnabled)
        refresh()
    }

    @objc private func handlePermissionItem() {
        gate.openSettings()
        if !gate.isTrusted {
            gate.requestAccess()
        }
    }

    @objc private func showDiagnostics() {
        if diagnosticsPanel == nil {
            diagnosticsPanel = DiagnosticsPanel(diagnostics: diagnostics)
        }
        diagnosticsPanel?.show()
    }
    @objc private func showAbout() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
