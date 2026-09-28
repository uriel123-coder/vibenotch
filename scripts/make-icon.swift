import AppKit

// Renders Resources/AppIcon.iconset: a black squircle holding a small notch pill and a sparkle.
let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data? {
    let s = CGFloat(px)
    let image = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
        let inset = s * 0.1
        let body = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
        let squircle = NSBezierPath(roundedRect: body, xRadius: body.width * 0.23, yRadius: body.width * 0.23)
        NSGradient(starting: NSColor(white: 0.16, alpha: 1), ending: NSColor(white: 0.02, alpha: 1))?.draw(in: squircle, angle: -90)

        let pillW = body.width * 0.56, pillH = body.height * 0.2
        let pill = NSRect(x: body.midX - pillW / 2, y: body.maxY - pillH - body.height * 0.14, width: pillW, height: pillH)
        NSColor.black.setFill()
        NSBezierPath(roundedRect: pill, xRadius: pillH / 2, yRadius: pillH / 2).fill()
        NSColor(white: 1, alpha: 0.12).setStroke()
        let outline = NSBezierPath(roundedRect: pill, xRadius: pillH / 2, yRadius: pillH / 2)
        outline.lineWidth = max(1, s * 0.006)
        outline.stroke()

        let dot = pillH * 0.34
        NSColor(red: 0.36, green: 0.86, blue: 0.52, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: pill.maxX - pillH * 0.5 - dot / 2, y: pill.midY - dot / 2, width: dot, height: dot)).fill()

        let config = NSImage.SymbolConfiguration(pointSize: body.width * 0.36, weight: .semibold)
            .applying(.init(paletteColors: [NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1)]))
        if let sparkle = NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let sz = sparkle.size
            sparkle.draw(in: NSRect(x: body.midX - sz.width / 2, y: body.minY + body.height * 0.2, width: sz.width, height: sz.height))
        }
        return true
    }
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
    rep.size = NSSize(width: px, height: px)
    return rep.representation(using: .png, properties: [:])
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try? render(base * scale)?.write(to: out.appendingPathComponent(name))
    }
}
