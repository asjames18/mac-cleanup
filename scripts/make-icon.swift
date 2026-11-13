import AppKit

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let rect = NSRect(x: 0, y: 0, width: pixels, height: pixels)
        let inset = Double(pixels) * 0.07
        let shape = NSBezierPath(roundedRect: rect.insetBy(dx: inset, dy: inset), xRadius: Double(pixels) * 0.2, yRadius: Double(pixels) * 0.2)
        NSGradient(starting: NSColor(calibratedRed: 0.08, green: 0.72, blue: 0.66, alpha: 1), ending: NSColor(calibratedRed: 0.01, green: 0.28, blue: 0.4, alpha: 1))!.draw(in: shape, angle: -55)
        let circle = NSBezierPath(ovalIn: rect.insetBy(dx: Double(pixels) * 0.21, dy: Double(pixels) * 0.21))
        NSColor.white.withAlphaComponent(0.18).setStroke()
        circle.lineWidth = Double(pixels) * 0.025
        circle.stroke()
        let config = NSImage.SymbolConfiguration(pointSize: Double(pixels) * 0.43, weight: .light)
        if let symbol = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let symbolRect = NSRect(x: Double(pixels) * 0.27, y: Double(pixels) * 0.25, width: Double(pixels) * 0.46, height: Double(pixels) * 0.5)
            let white = NSImage(size: symbolRect.size)
            white.lockFocus()
            symbol.draw(in: NSRect(origin: .zero, size: symbolRect.size))
            NSColor.white.setFill()
            NSRect(origin: .zero, size: symbolRect.size).fill(using: .sourceAtop)
            white.unlockFocus()
            white.draw(in: symbolRect)
        }
        image.unlockFocus()
        let data = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        let suffix = scale == 2 ? "@2x" : ""
        try data.write(to: destination.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
