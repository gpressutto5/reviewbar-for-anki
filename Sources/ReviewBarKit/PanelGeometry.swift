import CoreGraphics

/// Pure frame math for the floating review panel: where the window sits on a
/// given screen and, on notched MacBooks, where the notch is. Kept free of
/// AppKit so it can be unit-tested on any machine; the app layer feeds it
/// NSScreen measurements.
public struct PanelGeometry: Equatable, Sendable {
    /// Full screen frame (AppKit coordinates, bottom-left origin).
    public let screenFrame: CGRect
    /// Frame minus menu bar and Dock.
    public let visibleFrame: CGRect
    /// Notch rect hugging the screen's top edge, nil on notchless displays.
    public let notch: CGRect?

    /// Gap between the panel's top edge and the menu bar on notchless displays.
    public static let floatingTopMargin: CGFloat = 8
    /// Notch width to assume when the screen reports a camera housing height
    /// but no auxiliary top areas (14"/16" notches measure ≈180–200pt).
    public static let fallbackNotchWidth: CGFloat = 200

    public init(screenFrame: CGRect, visibleFrame: CGRect, notch: CGRect?) {
        self.screenFrame = screenFrame
        self.visibleFrame = visibleFrame
        self.notch = notch
    }

    public var hasNotch: Bool { notch != nil }

    /// Menu bar thickness on this screen (0 when the menu bar auto-hides).
    public var menuBarHeight: CGFloat { max(0, screenFrame.maxY - visibleFrame.maxY) }

    /// Where a synthetic notch sits on notchless screens: top-center,
    /// menu-bar tall, notch-wide. Anchors the hover hotspot and notch-style
    /// panel openings on external displays.
    public var virtualNotch: CGRect {
        let height = menuBarHeight > 0 ? menuBarHeight : 24
        return CGRect(x: screenFrame.midX - Self.fallbackNotchWidth / 2,
                      y: screenFrame.maxY - height,
                      width: Self.fallbackNotchWidth, height: height)
    }

    /// This geometry with the virtual notch standing in for a real one, so
    /// the whole notch-mode pipeline (flush-top frame, notch-sized collapse)
    /// works unchanged on notchless screens. No-op when a real notch exists.
    public var adoptingVirtualNotch: PanelGeometry {
        hasNotch ? self : PanelGeometry(screenFrame: screenFrame,
                                        visibleFrame: visibleFrame,
                                        notch: virtualNotch)
    }

    /// The notch as reported by a screen: `safeAreaTop` is
    /// `NSScreen.safeAreaInsets.top`, the auxiliary areas are the usable menu
    /// bar strips on either side of the camera housing.
    public static func notchRect(screenFrame: CGRect,
                                 safeAreaTop: CGFloat,
                                 auxiliaryTopLeftArea: CGRect?,
                                 auxiliaryTopRightArea: CGRect?) -> CGRect? {
        guard safeAreaTop > 0 else { return nil }
        let width: CGFloat
        let minX: CGFloat
        if let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea,
           right.minX > left.maxX {
            width = right.minX - left.maxX
            minX = left.maxX
        } else {
            width = fallbackNotchWidth
            minX = screenFrame.midX - width / 2
        }
        return CGRect(x: minX, y: screenFrame.maxY - safeAreaTop,
                      width: width, height: safeAreaTop)
    }

    /// Window frame for a panel of `size`, top-anchored: flush with the
    /// screen's top edge and centered on the notch when there is one,
    /// otherwise just below the menu bar. On notchless screens an `anchorX`
    /// (e.g. the menu bar icon's position) centers the panel there instead of
    /// mid-screen, clamped so the visible content — `contentWidth` points
    /// centered inside `size`, for windows padded out with shadow margins —
    /// stays on screen. The notch always wins over the anchor: the panel
    /// must stay attached to the housing.
    public func windowFrame(size: CGSize,
                            anchorX: CGFloat? = nil,
                            contentWidth: CGFloat? = nil) -> CGRect {
        let centerX: CGFloat
        let topY: CGFloat
        if let notch {
            centerX = notch.midX
            topY = screenFrame.maxY
        } else {
            let content = contentWidth ?? size.width
            let minCenter = visibleFrame.minX + content / 2 + Self.floatingTopMargin
            let maxCenter = visibleFrame.maxX - content / 2 - Self.floatingTopMargin
            centerX = min(max(anchorX ?? visibleFrame.midX, minCenter),
                          max(minCenter, maxCenter))
            topY = visibleFrame.maxY - Self.floatingTopMargin
        }
        return CGRect(x: centerX - size.width / 2, y: topY - size.height,
                      width: size.width, height: size.height)
    }
}
