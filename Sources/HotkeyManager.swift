import AppKit
import Carbon.HIToolbox

/// 全局快捷键 ⇧⌘K：走 Carbon `RegisterEventHotKey`，不依赖事件 tap，
/// 因此未锁定时不需要常驻 tap，也不需要额外权限。
final class HotkeyManager {

    fileprivate static var current: HotkeyManager?

    private let diagnostics: Diagnostics
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var isEnabled = false

    /// 触发时调用（只负责"锁定"，解锁仍需鼠标/触控板）。
    var onTrigger: (() -> Void)?

    private static let signature: OSType = 0x4B4D_5554 // 'KMUT'
    private static let hotKeyID: UInt32 = 1

    init(diagnostics: Diagnostics) {
        self.diagnostics = diagnostics
    }

    deinit {
        unregister()
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            register()
        } else {
            unregister()
            diagnostics.note("全局快捷键已关闭")
        }
    }

    fileprivate func fire() {
        onTrigger?()
    }

    // MARK: - Carbon

    private func register() {
        unregister()
        HotkeyManager.current = self

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            keyMuteHotkeyHandler,
            1,
            &eventType,
            nil,
            &handlerRef
        )
        guard installStatus == noErr else {
            diagnostics.note("全局快捷键事件处理器安装失败（status=\(installStatus)）")
            return
        }

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: Self.hotKeyID)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_K),
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr, let ref = ref {
            hotKeyRef = ref
            diagnostics.note("全局快捷键 ⇧⌘K 已注册")
        } else {
            diagnostics.note("全局快捷键 ⇧⌘K 注册失败（status=\(status)），可能被其他 App 占用")
        }
    }

    private func unregister() {
        if let hotKeyRef = hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef = handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }
}

private func keyMuteHotkeyHandler(
    callRef: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    HotkeyManager.current?.fire()
    return noErr
}
