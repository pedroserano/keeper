// Draws Keeper's app icon in the macOS style: a continuous-corner tile with a soft glassy light,
// one photo print turned slightly, and a sparkle: the library getting better.
// Writes Resources/AppIcon-1024.png and Resources/Keeper.icns.
//
//   swift scripts/make-icon.swift

import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func withShadow(_ blur: CGFloat, _ offset: CGSize, _ shadowColor: NSColor, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = blur
    shadow.shadowOffset = offset
    shadow.shadowColor = shadowColor
    shadow.set()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

func rotated(_ degrees: CGFloat, around center: CGPoint, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let t = NSAffineTransform()
    t.translateX(by: center.x, yBy: center.y)
    t.rotate(byDegrees: degrees)
    t.translateX(by: -center.x, yBy: -center.y)
    t.concat()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

/// A superellipse ("squircle"): the continuous corners of macOS icons, which a plain rounded
/// rectangle only approximates.
func squircle(_ rect: NSRect, exponent n: CGFloat = 5) -> NSBezierPath {
    let path = NSBezierPath()
    let a = rect.width / 2, b = rect.height / 2, c = CGPoint(x: rect.midX, y: rect.midY)
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = c.x + a * (ct < 0 ? -1 : 1) * pow(abs(ct), 2 / n)
        let y = c.y + b * (st < 0 ? -1 : 1) * pow(abs(st), 2 / n)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.line(to: CGPoint(x: x, y: y)) }
    }
    path.close()
    return path
}

/// A four-pointed sparkle with curved sides, centred on `c`.
func sparklePath(_ c: CGPoint, _ r: CGFloat, waist: CGFloat = 0.18) -> NSBezierPath {
    let p = NSBezierPath()
    let tips = [CGPoint(x: c.x, y: c.y + r), CGPoint(x: c.x + r, y: c.y),
                CGPoint(x: c.x, y: c.y - r), CGPoint(x: c.x - r, y: c.y)]
    p.move(to: tips[0])
    for i in 0..<4 {
        let next = tips[(i + 1) % 4]
        // Pull each side in towards the centre for the pinched star shape.
        let control = CGPoint(x: c.x + (tips[i].x - c.x + next.x - c.x) * waist,
                              y: c.y + (tips[i].y - c.y + next.y - c.y) * waist)
        p.curve(to: next, controlPoint1: control, controlPoint2: control)
    }
    p.close()
    return p
}

image.lockFocus()

// Tile: the standard macOS icon area (824 of 1024), with its drop shadow.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = squircle(tile, exponent: 4.2)
withShadow(28, CGSize(width: 0, height: -10), color(0x000000, 0.30)) {
    color(0x2B4FD8).setFill()
    tilePath.fill()
}
NSGraphicsContext.saveGraphicsState()
tilePath.addClip()
// Deep blue to violet, lit from the top.
NSGradient(colors: [color(0x5AA2FF), color(0x3A5BEA), color(0x5B33C9)],
           atLocations: [0, 0.55, 1], colorSpace: .sRGB)!.draw(in: tile, angle: -90)
// Glass: a soft sheen over the top half, and a glow behind where the sparkle sits.
NSGradient(colors: [color(0xFFFFFF, 0.28), color(0xFFFFFF, 0)])!
    .draw(in: NSRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)
NSGradient(colors: [color(0xFFF4C2, 0.55), color(0xFFF4C2, 0)])!
    .draw(fromCenter: CGPoint(x: 712, y: 700), radius: 0, toCenter: CGPoint(x: 712, y: 700), radius: 300, options: [])

// One print, turned a little, with a landscape: sky, sun, hills.
rotated(-8, around: CGPoint(x: 492, y: 470)) {
    let card = NSRect(x: 492 - 250, y: 470 - 205, width: 500, height: 410)
    withShadow(36, CGSize(width: 0, height: -18), color(0x1A0F5C, 0.45)) {
        color(0xFFFFFF).setFill()
        NSBezierPath(roundedRect: card, xRadius: 40, yRadius: 40).fill()
    }
    let photo = card.insetBy(dx: 28, dy: 28)
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: photo, xRadius: 20, yRadius: 20).addClip()
    NSGradient(colors: [color(0xFFB27A), color(0xFFD9A8), color(0xBFE3FF)],
               atLocations: [0, 0.45, 1], colorSpace: .sRGB)!.draw(in: photo, angle: 90)
    color(0xFFF1B8).setFill()
    NSBezierPath(ovalIn: NSRect(x: photo.minX + 70, y: photo.minY + 120, width: 92, height: 92)).fill()
    color(0x4FA87A).setFill()
    NSBezierPath(ovalIn: NSRect(x: photo.minX - 90, y: photo.minY - 190, width: 380, height: 300)).fill()
    color(0x2F7F67).setFill()
    NSBezierPath(ovalIn: NSRect(x: photo.minX + 150, y: photo.minY - 230, width: 420, height: 320)).fill()
    NSGraphicsContext.restoreGraphicsState()
}

// The sparkle, big at the print's top right, with a small companion.
let star = CGPoint(x: 712, y: 700)
withShadow(30, CGSize(width: 0, height: -6), color(0xFFB300, 0.55)) {
    NSGradient(colors: [color(0xFFFFFF), color(0xFFE48A)])!
        .draw(in: sparklePath(star, 150), angle: -90)
}
withShadow(14, .zero, color(0xFFB300, 0.5)) {
    color(0xFFFFFF).setFill()
    sparklePath(CGPoint(x: 820, y: 560), 52).fill()
}

// A fine light edge, as glass catches light at its rim.
color(0xFFFFFF, 0.22).setStroke()
let rim = squircle(tile.insetBy(dx: 2, dy: 2), exponent: 4.2)
rim.lineWidth = 4
rim.stroke()
NSGraphicsContext.restoreGraphicsState()

image.unlockFocus()

// Write the 1024 master, then every size macOS wants, then the .icns.
let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let resources = root.appendingPathComponent("Resources")
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024))
NSGraphicsContext.restoreGraphicsState()
let master = resources.appendingPathComponent("AppIcon-1024.png")
try! rep.representation(using: .png, properties: [:])!.write(to: master)

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Keeper.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = points * scale
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        try! out.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("Keeper.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
print("Wrote \(master.path) and Resources/Keeper.icns")
