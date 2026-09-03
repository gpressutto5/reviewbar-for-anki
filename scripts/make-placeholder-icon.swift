#!/usr/bin/env swift
//
// Generates Resources/AppIcon.icns — a placeholder app icon.
//
//   swift scripts/make-placeholder-icon.swift
//
// This exists so the icon is reproducible rather than an opaque committed
// binary. To ship a real icon, either drop a replacement at
// Resources/AppIcon.icns (any .icns works — nothing else needs to change) or
// edit the drawing below and re-run.
//
// Everything is drawn in a 1024×1024 coordinate space and scaled per size, so
// the artwork stays sharp from 16pt up.

import AppKit

let side: CGFloat = 1024

/// macOS icon grid: the rounded square occupies 824×824 centred in 1024, which
/// is what keeps it visually the same size as system icons beside it.
let plateInset: CGFloat = 100
let plateRadius: CGFloat = 185.4

func drawIcon() {
    let plate = NSRect(x: plateInset, y: plateInset,
                       width: side - plateInset * 2,
                       height: side - plateInset * 2)
    let platePath = NSBezierPath(roundedRect: plate,
                                 xRadius: plateRadius, yRadius: plateRadius)

    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.36, green: 0.32, blue: 0.89, alpha: 1),
        NSColor(srgbRed: 0.55, green: 0.28, blue: 0.85, alpha: 1),
    ])!
    gradient.draw(in: platePath, angle: -90)

    // Two stacked cards: a tilted one behind, a square one in front. Reads as
    // "flashcards" at Finder sizes and as a light shape in the menu bar.
    func card(_ rect: NSRect, rotation: CGFloat, alpha: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: rect.midX, yBy: rect.midY)
        transform.rotate(byDegrees: rotation)
        transform.translateX(by: -rect.midX, yBy: -rect.midY)
        transform.concat()

        let path = NSBezierPath(roundedRect: rect, xRadius: 44, yRadius: 44)
        NSColor(white: 1, alpha: alpha).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    card(NSRect(x: 300, y: 330, width: 424, height: 300), rotation: -9, alpha: 0.45)
    card(NSRect(x: 300, y: 390, width: 424, height: 300), rotation: 0, alpha: 1.0)

    // Two text lines on the front card, hinting at a question side.
    NSColor(srgbRed: 0.36, green: 0.32, blue: 0.89, alpha: 0.55).setFill()
    for (y, width) in [(CGFloat(575), CGFloat(250)), (CGFloat(495), CGFloat(170))] {
        NSBezierPath(roundedRect: NSRect(x: 360, y: y, width: width, height: 34),
                     xRadius: 17, yRadius: 17).fill()
    }
}

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(size) / side
    let transform = NSAffineTransform()
    transform.scaleX(by: scale, yBy: scale)
    transform.concat()
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()

    return rep.representation(using: .png, properties: [:])!
}

// iconutil expects exactly these names inside a .iconset directory.
let variants: [(name: String, size: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

let iconset = URL(fileURLWithPath: "Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for variant in variants {
    let url = iconset.appendingPathComponent("\(variant.name).png")
    try render(size: variant.size).write(to: url)
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}

try FileManager.default.removeItem(at: iconset)
print("Wrote Resources/AppIcon.icns")
