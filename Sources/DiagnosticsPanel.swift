import AppKit

/// 诊断日志窗口：只读日志流 + 暂停/清空/注入自测。
///
/// 关键点：所有渲染都在 10Hz 定时器里做（tap 回调之外），
/// 窗口不激活 App、不抢焦点，避免"输入进了诊断窗口"。
final class DiagnosticsPanel: NSObject, NSWindowDelegate {

    private let diagnostics: Diagnostics
    private var panel: NSPanel?
    private var textView: NSTextView?
    private var captureButton: NSButton?
    private var drainTimer: Timer?

    private let drainInterval: TimeInterval = 0.1
    private let textLimit = 300_000
    private let trimChunk = 60_000

    init(diagnostics: Diagnostics) {
        self.diagnostics = diagnostics
        super.init()
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        diagnostics.isCapturing = true
        captureButton?.title = "暂停记录"
        _ = diagnostics.flush()
        reloadText()
        startDraining()
        panel.orderFrontRegardless()
    }

    // MARK: - 构建

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 420),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "KeyMute 诊断"
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.center()

        let content = NSView()

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        // 长日志下布局走非连续布局，避免每次追加都重排整个文档。
        textView.layoutManager?.allowsNonContiguousLayout = true
        scrollView.documentView = textView
        self.textView = textView

        let captureButton = NSButton(title: "暂停记录", target: self, action: #selector(toggleCapture(_:)))
        captureButton.bezelStyle = .rounded
        self.captureButton = captureButton

        let clearButton = NSButton(title: "清空", target: self, action: #selector(clearLog))
        clearButton.bezelStyle = .rounded

        let injectButton = NSButton(title: "注入测试按键", target: self, action: #selector(injectTestKey))
        injectButton.bezelStyle = .rounded

        let hint = NSTextField(labelWithString: "pid=0 → 本地硬件键（锁定时吞掉）　pid≠0 → 注入（放行）")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let closeButton = NSButton(title: "关闭", target: self, action: #selector(closePanel))
        closeButton.bezelStyle = .rounded

        let buttonRow = NSStackView(views: [captureButton, clearButton, injectButton, hint, closeButton])
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 10, right: 12)

        content.addSubview(scrollView)
        content.addSubview(buttonRow)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: buttonRow.topAnchor),
            buttonRow.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            buttonRow.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            buttonRow.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        panel.contentView = content
        return panel
    }

    // MARK: - 渲染

    private func startDraining() {
        stopDraining()
        let timer = Timer(timeInterval: drainInterval, repeats: true) { [weak self] _ in
            self?.drain()
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        drainTimer = timer
    }

    private func stopDraining() {
        drainTimer?.invalidate()
        drainTimer = nil
    }

    private func drain() {
        let fresh = diagnostics.flush()
        guard !fresh.isEmpty else { return }
        append(fresh)
    }

    private func reloadText() {
        guard let textView = textView else { return }
        let lines = diagnostics.allLines
        textView.string = lines.map(\.text).joined(separator: "\n")
        textView.scrollToEndOfDocument(nil)
    }

    private func append(_ lines: [Diagnostics.Line]) {
        guard let textView = textView, let storage = textView.textStorage else { return }

        if storage.length > textLimit {
            storage.deleteCharacters(in: NSRange(location: 0, length: trimChunk))
        }

        let prefix = storage.length == 0 ? "" : "\n"
        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: prefix))
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        for line in lines {
            text.append(NSAttributedString(
                string: line.text + "\n",
                attributes: [
                    .font: font,
                    .foregroundColor: line.swallowed ? NSColor.systemRed : NSColor.labelColor,
                ]
            ))
        }
        storage.append(text)
        textView.scrollToEndOfDocument(nil)
    }

    // MARK: - 动作

    @objc private func toggleCapture(_ sender: NSButton) {
        diagnostics.isCapturing.toggle()
        sender.title = diagnostics.isCapturing ? "暂停记录" : "继续记录"
    }

    @objc private func clearLog() {
        diagnostics.clear()
        textView?.string = ""
    }

    @objc private func injectTestKey() {
        let posted = InjectedKeyTest.post(character: 0)
        diagnostics.note(posted ? "已注入测试按键 a（来源为本进程，锁定时应放行）" : "注入测试按键失败")
    }

    @objc private func closePanel() {
        panel?.close()
    }

    func windowWillClose(_ notification: Notification) {
        diagnostics.isCapturing = false
        stopDraining()
        captureButton?.title = "继续记录"
    }
}
