#!/usr/bin/swift
// Generates assets/AppIcon.icns: an indigo squircle (Aegis palette) with a
// white shield holding three code dots. Run: swift scripts/make-icon.swift
// Requires only AppKit + iconutil; regenerating is deterministic.
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("assets/AppIcon.iconset")
let icns = root.appendingPathComponent("assets/AppIcon.icns")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let u = CGFloat(px) / 1024
    func P(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * u, y: y * u) }

    // Rounded-square background, Aegis indigo gradient (#2b5bb5 family)
    let bg = NSBezierPath(
        roundedRect: NSRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u),
        xRadius: 185 * u, yRadius: 185 * u)
    NSGradient(
        starting: NSColor(calibratedRed: 0.36, green: 0.52, blue: 0.85, alpha: 1),
        ending: NSColor(calibratedRed: 0.12, green: 0.28, blue: 0.60, alpha: 1))!
        .draw(in: bg, angle: -90)

    // Shield: flat top, straight upper sides, curving to a bottom point
    let shield = NSBezierPath()
    shield.move(to: P(512, 268))
    shield.curve(to: P(316, 520), controlPoint1: P(420, 320), controlPoint2: P(316, 410))
    shield.line(to: P(316, 700))
    shield.line(to: P(708, 700))
    shield.line(to: P(708, 520))
    shield.curve(to: P(512, 268), controlPoint1: P(708, 410), controlPoint2: P(604, 320))
    shield.close()
    NSColor.white.setFill()
    shield.fill()

    // Three OTP-code dots
    NSColor(calibratedRed: 0.169, green: 0.357, blue: 0.710, alpha: 1).setFill()
    for x in [402, 512, 622] {
        NSBezierPath(ovalIn: NSRect(
            x: CGFloat(x - 34) * u, y: (520 - 34) * u, width: 68 * u, height: 68 * u)).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { fatalError("iconutil failed") }
try? FileManager.default.removeItem(at: iconset)
print("Wrote \(icns.path)")
