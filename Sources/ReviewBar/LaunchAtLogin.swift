import AppKit
import ServiceManagement
import os

/// "Open at Login", via `SMAppService.mainApp` — no helper target and no login
/// item to install: macOS registers the app bundle itself.
///
/// There is deliberately no stored copy of this setting. macOS owns it (System
/// Settings ▸ General ▸ Login Items can flip it behind our back, and a user who
/// disables it there puts the service into `.requiresApproval`), so the toggle
/// reads `status` every time rather than trusting a mirror in `UserDefaults`.
@MainActor
enum LaunchAtLogin {
    nonisolated private static let log =
        Logger(subsystem: "com.reviewbar.app", category: "launch-at-login")

    /// Registration identifies the app by its bundle, which `swift run` has
    /// none of — same constraint as notifications. Dev runs show the toggle
    /// disabled instead of failing at the click.
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    static var status: SMAppService.Status {
        isAvailable ? SMAppService.mainApp.status : .notFound
    }

    static var isEnabled: Bool { status == .enabled }

    /// True when the user switched the login item off in System Settings.
    /// Re-registering from here silently does nothing in that state, so the UI
    /// has to send them there instead.
    static var needsApproval: Bool { status == .requiresApproval }

    /// Returns false when macOS refused; the caller re-reads `isEnabled` either
    /// way, so a failed toggle snaps back rather than lying.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        guard isAvailable else { return false }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            log.error("Failed to \(enabled ? "register" : "unregister") login item: \(error)")
            return false
        }
    }

    /// System Settings ▸ General ▸ Login Items — where an approval-blocked
    /// login item has to be re-enabled by hand.
    static func openLoginItemsSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
