import AppKit

/// 事件来源记录（P0 诊断用），分两段：
/// - `record`：在 tap 回调里调用，只做结构体入队，绝不格式化/查进程/碰 UI；
/// - `flush`：由诊断面板定时器在回调之外调用，做格式化与进程名解析。
final class Diagnostics {

    struct RawEvent {
        let time: Date
        let type: UInt32
        let keycode: Int64
        let pid: Int64
        let stateID: Int64
        let isRepeat: Bool
        let characters: String
        let swallowed: Bool
    }

    struct Line {
        let text: String
        let swallowed: Bool
    }

    private enum Item {
        case event(RawEvent)
        case note(Date, String)
    }

    /// NX_SYSDEFINED 的 CGEventType rawValue（CGEventType 没有具名常量）。
    static let systemDefinedRawValue: UInt32 = 14

    private let pendingCapacity = 4000
    private let historyCapacity = 2000

    private var pending: [Item] = []
    private var history: [Line] = []
    private var processNameCache: [Int64: String] = [:]

    /// 面板打开时为 true；关闭后停止记录按键事件。
    var isCapturing = false

    // MARK: - 写入（tap 回调里调用，必须极快）

    func record(
        type: CGEventType,
        keycode: Int64,
        pid: Int64,
        stateID: Int64,
        isRepeat: Bool,
        characters: String,
        swallowed: Bool
    ) {
        guard isCapturing else { return }
        pending.append(.event(RawEvent(
            time: Date(),
            type: type.rawValue,
            keycode: keycode,
            pid: pid,
            stateID: stateID,
            isRepeat: isRepeat,
            characters: characters,
            swallowed: swallowed
        )))
        if pending.count > pendingCapacity {
            pending.removeFirst(pending.count - pendingCapacity)
        }
    }

    func note(_ text: String) {
        pending.append(.note(Date(), text))
        if pending.count > pendingCapacity {
            pending.removeFirst(pending.count - pendingCapacity)
        }
    }

    // MARK: - 读取（面板定时器里调用）

    var allLines: [Line] { history }

    func clear() {
        pending.removeAll()
        history.removeAll()
        processNameCache.removeAll()
    }

    @discardableResult
    func flush() -> [Line] {
        guard !pending.isEmpty else { return [] }
        let items = pending
        pending.removeAll(keepingCapacity: true)

        var fresh: [Line] = []
        fresh.reserveCapacity(items.count)
        for item in items {
            switch item {
            case .note(let date, let text):
                fresh.append(Line(text: "\(Self.timestamp(date)) | note | \(text)", swallowed: false))
            case .event(let raw):
                fresh.append(Line(text: format(raw), swallowed: raw.swallowed))
            }
        }

        history.append(contentsOf: fresh)
        if history.count > historyCapacity {
            history.removeFirst(history.count - historyCapacity)
        }
        return fresh
    }

    // MARK: - 格式化

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private static func timestamp(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    private func format(_ raw: RawEvent) -> String {
        var fields = [
            Self.timestamp(raw.time),
            Self.typeName(raw.type),
            "key=\(raw.characters.isEmpty ? (Self.modifierName(raw.keycode) ?? "-") : raw.characters)",
            "kc=\(raw.keycode)",
            "pid=\(raw.pid)",
            "src=\(Self.sourceName(raw.stateID))",
            "from=\(originName(raw.pid))",
        ]
        if raw.isRepeat { fields.append("repeat") }
        fields.append(raw.swallowed ? "→ 吞掉" : "→ 放行")
        return fields.joined(separator: " | ")
    }

    private static func typeName(_ rawValue: UInt32) -> String {
        switch rawValue {
        case CGEventType.keyDown.rawValue: return "keyDown"
        case CGEventType.keyUp.rawValue: return "keyUp"
        case CGEventType.flagsChanged.rawValue: return "flagsChanged"
        case systemDefinedRawValue: return "systemDefined"
        default: return "type(\(rawValue))"
        }
    }

    private static func sourceName(_ stateID: Int64) -> String {
        switch stateID {
        case -1: return "private"
        case 0: return "session"
        case 1: return "hid"
        default: return "state(\(stateID))"
        }
    }

    private static func modifierName(_ keycode: Int64) -> String? {
        switch keycode {
        case 54, 55: return "⌘"
        case 56, 60: return "⇧"
        case 58, 61: return "⌥"
        case 59, 62: return "⌃"
        case 57: return "⇪"
        case 63: return "fn"
        default: return nil
        }
    }

    /// 进程名解析（LaunchServices 查询）只在 flush 里做，且带缓存。
    private func originName(_ pid: Int64) -> String {
        if pid == 0 { return "hardware" }
        if pid == Int64(getpid()) { return "self" }
        if let cached = processNameCache[pid] { return cached }

        let name: String
        if let app = NSRunningApplication(processIdentifier: pid_t(pid)) {
            name = app.localizedName ?? app.bundleIdentifier ?? "pid \(pid)"
        } else {
            name = "pid \(pid)"
        }
        processNameCache[pid] = name
        return name
    }
}

/// 自测注入：用私有事件源发一个按键，来源 PID 是本进程，
/// 因此锁定时它必须仍然生效（等价于验证 F4）。
enum InjectedKeyTest {

    @discardableResult
    static func post(character keycode: CGKeyCode = 0) -> Bool {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keycode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keycode, keyDown: false)
        else { return false }

        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
        return true
    }
}
