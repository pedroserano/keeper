// Draws Winnow's app icon: the grain worth keeping (a smiling wheat grain with a sprout) in front
// of two photo prints, on a mint-to-teal tile. Writes Resources/AppIcon-1024.png and Resources/Winnow.icns.
//
//   swift scripts/make-icon.swift

import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func withShadow(_ blur: CGFloat, _ offset: CGSize, _ alpha: CGFloat, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = blur
    shadow.shadowOffset = offset
    shadow.shadowColor = NSColor.black.withAlphaComponent(alpha)
    shadow.set()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

/// Runs `draw` rotated by `degrees` around `center`.
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

/// A white print with a little landscape: sky, sun, two hills.
func photoCard(center: CGPoint, degrees: CGFloat, sky: (UInt32, UInt32), hills: (UInt32, UInt32)) {
    rotated(degrees, around: center) {
        let card = NSRect(x: center.x - 215, y: center.y - 180, width: 430, height: 360)
        withShadow(28, CGSize(width: 0, height: -14), 0.22) {
            color(0xFFFFFF).setFill()
            NSBezierPath(roundedRect: card, xRadius: 34, yRadius: 34).fill()
        }
        let photo = card.insetBy(dx: 26, dy: 26)
        let clip = NSBezierPath(roundedRect: photo, xRadius: 18, yRadius: 18)
        NSGraphicsContext.saveGraphicsState()
        clip.addClip()
        NSGradient(starting: color(sky.0), ending: color(sky.1))!.draw(in: photo, angle: -90)
        color(0xFFE27A).setFill()
        NSBezierPath(ovalIn: NSRect(x: photo.maxX - 120, y: photo.maxY - 115, width: 76, height: 76)).fill()
        color(hills.0).setFill()
        NSBezierPath(ovalIn: NSRect(x: photo.minX - 80, y: photo.minY - 170, width: 330, height: 280)).fill()
        color(hills.1).setFill()
        NSBezierPath(ovalIn: NSRect(x: photo.minX + 130, y: photo.minY - 200, width: 360, height: 290)).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

image.lockFocus()

// Tile: the standard macOS icon area (824 of 1024) with soft corners.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 186, yRadius: 186)
withShadow(30, CGSize(width: 0, height: -12), 0.28) {
    color(0x6FCFBF).setFill()
    tilePath.fill()
}
NSGraphicsContext.saveGraphicsState()
tilePath.addClip()
NSGradient(starting: color(0x8EE0C9), ending: color(0x3E97C2))!.draw(in: tile, angle: -70)
// A soft light from the top left, fading out with no edge.
NSGradient(colors: [color(0xFFFFFF, 0.30), color(0xFFFFFF, 0.08), color(0xFFFFFF, 0)])!
    .draw(in: tile, relativeCenterPosition: NSPoint(x: -0.7, y: 0.7))

// Two prints, fanned.
photoCard(center: CGPoint(x: 440, y: 615), degrees: 11, sky: (0xBFE3FF, 0xEAF6FF), hills: (0x8FD18A, 0x5FB46B))
photoCard(center: CGPoint(x: 590, y: 590), degrees: -9, sky: (0xFFC7B5, 0xFFE8D6), hills: (0xF2A0A8, 0xE07C8E))

// The grain: plump, golden, smiling, with a sprout.
let grainCenter = CGPoint(x: 512, y: 378)
rotated(-8, around: grainCenter) {
    let body = NSRect(x: grainCenter.x - 150, y: grainCenter.y - 185, width: 300, height: 365)
    let grain = NSBezierPath(ovalIn: body)

    // Sprout first, so the grain sits in front of its stem. A white outline, like a sticker,
    // lifts it off the photo behind.
    let stem = NSBezierPath()
    stem.move(to: CGPoint(x: grainCenter.x, y: body.maxY - 18))
    stem.curve(to: CGPoint(x: grainCenter.x + 8, y: body.maxY + 70),
               controlPoint1: CGPoint(x: grainCenter.x - 14, y: body.maxY + 22),
               controlPoint2: CGPoint(x: grainCenter.x + 14, y: body.maxY + 44))
    stem.lineCapStyle = .round
    let leaves: [(CGPoint, CGFloat, UInt32)] = [
        (CGPoint(x: grainCenter.x + 8 - 58, y: body.maxY + 84), 28, 0x57C266),
        (CGPoint(x: grainCenter.x + 8 + 62, y: body.maxY + 84), -32, 0x6FD27A),
    ]
    func leaf(_ c: CGPoint) -> NSBezierPath { NSBezierPath(ovalIn: NSRect(x: c.x - 60, y: c.y - 25, width: 120, height: 50)) }
    withShadow(14, CGSize(width: 0, height: -6), 0.25) {
        color(0xFFFFFF).setStroke()
        stem.lineWidth = 34
        stem.stroke()
        for (c, deg, _) in leaves {
            rotated(deg, around: c) {
                let l = leaf(c)
                l.lineWidth = 18
                l.stroke()
                color(0xFFFFFF).setFill()
                l.fill()
            }
        }
    }
    stem.lineWidth = 16
    color(0x3E9E4F).setStroke()
    stem.stroke()
    for (c, deg, hex) in leaves {
        rotated(deg, around: c) {
            color(hex).setFill()
            leaf(c).fill()
        }
    }

    withShadow(26, CGSize(width: 0, height: -16), 0.30) {
        color(0xF2B04A).setFill()
        grain.fill()
    }
    NSGraphicsContext.saveGraphicsState()
    grain.addClip()
    NSGradient(colors: [color(0xFFE48C), color(0xF7BF52), color(0xE89A34)])!
        .draw(in: grain, relativeCenterPosition: NSPoint(x: -0.35, y: 0.4))
    // The grain's crease, drawn as a soft curve down one side.
    let crease = NSBezierPath()
    crease.move(to: CGPoint(x: body.midX + 92, y: body.maxY - 60))
    crease.curve(to: CGPoint(x: body.midX + 96, y: body.minY + 70),
                 controlPoint1: CGPoint(x: body.midX + 150, y: body.midY + 60),
                 controlPoint2: CGPoint(x: body.midX + 150, y: body.midY - 70))
    crease.lineWidth = 12
    crease.lineCapStyle = .round
    color(0xD98A2B, 0.55).setStroke()
    crease.stroke()
    // A highlight.
    color(0xFFFFFF, 0.45).setFill()
    rotated(-25, around: CGPoint(x: body.minX + 95, y: body.maxY - 110)) {
        NSBezierPath(ovalIn: NSRect(x: body.minX + 60, y: body.maxY - 150, width: 70, height: 110)).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    color(0xC9801F).setStroke()
    grain.lineWidth = 9
    grain.stroke()

    // Face.
    let eyeY = grainCenter.y + 30
    for x in [grainCenter.x - 62, grainCenter.x + 52] {
        color(0x3D2412).setFill()
        NSBezierPath(ovalIn: NSRect(x: x - 21, y: eyeY - 26, width: 42, height: 52)).fill()
        color(0xFFFFFF).setFill()
        NSBezierPath(ovalIn: NSRect(x: x - 8, y: eyeY + 4, width: 15, height: 15)).fill()
    }
    for x in [grainCenter.x - 108, grainCenter.x + 98] {
        color(0xFF7F96, 0.55).setFill()
        NSBezierPath(ovalIn: NSRect(x: x - 34, y: eyeY - 70, width: 68, height: 38)).fill()
    }
    let smile = NSBezierPath()
    smile.appendArc(withCenter: CGPoint(x: grainCenter.x - 5, y: eyeY - 40), radius: 38,
                    startAngle: 205, endAngle: 335)
    smile.lineWidth = 13
    smile.lineCapStyle = .round
    color(0x3D2412).setStroke()
    smile.stroke()
}

// A sparkle: this is the one you keep.
func sparkle(at c: CGPoint, _ r: CGFloat) {
    let p = NSBezierPath()
    p.move(to: CGPoint(x: c.x, y: c.y + r))
    p.curve(to: CGPoint(x: c.x + r, y: c.y), controlPoint1: CGPoint(x: c.x + r * 0.12, y: c.y + r * 0.12),
            controlPoint2: CGPoint(x: c.x + r * 0.12, y: c.y + r * 0.12))
    p.curve(to: CGPoint(x: c.x, y: c.y - r), controlPoint1: CGPoint(x: c.x + r * 0.12, y: c.y - r * 0.12),
            controlPoint2: CGPoint(x: c.x + r * 0.12, y: c.y - r * 0.12))
    p.curve(to: CGPoint(x: c.x - r, y: c.y), controlPoint1: CGPoint(x: c.x - r * 0.12, y: c.y - r * 0.12),
            controlPoint2: CGPoint(x: c.x - r * 0.12, y: c.y - r * 0.12))
    p.curve(to: CGPoint(x: c.x, y: c.y + r), controlPoint1: CGPoint(x: c.x - r * 0.12, y: c.y + r * 0.12),
            controlPoint2: CGPoint(x: c.x - r * 0.12, y: c.y + r * 0.12))
    color(0xFFFFFF).setFill()
    p.fill()
}
sparkle(at: CGPoint(x: 748, y: 352), 50)
sparkle(at: CGPoint(x: 806, y: 432), 24)
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

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Winnow.iconset")
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
iconutil.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("Winnow.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
print("Wrote \(master.path) and Resources/Winnow.icns")
