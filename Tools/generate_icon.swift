// Draws Resources/AppIcon.png: the same SF Symbol as the menu bar item, white on an indigo
// tile, so the app icon and the menu bar item read as one thing. Run via ./Tools/make_icns.sh.
import AppKit

let size = CGFloat(1024)
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let rect = NSRect(x: 0, y: 0, width: size, height: size)
let tile = NSBezierPath(roundedRect: rect, xRadius: size * 0.225, yRadius: size * 0.225)
NSGradient(colors: [
    NSColor(srgbRed: 0.36, green: 0.42, blue: 0.95, alpha: 1),
    NSColor(srgbRed: 0.20, green: 0.20, blue: 0.62, alpha: 1),
])?.draw(in: tile, angle: -90)

let config = NSImage.SymbolConfiguration(pointSize: size * 0.42, weight: .regular)
    .applying(.init(paletteColors: [.white]))
guard let symbol = NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: nil)?
    .withSymbolConfiguration(config)
else { fatalError("Symbol missing") }
let s = symbol.size
symbol.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2, width: s.width, height: s.height))
image.unlockFocus()

// lockFocus renders at the display's backing scale; read back whatever came out and let
// sips downsample.
guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:])
else { fatalError("Could not render the icon.") }
try! png.write(to: URL(fileURLWithPath: "Resources/AppIcon.png"))
print("Wrote Resources/AppIcon.png at \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
