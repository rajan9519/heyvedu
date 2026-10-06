// Draws the DMG window background: a heading and an arrow from the app icon to the
// Applications shortcut. Positions must match the Finder layout in release.sh.
//   swift scripts/make-dmg-background.swift OUTPUT.png SCALE
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 3, let scale = Double(arguments[2]) else {
    FileHandle.standardError.write(Data("usage: make-dmg-background.swift OUTPUT.png SCALE\n".utf8))
    exit(2)
}

let size = NSSize(width: 640, height: 400)  // Finder window content size, in points
let ink = NSColor(srgbRed: 0.13, green: 0.12, blue: 0.11, alpha: 1)
let muted = NSColor(srgbRed: 0.42, green: 0.40, blue: 0.37, alpha: 1)

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
else { exit(1) }
bitmap.size = size  // draw in points; the rep supplies the pixel density
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

NSColor(srgbRed: 0.961, green: 0.949, blue: 0.918, alpha: 1).setFill()  // #f5f2ea, as on the website
NSRect(origin: .zero, size: size).fill()

// AppKit's origin is bottom-left; the layout below is measured from the window's top edge.
let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center
NSString(string: "Drag HeyVedu to Applications").draw(
    in: NSRect(x: 0, y: size.height - 80, width: size.width, height: 34),
    withAttributes: [
        .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
        .foregroundColor: ink, .paragraphStyle: paragraph,
    ])

// Arrow between the icon centres at (160, 200) and (480, 200).
let arrowY = size.height - 200
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 248, y: arrowY))
arrow.line(to: NSPoint(x: 378, y: arrowY))
arrow.lineWidth = 4
arrow.lineCapStyle = .round
muted.setStroke()
arrow.stroke()
let head = NSBezierPath()
head.move(to: NSPoint(x: 392, y: arrowY))
head.line(to: NSPoint(x: 372, y: arrowY + 13))
head.line(to: NSPoint(x: 372, y: arrowY - 13))
head.close()
muted.setFill()
head.fill()

NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: arguments[1]))
