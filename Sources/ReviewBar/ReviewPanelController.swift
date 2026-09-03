import AppKit
import SwiftUI
import ReviewBarKit

/// Drives the panel's open/close animation from outside the view tree.
@MainActor
@Observable
final class PanelAnimator {
    var mode: PanelMode = .floating
    var expanded = false
}

/// Owns the borderless NSPanel that hosts the review UI. A SwiftUI `Window`
/// scene can't sit above the menu bar or hug the notch, so window management
/// lives here. This is also the single seam where the deferred features hook
/// in later: a global hotkey calls `show`, a dimming overlay would be a
/// sibling window owned here, and placement options are one more branch in
/// the frame math.
@MainActor
final class ReviewPanelController {
    private var panel: NSPanel?
    private let animator = PanelAnimator()
    /// Unmodified key presses reach the card's WKWebView first (it is the
    /// panel's first responder, and plain keys aren't key equivalents), so the
    /// reviewer shortcuts are claimed ahead of the responder chain. Live only
    /// while the panel is on screen.
    private var keyMonitor: Any?
    /// Invalidates a pending post-collapse orderOut when the panel is
    /// re-opened mid-animation.
    private var generation = 0

    /// Extra window size around the content so the SwiftUI-drawn shadow has
    /// room to render (the NSWindow shadow is disabled; it can't track the
    /// animating shape).
    private static let shadowMargin: CGFloat = 60

    var isVisible: Bool { panel?.isVisible ?? false }

    /// The level the panel is sitting at while it's on screen — what anything
    /// that has to appear over the review (the Settings window) must clear.
    /// Nil when the panel is hidden and nothing needs lifting.
    var visibleWindowLevel: NSWindow.Level? {
        guard let panel, panel.isVisible else { return nil }
        return panel.level
    }

    /// `notchStyle` makes notchless screens behave like notched ones — the
    /// panel grows flush out of a virtual notch at the top-center — used
    /// when opening from a notch hotspot. Screens with a real notch always
    /// use it regardless.
    func show(state: AppState, on preferredScreen: NSScreen? = nil,
              anchorX: CGFloat? = nil, notchStyle: Bool = false) {
        generation += 1
        let screen = preferredScreen ?? NSScreen.main ?? NSScreen.screens.first
        var geometry = screen?.panelGeometry
            ?? PanelGeometry(screenFrame: .zero, visibleFrame: .zero, notch: nil)
        if notchStyle { geometry = geometry.adoptingVirtualNotch }

        animator.mode = geometry.notch.map {
            .notch(size: $0.size, isVirtual: !(screen?.panelGeometry.hasNotch ?? false))
        } ?? .floating

        let panel = panel ?? makePanel(state: state)
        installKeyMonitor()
        // Window is a fixed, oversized transparent stage: all motion happens
        // in SwiftUI inside it, top-anchored. Fully transparent pixels pass
        // clicks through to whatever is underneath.
        let maxContentHeight = max(geometry.visibleFrame.height - 40, 400)
        let windowSize = CGSize(width: PanelTheme.width + Self.shadowMargin * 2,
                                height: maxContentHeight + Self.shadowMargin)
        panel.setFrame(
            geometry.windowFrame(size: windowSize, anchorX: anchorX,
                                 contentWidth: PanelTheme.width),
            display: false)
        panel.level = geometry.hasNotch
            ? NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
            : .floating
        panel.isMovableByWindowBackground = !geometry.hasNotch

        let alreadyOpen = panel.isVisible && animator.expanded
        if !alreadyOpen { animator.expanded = false }
        panel.makeKeyAndOrderFront(nil)
        if !alreadyOpen {
            // Let the collapsed state render once so the expansion animates.
            Task { @MainActor [animator] in
                try? await Task.sleep(for: .milliseconds(30))
                withAnimation(PanelTheme.spring) { animator.expanded = true }
            }
        }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        removeKeyMonitor()
        generation += 1
        let expected = generation
        withAnimation(PanelTheme.closeSpring) { animator.expanded = false }
        Task { @MainActor in
            try? await Task.sleep(for: PanelTheme.settleDelay)
            guard expected == self.generation else { return }
            panel.orderOut(nil)
        }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel as? ReviewPanel,
                  event.window === panel else { return event }
            // Modified presses stay with the responder chain: ⌘, opens
            // Settings, ⌘C copies out of the card, and so on.
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.capsLock, .shift, .numericPad])
            guard flags.isEmpty,
                  let characters = event.charactersIgnoringModifiers else { return event }
            return panel.handleReviewKey?(characters) == true ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func makePanel(state: AppState) -> NSPanel {
        let panel = ReviewPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.openSettings = { [weak state] in state?.openSettingsWindow() }
        panel.handleReviewKey = { [weak state] key in
            state?.handleReviewKey(key) ?? false
        }
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)

        let hosting = NSHostingView(
            rootView: PanelContainerView(state: state, animator: animator))
        hosting.sizingOptions = []
        panel.contentView = hosting
        self.panel = panel
        return panel
    }
}

/// Borderless panels refuse key status by default; the review UI needs it for
/// the Return/Escape shortcuts.
private final class ReviewPanel: NSPanel {
    var openSettings: (() -> Void)?
    /// Unmodified review keys (space/Return, the rating keys). Consulted
    /// before the responder chain — see `keyMonitor` in the controller.
    var handleReviewKey: ((String) -> Bool)?

    override var canBecomeKey: Bool { true }

    /// ⌘, opens Settings while reviewing. The status menu's own ⌘, item only
    /// fires while that menu is open, so the key panel has to handle it.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock)
        if flags == .command, event.charactersIgnoringModifiers == "," {
            openSettings?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Wraps `ReviewPanelView` in the dynamic-island choreography: in notch mode
/// the glass springs from the notch's own footprint to the full panel and
/// back; in floating mode it scales and fades in place. The hosting window
/// never animates — only this view does.
private struct PanelContainerView: View {
    let state: AppState
    let animator: PanelAnimator

    @State private var panelSize = CGSize(width: PanelTheme.width, height: 240)

    var body: some View {
        let expanded = animator.expanded

        ReviewPanelView(state: state)
            // In notch mode the content clears the notch band vertically and
            // the ear inset horizontally, so nothing crowds the housing.
            .padding(.top, contentInsets.top)
            .padding(.horizontal, contentInsets.side)
            .frame(width: PanelTheme.width)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { panelSize = $0 }
            // Content trails the shape on the way in, bails out fast on the
            // way out — the slab reads as stretching open, not fading.
            .opacity(expanded ? 1 : 0)
            .blur(radius: expanded ? 0 : 12)
            .scaleEffect(expanded ? 1 : 0.94, anchor: .top)
            .animation(expanded ? PanelTheme.contentIn : PanelTheme.contentOut,
                       value: expanded)
            .frame(width: stageSize.width, height: stageSize.height, alignment: .top)
            .clipShape(PanelShape(mode: animator.mode))
            .background(PanelBackground(mode: animator.mode))
            .animation(expanded ? PanelTheme.spring : PanelTheme.closeSpring,
                       value: expanded)
            .animation(PanelTheme.spring, value: panelSize)
            .overlay(alignment: .top) { notchCloseTarget }
            .preferredColorScheme(.dark)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// In notch mode the open panel covers the notch hotspot window, so its
    /// toggle-to-close click never arrives there. This restores the gesture:
    /// the panel's own notch band folds the review away when clicked.
    @ViewBuilder private var notchCloseTarget: some View {
        if case .notch(let notchSize, _) = animator.mode, animator.expanded {
            Color.clear
                .frame(width: notchSize.width + PanelTheme.earRadius * 2,
                       height: notchSize.height)
                .contentShape(Rectangle())
                .onTapGesture { state.dismissReview() }
        }
    }

    /// Collapsed, the stage is what the panel grows out of and shrinks back
    /// into: the notch itself (plus the ear flare, so the shape's straight
    /// sides line up with the housing), or a point at top-center on
    /// notchless screens. Expanded, it is the content's natural size — so
    /// open/close is pure frame morphing, never a fade.
    private var contentInsets: (top: CGFloat, side: CGFloat) {
        switch animator.mode {
        case .notch(let notchSize, _): (notchSize.height, PanelTheme.earRadius)
        case .floating: (0, 0)
        }
    }

    private var stageSize: CGSize {
        if animator.expanded { return panelSize }
        switch animator.mode {
        case .notch(let notchSize, let isVirtual):
            // A virtual notch has no housing to vanish behind: keep
            // shrinking all the way out of the screen edge.
            return CGSize(width: notchSize.width + PanelTheme.earRadius * 2,
                          height: isVirtual ? 0 : notchSize.height)
        case .floating:
            return .zero
        }
    }
}

extension NSScreen {
    /// Measurements `PanelGeometry` needs, in this screen's coordinates.
    var panelGeometry: PanelGeometry {
        PanelGeometry(
            screenFrame: frame,
            visibleFrame: visibleFrame,
            notch: PanelGeometry.notchRect(
                screenFrame: frame,
                safeAreaTop: safeAreaInsets.top,
                auxiliaryTopLeftArea: auxiliaryTopLeftArea,
                auxiliaryTopRightArea: auxiliaryTopRightArea))
    }
}
