// Zeichnet das App-Symbol (1024 × 1024 PNG): Verlauf vom Abendlicht ins Nachtblau,
// in der Mitte eine Sonne am Horizont.
// Aufruf: swift icon.swift ziel.png
import AppKit

let ziel = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func farbe(_ hex: Int) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}

let kachel = NSRect(x: 100, y: 100, width: 824, height: 824)
let form = NSBezierPath(roundedRect: kachel, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let schatten = NSShadow()
schatten.shadowColor = NSColor.black.withAlphaComponent(0.3)
schatten.shadowOffset = NSSize(width: 0, height: -12)
schatten.shadowBlurRadius = 28
schatten.set()
farbe(0x2b2f6b).setFill()
form.fill()
NSGraphicsContext.restoreGraphicsState()
// oben noch Abendlicht, unten schon Nacht
NSGradient(colors: [farbe(0xffb25c), farbe(0xe0708a), farbe(0x6a5ab8), farbe(0x232a5e)],
           atLocations: [0, 0.3, 0.65, 1], colorSpace: .sRGB)!.draw(in: form, angle: -90)

func zeichne(_ name: String, in rect: NSRect) {
    let konf = NSImage.SymbolConfiguration(pointSize: 400, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    guard let bild = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(konf) else { return }
    // Seitenverhältnis halten
    let s = bild.size, f = min(rect.width / s.width, rect.height / s.height)
    let r = NSRect(x: rect.midX - s.width * f / 2, y: rect.midY - s.height * f / 2,
                   width: s.width * f, height: s.height * f)
    bild.draw(in: r)
}
zeichne("sun.horizon.fill", in: NSRect(x: 222, y: 222, width: 580, height: 580))

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: ziel))
