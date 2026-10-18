// Renders the EvenSound app icon (same design as the Android launcher icon) as a 1024x1024 PNG.
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// macOS icon grid: a rounded square of 824 pt centred in 1024, leaving room for the shadow.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.shadowBlurRadius = 28
NSGraphicsContext.saveGraphicsState()
shadow.set()
NSColor(srgbRed: 0x0B / 255.0, green: 0x6E / 255.0, blue: 0x8C / 255.0, alpha: 1).setFill()
NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185).fill()
NSGraphicsContext.restoreGraphicsState()

// Five bars, same proportions as the Android icon, centred on the tile and drawn larger to suit
// the macOS icon grid. Units are the Android 108-unit grid, relative to its centre (54, 54).
let scale: CGFloat = 824 / 108 * 1.45
func unit(_ v: CGFloat) -> CGFloat { v * scale }
NSColor.white.setFill()
let bars: [(centreX: CGFloat, height: CGFloat)] = [(-20, 10), (-10, 26), (0, 40), (10, 26), (20, 10)]
for bar in bars {
    let rect = NSRect(
        x: tile.midX + unit(bar.centreX - 3),
        y: tile.midY - unit(bar.height / 2),
        width: unit(6),
        height: unit(bar.height))
    NSBezierPath(roundedRect: rect, xRadius: unit(3), yRadius: unit(3)).fill()
}
image.unlockFocus()

guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { fatalError("Couldn't render icon") }
try! png.write(to: URL(fileURLWithPath: output))
