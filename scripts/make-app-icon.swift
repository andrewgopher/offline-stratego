// Draws the iPhone/iPad app icon (1024×1024, opaque) in the app's piece style:
//     swift scripts/make-app-icon.swift iOS/Assets.xcassets/AppIcon.appiconset/AppIcon.png
import AppKit

let size = 1024
let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                 samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32),
      let context = NSGraphicsContext(bitmapImageRep: rep)
else { fatalError("couldn't create the bitmap") }
NSGraphicsContext.current = context
let cg = context.cgContext

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor { NSColor(deviceRed: r, green: g, blue: b, alpha: 1) }

// The field.
NSGradient(starting: color(0.84, 0.88, 0.70), ending: color(0.66, 0.76, 0.52))!
    .draw(in: NSRect(x: 0, y: 0, width: size, height: size), angle: -90)
// A hint of the board's squares.
for row in 0..<4 {
    for column in 0..<4 where (row + column) % 2 == 0 {
        color(0.0, 0.0, 0.0).withAlphaComponent(0.035).setFill()
        NSRect(x: column * 256, y: row * 256, width: 256, height: 256).fill()
    }
}

/// A piece: a rounded square with a top-to-bottom gradient, like `PieceToken`.
func piece(center: CGPoint, side: CGFloat, angle: CGFloat, light: NSColor, dark: NSColor, face: (CGRect) -> Void) {
    cg.saveGState()
    cg.translateBy(x: center.x, y: center.y)
    cg.rotate(by: angle * .pi / 180)
    let rect = CGRect(x: -side / 2, y: -side / 2, width: side, height: side)
    let path = NSBezierPath(roundedRect: rect, xRadius: side * 0.17, yRadius: side * 0.17)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 40
    shadow.shadowOffset = NSSize(width: 0, height: -18)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    dark.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: light, ending: dark)!.draw(in: path, angle: -90)
    NSColor.black.withAlphaComponent(0.35).setStroke()
    path.lineWidth = side * 0.03
    path.stroke()
    face(rect)
    cg.restoreGState()
}

// Behind: a blue piece, face down.
piece(center: CGPoint(x: 650, y: 610), side: 430, angle: 9,
      light: color(0.20, 0.42, 0.76), dark: color(0.10, 0.24, 0.50)) { rect in
    let inner = NSBezierPath(roundedRect: rect.insetBy(dx: rect.width * 0.17, dy: rect.height * 0.17),
                             xRadius: rect.width * 0.1, yRadius: rect.width * 0.1)
    NSColor.white.withAlphaComponent(0.35).setStroke()
    inner.lineWidth = rect.width * 0.045
    inner.stroke()
}

// In front: a red Marshal, face up.
piece(center: CGPoint(x: 410, y: 420), side: 500, angle: -7,
      light: color(0.80, 0.24, 0.20), dark: color(0.55, 0.12, 0.11)) { rect in
    let config = NSImage.SymbolConfiguration(pointSize: rect.width * 0.36, weight: .bold)
    if let crown = NSImage(systemSymbolName: "crown.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let tinted = NSImage(size: crown.size, flipped: false) { bounds in
            crown.draw(in: bounds)
            NSColor.white.set()
            bounds.fill(using: .sourceAtop)
            return true
        }
        let crownRect = CGRect(x: -tinted.size.width / 2, y: rect.height * 0.02, width: tinted.size.width, height: tinted.size.height)
        tinted.draw(in: crownRect)
    }
    let font = NSFont.systemFont(ofSize: rect.width * 0.34, weight: .heavy)
    let text = NSAttributedString(string: "10", attributes: [.font: font, .foregroundColor: NSColor.white])
    let textSize = text.size()
    text.draw(at: CGPoint(x: -textSize.width / 2, y: -rect.height * 0.40))
}

NSGraphicsContext.current = nil
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("couldn't encode the PNG") }
try png.write(to: URL(fileURLWithPath: output))
print("Wrote \(output)")
