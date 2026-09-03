import AppKit
import CoreGraphics

/// Whether a nudge would actually be seen. A peek nobody is present for is
/// simply lost — and worse, it would burn the interval — so the scheduler holds
/// nudges while these say the user is away or can't see the notch.
enum SystemPresence {
    /// Seconds since the user last touched the machine.
    ///
    /// `CGEventType` is a Swift enum, so the C idiom of passing
    /// `kCGAnyInputEventType` (~0) as a raw value isn't expressible; taking the
    /// minimum over the input event types is equivalent and needs no
    /// force-unwrap.
    static var idleSeconds: TimeInterval {
        let inputEvents: [CGEventType] = [
            .keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown,
            .mouseMoved, .scrollWheel,
        ]
        return inputEvents
            .map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }
            .min() ?? 0
    }

    /// Whether the notch/menu bar is off screen, which is what promotes a
    /// nudge from a peek to a notification.
    ///
    /// Heuristic: a fullscreen app hides the menu bar, so the screen reserves
    /// no space for it. Also true under an auto-hiding menu bar — correctly so:
    /// a peek there would be just as unseeable.
    static var isNotchHidden: Bool {
        // Dev override: the notification rung is otherwise only reachable by
        // putting another app fullscreen, which makes it awkward to verify.
        //   REVIEWBAR_FORCE_NOTCH_HIDDEN=1 make run
        if let forced = ProcessInfo.processInfo.environment["REVIEWBAR_FORCE_NOTCH_HIDDEN"] {
            return forced == "1"
        }
        guard let screen = NSScreen.main else { return false }
        return screen.panelGeometry.menuBarHeight <= 0
    }
}
