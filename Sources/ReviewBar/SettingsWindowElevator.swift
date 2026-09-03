import AppKit

/// Keeps the Settings window above the review panel.
///
/// The panel deliberately sits at `mainMenu + 1` so it can hug the notch, and
/// a level beats activation and ordering — so a normal Settings window opens
/// *underneath* the review even though it is the key window. Rather than
/// lowering the panel (which would drop it behind the menu bar and break the
/// notch illusion), the Settings window is lifted over it while it is key, and
/// dropped straight back to `.normal` when it isn't.
///
/// The lift is scoped to key-window status on purpose: a raised level applies
/// across apps, so a window left up there would float over everything the user
/// switched to. Clicking the panel makes it key, which resigns Settings and
/// lowers it — exactly the ordering you'd expect from the click.
@MainActor
final class SettingsWindowElevator {
    /// SwiftUI's `Settings` scene window. It owns its own lifetime; we only
    /// adjust its level.
    private weak var window: NSWindow?
    /// Read live rather than captured: the panel's level depends on the screen
    /// it opened on, and it may not be open at all.
    private let panelLevel: () -> NSWindow.Level?
    private var observers: [any NSObjectProtocol] = []

    init(window: NSWindow, panelLevel: @escaping () -> NSWindow.Level?) {
        self.window = window
        self.panelLevel = panelLevel
        observe(NSWindow.didBecomeKeyNotification) { [weak self] in self?.lift() }
        observe(NSWindow.didResignKeyNotification) { [weak self] in self?.drop() }
        lift()
    }

    /// Block-based observers outlive their owner unless removed by hand, so
    /// the elevator is retired explicitly rather than in `deinit` (which can't
    /// touch main-actor state).
    func invalidate() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        drop()
        window = nil
    }

    /// True while this still tracks the given window — SwiftUI reuses the
    /// Settings window, so the elevator is reused with it.
    func tracks(_ other: NSWindow) -> Bool { window === other }

    private func observe(_ name: Notification.Name, _ handler: @escaping @MainActor () -> Void) {
        let observer = NotificationCenter.default.addObserver(
            forName: name, object: window, queue: .main) { _ in
                MainActor.assumeIsolated(handler)
            }
        observers.append(observer)
    }

    private func lift() {
        guard let window else { return }
        // Nothing to clear when the review isn't on screen: staying at
        // `.normal` keeps Settings an ordinary window.
        guard let level = panelLevel() else {
            window.level = .normal
            return
        }
        window.level = NSWindow.Level(rawValue: level.rawValue + 1)
    }

    private func drop() {
        window?.level = .normal
    }
}

extension NSApplication {
    /// SwiftUI's `Settings` scene window, once it exists. The identifier is
    /// what SwiftUI stamps on it; the title match is a fallback in case that
    /// ever changes, and both exclude our own panels.
    var settingsWindow: NSWindow? {
        windows.first { window in
            guard !(window is NSPanel) else { return false }
            if window.identifier?.rawValue.contains("Settings") == true { return true }
            return window.title == "Settings" || window.title == "Preferences"
        }
    }
}
