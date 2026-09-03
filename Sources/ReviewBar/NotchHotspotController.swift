import AppKit
import SwiftUI
import ReviewBarKit

/// NotchNook-style notch interaction, on every screen. On the built-in
/// display an invisible window sits over the camera housing: idle, its black
/// shape exactly overlays the notch (so it renders as nothing); hovering
/// makes it peek out with the due count, and a click toggles the review
/// panel. Notchless externals get a virtual notch: the same hotspot at the
/// menu bar's top-center, fully invisible until hovered, when the black pill
/// fades and grows in.
@MainActor
final class NotchHotspotController {
    /// How far the shape grows below the menu bar on hover.
    static let peek: CGFloat = 6

    private let onTap: (NSScreen) -> Void
    /// For the due-count badge in the hover peek. Unowned: AppState owns
    /// this controller and outlives it.
    private unowned let state: AppState
    private var panels: [NSPanel] = []
    private var observer: (any NSObjectProtocol)?

    init(state: AppState, onTap: @escaping (NSScreen) -> Void) {
        self.state = state
        self.onTap = onTap
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        update()
    }

    /// Rebuild one hotspot per screen; screens change rarely enough that
    /// recreating them all is simpler than diffing.
    private func update() {
        for panel in panels { panel.orderOut(nil) }
        panels.removeAll()

        for screen in NSScreen.screens {
            let geometry = screen.panelGeometry
            let notch = geometry.notch ?? geometry.virtualNotch

            // Room for the hover peek to widen and carry the due-count badge.
            let margin = PanelTheme.earRadius + NotchHotspotView.badgeRoom + 12
            let frame = CGRect(x: notch.minX - margin,
                               y: notch.minY - Self.peek,
                               width: notch.width + margin * 2,
                               height: notch.height + Self.peek)
            let panel = makePanel()
            panel.setFrame(frame, display: true)
            panel.contentView = NSHostingView(rootView: NotchHotspotView(
                notchSize: notch.size,
                isVirtual: !geometry.hasNotch,
                state: state,
                action: { [onTap] in onTap(screen) }))
            panel.orderFrontRegardless()
            panels.append(panel)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Same level as the review panel; the review panel is ordered front
        // when shown, so it stacks above the hotspot.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        return panel
    }
}

struct NotchHotspotView: View {
    /// Horizontal room the peek gains on the right on hover — enough for the
    /// due-count badge to sit beside the housing, Dynamic-Island style.
    static let badgeRoom: CGFloat = 46

    let notchSize: CGSize
    /// True on notchless screens: the pill is invisible until hovered.
    let isVirtual: Bool
    let state: AppState
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        // The pill pokes out either because the pointer is over it or because
        // a reminder nudge asked it to (the quietest rung of the ladder) —
        // visually identical, so the nudge reads as "the notch noticed you".
        let peeked = hovering || state.isPeeking
        // Asymmetric peek: the left grows as subtly as the height, the right
        // grows enough to seat the badge. The offset re-centers so the left
        // edge moves only by its own small growth.
        let grow = peeked ? NotchHotspotController.peek : 0
        let rightGrow = peeked ? Self.badgeRoom : 0
        // The virtual pill grows organically out of the screen edge from
        // height zero; the real notch's shape is always at full height
        // (it hides against the housing instead).
        let pillHeight = isVirtual && !peeked ? 0 : notchSize.height + grow

        ZStack(alignment: .top) {
            // A fully transparent window region passes mouse events to
            // whatever is beneath, and a zero-height pill is unhittable —
            // so the virtual hotspot keeps a whisker-of-alpha capture strip
            // over the menu bar band: invisible to the eye, still hoverable.
            if isVirtual {
                Rectangle()
                    .fill(Color.black.opacity(0.001))
                    .frame(width: notchSize.width + PanelTheme.earRadius * 2,
                           height: notchSize.height)
            }
            PanelShape(mode: .notch(size: notchSize))
                .fill(Color.black)
                // Overlay sits inside the frame/offset chain so the badge
                // moves and grows with the shape.
                .overlay(alignment: .topTrailing) {
                    if peeked, let badge {
                        Text(badge)
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.85))
                            .monospacedDigit()
                            // Vertically centered in the menu-bar band, clear
                            // of the ear curve on the right.
                            .frame(height: notchSize.height)
                            .padding(.trailing, PanelTheme.earRadius + 10)
                            .transition(.opacity)
                    }
                }
                .frame(width: notchSize.width + PanelTheme.earRadius * 2
                            + grow + rightGrow,
                       height: pillHeight)
                .offset(x: (rightGrow - grow) / 2)
        }
        .contentShape(Rectangle())
        .onHover { isInside in
            hovering = isInside
            // Hovering the notch is the acknowledgement signal: the user saw
            // the nudge. Choosing not to review is a legitimate answer, so
            // this is what stops the escalation to a notification.
            if isInside { state.acknowledgeNudge() }
        }
        .onTapGesture(perform: action)
        // Bounce on the way out, settle dead on the way back — an
        // underdamped collapse would overshoot below zero height.
        .animation(peeked ? PanelTheme.spring : PanelTheme.closeSpring,
                   value: peeked)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Remaining reviews; a checkmark when caught up, nothing when the due
    /// count is unknown (Anki unreachable).
    private var badge: String? {
        guard let dueCount = state.dueCount else { return nil }
        return dueCount > 0 ? "\(dueCount)" : "✓"
    }
}
