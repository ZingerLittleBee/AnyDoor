import AppKit

// Renders the real AnyDoor builtin SF Symbols (BuiltinItem.symbol) to white PNGs
// so the Remotion promo MenuPanel can show the actual app icons instead of letters.
// Run from the `video/` directory: `swift scripts/render-symbols.swift`

// SF Symbol name -> output asset stem (dots -> underscores). Mirrors the symbols
// used by the panel rows in src/ui/MenuPanel.tsx.
let symbols: [String] = [
    "keyboard",
    "network",
    "cup.and.saucer.fill",
    "speaker.slash.fill",
    "rectangle.on.rectangle.slash",
    "eye.fill",
    "moon.fill",
    "lock.fill",
    "trash.fill",
    "camera.viewfinder",
    "doc.on.clipboard",
    "moon.zzz.fill",
    "powersleep",
    "dock.rectangle",
    "menubar.rectangle",
    "macwindow.on.rectangle",
    "dock.arrow.down.rectangle",
    "menubar.arrow.up.rectangle",
    "keyboard.fill",
    "text.viewfinder",
    "eyedropper",
    "qrcode.viewfinder",
    "sun.max",
    "macwindow",
    "list.bullet.rectangle",
]

let outDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("public/icons")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// Large point size so the downscaled badge glyph stays crisp at 1080p.
let config = NSImage.SymbolConfiguration(pointSize: 120, weight: .semibold)

var missing: [String] = []
for name in symbols {
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else {
        missing.append(name)
        continue
    }
    let size = base.size
    let canvas = NSImage(size: size)
    canvas.lockFocus()
    base.draw(in: NSRect(origin: .zero, size: size))
    NSColor.white.setFill()
    NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
    canvas.unlockFocus()

    guard let tiff = canvas.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        missing.append(name)
        continue
    }
    let stem = name.replacingOccurrences(of: ".", with: "_")
    let url = outDir.appendingPathComponent("\(stem).png")
    try? png.write(to: url)
    print("✓ \(name) -> \(stem).png  \(Int(size.width))x\(Int(size.height))")
}

if missing.isEmpty {
    print("All \(symbols.count) symbols rendered.")
} else {
    FileHandle.standardError.write("MISSING: \(missing.joined(separator: ", "))\n".data(using: .utf8)!)
    exit(1)
}
