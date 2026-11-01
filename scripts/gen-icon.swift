// 生成 App 图标（不依赖任何外部素材，用 SF Symbols 画）。
// 用法：swift scripts/gen-icon.swift build/AppIcon.iconset
// 之后：iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
import AppKit

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/AppIcon.iconset"
let fileManager = FileManager.default
try? fileManager.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

/// 在指定像素尺寸下画一张图标：深色圆角底 + 白色键盘符号。
func renderIcon(pixelSize: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    let side = CGFloat(pixelSize)
    let inset = side * 0.098
    let rect = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let radius = rect.width * 0.2237
    let background = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.16, green: 0.19, blue: 0.26, alpha: 1),
        NSColor(srgbRed: 0.31, green: 0.37, blue: 0.50, alpha: 1),
    ])
    gradient?.draw(in: background, angle: -90)

    if let symbol = NSImage(
        systemSymbolName: "keyboard",
        accessibilityDescription: nil
    )?.withSymbolConfiguration(.init(pointSize: side * 0.40, weight: .regular)) {
        let tinted = tint(symbol, color: NSColor(srgbRed: 0.96, green: 0.97, blue: 1.0, alpha: 1))
        let target = targetRect(for: tinted.size, side: side)
        tinted.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)
    }

    return rep.representation(using: .png, properties: [:])
}

func tint(_ image: NSImage, color: NSColor) -> NSImage {
    let out = NSImage(size: image.size)
    out.lockFocus()
    color.set()
    NSRect(origin: .zero, size: image.size).fill()
    image.draw(in: NSRect(origin: .zero, size: image.size), from: .zero, operation: .destinationIn, fraction: 1)
    out.unlockFocus()
    return out
}

func targetRect(for symbolSize: NSSize, side: CGFloat) -> NSRect {
    let scale = min(side * 0.62 / symbolSize.width, side * 0.62 / symbolSize.height)
    let width = symbolSize.width * scale
    let height = symbolSize.height * scale
    return NSRect(x: (side - width) / 2, y: (side - height) / 2, width: width, height: height)
}

let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for variant in variants {
    guard let data = renderIcon(pixelSize: variant.pixels) else {
        FileHandle.standardError.write(Data("渲染失败：\(variant.name)\n".utf8))
        exit(1)
    }
    let path = "\(outputDir)/\(variant.name)"
    try data.write(to: URL(fileURLWithPath: path))
}

print("✅ 图标已生成：\(outputDir)")
