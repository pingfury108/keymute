import AppKit

// 无 Dock 图标的菜单栏 App：不走 @main，显式装配 NSApplication。
let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.accessory)
app.run()
