import SwiftUI
import ReviewBarKit

/// How the panel is presented: growing out of the camera-housing notch on a
/// built-in display, or free-floating elsewhere.
enum PanelMode: Equatable {
    /// `isVirtual`: a synthesized notch on an external display — there is no
    /// housing to hide against, so collapse continues to zero height instead
    /// of stopping at notch size.
    case notch(size: CGSize, isVirtual: Bool = false)
    case floating
}

/// Design tokens for the NotchNook-style review panel: a solid black slab
/// with dark-gray rounded tiles for controls — no translucency, no borders.
/// One place to touch when user-configurable appearance settings land.
enum PanelTheme {
    static let width: CGFloat = 420
    /// Big, soft bottom corners like NotchNook's tray.
    static let bottomCornerRadius: CGFloat = 32
    /// Radius of the concave "ears" where the panel flares into the top of
    /// the screen (notch mode only).
    static let earRadius: CGFloat = 14
    static let padding: CGFloat = 20
    /// Show Answer and rating rows share this height so the card starts at
    /// the same y on both sides.
    static let controlsHeight: CGFloat = 44
    /// Corner radius of the control tiles and card inset.
    static let tileRadius: CGFloat = 14

    /// Dark-gray tile on black, NotchNook-style.
    static let tile = Color.white.opacity(0.12)
    static let cardSurface = Color.white.opacity(0.07)
    /// Under a light card theme the card gets a paper-white surface; Anki's
    /// own light reviewer background, and what default black text needs.
    static let lightCardSurface = Color.white
    static let secondaryText = Color.white.opacity(0.65)
    static let tertiaryText = Color.white.opacity(0.45)

    /// The spring for the panel's silhouette: slightly underdamped so
    /// expansion overshoots a touch, like the Dynamic Island.
    static let spring = Animation.spring(response: 0.5, dampingFraction: 0.72)
    /// Collapse is critically damped: any overshoot at notch size reads as a
    /// sideways wobble against the housing, so it settles without bouncing.
    static let closeSpring = Animation.spring(response: 0.4, dampingFraction: 1.0)
    /// Content arrives a beat after the shape starts stretching…
    static let contentIn = Animation.spring(response: 0.4, dampingFraction: 0.85)
        .delay(0.1)
    /// …and vanishes quickly on collapse so the shape shrinks around nothing.
    static let contentOut = Animation.easeOut(duration: 0.14)
    /// How long `spring` takes to visually settle; the window is hidden after
    /// the collapse animation has run its course.
    static let settleDelay: Duration = .milliseconds(600)
}

/// The panel silhouette. Floating: a plain big-radius rounded rect. Notch:
/// the Dynamic-Island shape — flush square top spanning the full rect, sides
/// inset by `earRadius` with concave curves flaring back out to the top
/// corners, convex bottom corners. Radii clamp to the rect height, so the
/// same shape collapsed to notch size morphs into the notch's own outline.
struct PanelShape: Shape {
    let mode: PanelMode

    func path(in rect: CGRect) -> Path {
        switch mode {
        case .floating:
            let radius = min(PanelTheme.bottomCornerRadius, rect.height / 2)
            return RoundedRectangle(cornerRadius: radius, style: .continuous)
                .path(in: rect)
        case .notch:
            let ear = min(PanelTheme.earRadius, rect.height / 3)
            // Stay generously rounded at small heights — the virtual pill is
            // visible while it grows, and a height/3 clamp reads as square —
            // while never letting the bottom curve overlap the ear curve.
            let bottom = min(PanelTheme.bottomCornerRadius,
                             rect.height / 1.8,
                             rect.height - ear)
            var p = Path()
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addQuadCurve(
                to: CGPoint(x: rect.minX + ear, y: rect.minY + ear),
                control: CGPoint(x: rect.minX + ear, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.minX + ear, y: rect.maxY - bottom))
            p.addQuadCurve(
                to: CGPoint(x: rect.minX + ear + bottom, y: rect.maxY),
                control: CGPoint(x: rect.minX + ear, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX - ear - bottom, y: rect.maxY))
            p.addQuadCurve(
                to: CGPoint(x: rect.maxX - ear, y: rect.maxY - bottom),
                control: CGPoint(x: rect.maxX - ear, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX - ear, y: rect.minY + ear))
            p.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: rect.minY),
                control: CGPoint(x: rect.maxX - ear, y: rect.minY))
            p.closeSubpath()
            return p
        }
    }
}

/// Solid black, like the notch itself. Depth comes from the drop shadow and
/// the gray tiles inside, never from borders or blur.
struct PanelBackground: View {
    let mode: PanelMode

    var body: some View {
        PanelShape(mode: mode)
            .fill(Color.black)
            .shadow(color: .black.opacity(0.55), radius: 20, y: 8)
    }
}

/// Dark-gray rounded tile for actions, NotchNook-style. A tint colors the
/// label only; the tile itself stays gray.
struct TileButtonStyle: ButtonStyle {
    var tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        TileBody(configuration: configuration, tint: tint)
    }

    private struct TileBody: View {
        let configuration: Configuration
        let tint: Color?
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.callout.weight(.bold))
                .foregroundStyle(tint.map { $0.mix(with: .white, by: 0.5) } ?? .white)
                .frame(maxWidth: .infinity)
                .frame(minHeight: PanelTheme.controlsHeight)
                .background(
                    RoundedRectangle(cornerRadius: PanelTheme.tileRadius,
                                     style: .continuous)
                        .fill(.white.opacity(fillOpacity)))
                .contentShape(RoundedRectangle(cornerRadius: PanelTheme.tileRadius,
                                               style: .continuous))
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }

        private var fillOpacity: Double {
            if configuration.isPressed { return 0.24 }
            if hovering { return 0.17 }
            return 0.12
        }
    }
}

/// Circular ✕ that replaces the old "Stop" text button.
struct CloseButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(hovering ? 0.95 : 0.75))
                .frame(width: 24, height: 24)
                .background(Circle().fill(.white.opacity(hovering ? 0.2 : 0.12)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityLabel("Close review")
    }
}

extension Ease {
    var tint: Color {
        switch self {
        case .again: .red
        case .hard: .orange
        case .good: .green
        case .easy: .blue
        }
    }
}
