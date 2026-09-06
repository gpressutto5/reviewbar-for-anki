import AppKit

/// The status item's glyph: the app icon's two stacked cards, drawn in code
/// as a template image so it takes the menu bar's foreground colour and
/// adapts to light/dark and wallpaper tint like a system item.
///
/// Drawn rather than shipped as an asset because the SwiftPM executable has
/// no resource bundle — `swift run` would show a blank label — and a 16 pt
/// monochrome shape is cheaper to draw than to keep in sync with the .icns.
@MainActor
enum MenuBarGlyph {
    /// Menu bar items are 22 pt tall (24 on notch Macs); 16 × 16 matches the
    /// footprint of Apple's own template icons beside it.
    static let size = NSSize(width: 16, height: 16)

    static let image: NSImage = {
        let image = NSImage(size: size, flipped: false) { rect in
            // Same construction as scripts/make-placeholder-icon.swift, scaled
            // from its 1024 grid: a tilted card behind, an upright one in front.
            let scale = rect.width / 1024
            func card(_ r: NSRect, rotation: CGFloat, alpha: CGFloat) {
                NSGraphicsContext.saveGraphicsState()
                let t = NSAffineTransform()
                t.translateX(by: r.midX, yBy: r.midY)
                t.rotate(byDegrees: rotation)
                t.translateX(by: -r.midX, yBy: -r.midY)
                t.concat()
                NSColor(white: 0, alpha: alpha).setFill()
                NSBezierPath(roundedRect: r, xRadius: 60 * scale, yRadius: 60 * scale).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            // Cards are drawn larger than in the app icon (which sits on a
            // plate) so the glyph fills the 16 pt box like other menu icons.
            card(NSRect(x: 130 * scale, y: 120 * scale, width: 780 * scale, height: 540 * scale),
                 rotation: -9, alpha: 0.45)
            card(NSRect(x: 130 * scale, y: 360 * scale, width: 780 * scale, height: 540 * scale),
                 rotation: 0, alpha: 1)
            // Cut the "text lines" out of the front card so they read as
            // lines in whatever colour the menu bar paints behind them.
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSColor.black.setFill()
            for (y, width) in [(CGFloat(690), CGFloat(460)), (CGFloat(530), CGFloat(300))] {
                NSBezierPath(roundedRect: NSRect(x: 250 * scale, y: y * scale,
                                                 width: width * scale, height: 70 * scale),
                             xRadius: 35 * scale, yRadius: 35 * scale).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }()
}
