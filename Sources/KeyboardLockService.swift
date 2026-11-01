import AppKit
import ApplicationServices

/// 持有 CGEventTap，决定"吞掉还是放行"。
///
/// 三条硬约束：
/// 1. tap 只在锁定期间存在 —— 未锁定时零干扰，风险窗口最小化；
/// 2. 回调里只做整数读取 + 入缓冲 —— 绝不做 UI、字符串格式化、跨进程查询；
/// 3. 回调超时（tapDisabledByTimeout）说明回调慢了，计数并在看门狗里兜底。
final class KeyboardLockService {

    enum UnlockReason: String {
        case manual = "手动解锁"
        case autoTimeout = "到达自动解锁时间"
        case watchdog = "事件 tap 异常"
        case permissionLost = "辅助功能权限失效"
        case terminate = "进程退出"
    }

    private let preferences: Preferences
    private let diagnostics: Diagnostics

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var activityToken: NSObjectProtocol?
    private var tickTimer: Timer?
    private var watchdogTimer: Timer?

    private var lockedAt: Date?
    private var autoUnlockAt: Date?
    private var watchdogFailures = 0

    /// 锁定瞬间已按住的修饰键，放行它们的抬键事件，避免 ⌘/⌥ 粘住。
    private var passthroughOnRelease: Set<Int64> = []

    private(set) var isLocked = false
    /// 本次运行中 tap 因回调过慢被系统禁用的次数（正常应始终为 0）。
    private(set) var tapTimeoutCount = 0
    /// 全局快捷键与菜单项可能在同一轮事件里各触发一次，做去抖。
    private var lastHotkeyTrigger = Date.distantPast

    var onStateChange: (() -> Void)?

    init(preferences: Preferences, diagnostics: Diagnostics) {
        self.preferences = preferences
        self.diagnostics = diagnostics
    }

    var lockedDuration: TimeInterval {
        guard let lockedAt = lockedAt else { return 0 }
        return Date().timeIntervalSince(lockedAt)
    }

    /// nil 表示不自动解锁。
    var remainingSeconds: Int? {
        guard let autoUnlockAt = autoUnlockAt else { return nil }
        return max(0, Int(autoUnlockAt.timeIntervalSinceNow.rounded(.up)))
    }

    // MARK: - 生命周期

    func shutdown() {
        unlock(reason: .terminate)
        removeTap()
    }

    // MARK: - 锁定 / 解锁

    @discardableResult
    func lock() -> Bool {
        guard !isLocked else { return true }
        guard installTap() else {
            diagnostics.note("锁定失败：无法创建事件 tap（缺少辅助功能权限？）")
            return false
        }

        isLocked = true
        lockedAt = Date()
        watchdogFailures = 0
        passthroughOnRelease = Self.modifierKeycodes(
            for: CGEventSource.flagsState(.combinedSessionState)
        )
        recalculateAutoUnlock()

        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleDisplaySleepDisabled],
            reason: "KeyMute 键盘锁定中"
        )
        startTimers()
        diagnostics.note("已锁定（\(autoUnlockDescription)）")
        onStateChange?()
        return true
    }

    func unlock(reason: UnlockReason) {
        guard isLocked else { return }
        isLocked = false
        lockedAt = nil
        autoUnlockAt = nil
        watchdogFailures = 0
        passthroughOnRelease.removeAll()
        stopTimers()
        removeTap()

        if let activityToken = activityToken {
            ProcessInfo.processInfo.endActivity(activityToken)
            self.activityToken = nil
        }
        diagnostics.note("已解锁（\(reason.rawValue)）")
        onStateChange?()
    }

    func toggleLock() {
        guard Date().timeIntervalSince(lastHotkeyTrigger) > 0.3 else { return }
        if isLocked {
            unlock(reason: .manual)
        } else {
            lock()
        }
    }

    /// 全局快捷键入口：只负责锁定，解锁仍需鼠标/触控板。
    func lockFromHotkey() {
        guard !isLocked else { return }
        lastHotkeyTrigger = Date()
        lock()
    }

    /// 自动解锁时长变更时调用（锁定中即时生效）。
    func autoUnlockSettingChanged() {
        guard isLocked else { return }
        recalculateAutoUnlock()
        onStateChange?()
    }

    private func recalculateAutoUnlock() {
        let minutes = preferences.autoUnlockMinutes
        if minutes > 0, let lockedAt = lockedAt {
            autoUnlockAt = lockedAt.addingTimeInterval(TimeInterval(minutes * 60))
        } else {
            autoUnlockAt = nil
        }
    }

    private var autoUnlockDescription: String {
        let minutes = preferences.autoUnlockMinutes
        return minutes > 0 ? "\(minutes) 分钟后自动解锁" : "不自动解锁"
    }

    // MARK: - Tap

    private func installTap() -> Bool {
        if tap != nil { return true }
        guard AXIsProcessTrusted() else { return false }

        let mask: CGEventMask =
            (CGEventMask(1) << CGEventType.keyDown.rawValue) |
            (CGEventMask(1) << CGEventType.keyUp.rawValue) |
            (CGEventMask(1) << CGEventType.flagsChanged.rawValue) |
            // 14 = NX_SYSDEFINED（媒体键 / 亮度键 / 音量键），CGEventType 无具名常量
            (CGEventMask(1) << Diagnostics.systemDefinedRawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: keyMuteEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            diagnostics.note("事件 tap 创建失败（权限不足或被系统拒绝）")
            return false
        }

        self.tap = tap
        if let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) {
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        diagnostics.note("事件 tap 已安装")
        return true
    }

    private func removeTap() {
        if let runLoopSource = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        if let tap = tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            self.tap = nil
            diagnostics.note("事件 tap 已移除")
        }
    }

    // MARK: - 事件过滤（核心：必须极快）

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // 系统会因回调过慢或用户操作禁用 tap，必须重新启用，否则"锁着但没拦"。
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if type == .tapDisabledByTimeout {
                tapTimeoutCount += 1
            }
            if let tap = tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            diagnostics.note(
                type == .tapDisabledByTimeout
                    ? "tap 因回调超时被系统禁用，已重新启用（累计 \(tapTimeoutCount) 次）"
                    : "tap 被系统禁用，已重新启用"
            )
            return Unmanaged.passUnretained(event)
        }

        guard isLocked else { return Unmanaged.passUnretained(event) }

        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        let pid = event.getIntegerValueField(.eventSourceUnixProcessID)

        // 锁定瞬间已按住的修饰键，放行抬键事件。
        var isReleasePassthrough = false
        if type == .keyUp || type == .flagsChanged, passthroughOnRelease.contains(keycode) {
            passthroughOnRelease.remove(keycode)
            isReleasePassthrough = true
        }

        let isRemote = Self.isRemoteEvent(pid: pid)
        let swallowed = !isReleasePassthrough && !(preferences.allowRemoteInput && isRemote)

        if diagnostics.isCapturing {
            // 只入缓冲：不做格式化、不查进程名、不碰 UI。
            diagnostics.record(
                type: type,
                keycode: keycode,
                pid: pid,
                stateID: event.getIntegerValueField(.eventSourceStateID),
                isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                characters: Self.characters(of: event),
                swallowed: swallowed
            )
        }

        return swallowed ? nil : Unmanaged.passUnretained(event)
    }

    /// 判定"非硬件输入"的唯一入口。若将来要转 HID 独占方案，只需改这里。
    private static func isRemoteEvent(pid: Int64) -> Bool {
        pid != 0 && pid != Int64(getpid())
    }

    private static func characters(of event: CGEvent) -> String {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(
            maxStringLength: 4,
            actualStringLength: &length,
            unicodeString: &buffer
        )
        guard length > 0 else { return "" }
        return String(utf16CodeUnits: buffer, count: length)
    }

    private static func modifierKeycodes(for flags: CGEventFlags) -> Set<Int64> {
        var keycodes: Set<Int64> = []
        if flags.contains(.maskCommand) { keycodes.insert(55) }
        if flags.contains(.maskShift) { keycodes.insert(56) }
        if flags.contains(.maskAlternate) { keycodes.insert(58) }
        if flags.contains(.maskControl) { keycodes.insert(59) }
        if flags.contains(.maskAlphaShift) { keycodes.insert(57) }
        if flags.contains(.maskSecondaryFn) { keycodes.insert(63) }
        return keycodes
    }

    // MARK: - 定时器

    private func startTimers() {
        stopTimers()

        let tick = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        tick.tolerance = 0.15
        RunLoop.main.add(tick, forMode: .common)
        tickTimer = tick

        let watchdog = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.watchdogTick()
        }
        watchdog.tolerance = 0.3
        RunLoop.main.add(watchdog, forMode: .common)
        watchdogTimer = watchdog
    }

    private func stopTimers() {
        tickTimer?.invalidate()
        tickTimer = nil
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

    private func tick() {
        guard isLocked else { return }
        if let autoUnlockAt = autoUnlockAt, Date() >= autoUnlockAt {
            unlock(reason: .autoTimeout)
            return
        }
        onStateChange?()
    }

    /// 看门狗：绝不"显示已锁定但实际没拦"。
    private func watchdogTick() {
        guard isLocked else { return }

        guard AXIsProcessTrusted() else {
            unlock(reason: .permissionLost)
            return
        }
        guard let tap = tap else {
            unlock(reason: .watchdog)
            return
        }
        if CGEvent.tapIsEnabled(tap: tap) {
            watchdogFailures = 0
            return
        }

        CGEvent.tapEnable(tap: tap, enable: true)
        watchdogFailures += 1
        diagnostics.note("tap 处于禁用状态，尝试恢复（第 \(watchdogFailures) 次）")
        if watchdogFailures >= 3 {
            unlock(reason: .watchdog)
        }
    }
}

/// tap 回调必须是 C 函数指针，不能捕获上下文，因此用 refcon 回取实例。
private func keyMuteEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
    let service = Unmanaged<KeyboardLockService>.fromOpaque(refcon).takeUnretainedValue()
    return service.handle(type: type, event: event)
}
