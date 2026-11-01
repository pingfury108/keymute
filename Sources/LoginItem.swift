import Foundation
import ServiceManagement

/// 开机自启（macOS 13+ 的 SMAppService，不需要 root、不需要 helper）。
/// 注册的是「主 App」，所以要把 App 放到固定位置（/Applications）后再开。
enum LoginItem {

    enum State {
        case enabled
        case disabled
        /// 已在系统里注册，但需要用户到「登录项」里手动允许
        case requiresApproval
    }

    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        default:
            return .disabled
        }
    }

    /// 返回 nil 表示成功，否则是失败原因。
    static func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
