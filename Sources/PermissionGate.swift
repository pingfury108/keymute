import AppKit
import ApplicationServices

/// 辅助功能权限检查与引导。
/// 不再预装事件 tap：tap 只在锁定时创建，未授权时轮询等待。
final class PermissionGate {

    private let diagnostics: Diagnostics
    private var pollTimer: Timer?

    private(set) var isTrusted: Bool = AXIsProcessTrusted()
    var onChange: (() -> Void)?

    init(diagnostics: Diagnostics) {
        self.diagnostics = diagnostics
    }

    func start() {
        isTrusted = AXIsProcessTrusted()
        guard !isTrusted else { return }
        diagnostics.note("尚未获得辅助功能权限，等待授权")
        startPolling()
    }

    /// 不弹窗，仅刷新当前信任状态（运行中权限被撤销时由 UI 调用）。
    func refreshTrustState() {
        let trusted = AXIsProcessTrusted()
        guard trusted != isTrusted else { return }
        isTrusted = trusted
        if !trusted {
            startPolling()
        }
    }

    /// 触发系统授权弹窗（只在用户主动点击时调用）。
    func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        isTrusted = AXIsProcessTrustedWithOptions(options)
        onChange?()
        if !isTrusted {
            startPolling()
        }
    }

    func openSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.poll()
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func poll() {
        guard AXIsProcessTrusted() else { return }
        isTrusted = true
        stopPolling()
        diagnostics.note("辅助功能权限已获得")
        onChange?()
    }
}
