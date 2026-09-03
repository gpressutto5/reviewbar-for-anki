import AppKit
import UserNotifications
import os

/// The notification rung of the nudge ladder.
///
/// Authorization is requested the first time a notification is actually needed,
/// never at launch, and never again once denied (PRD: don't repeatedly ask).
/// Notifications go out at default interruption level so macOS Do Not Disturb
/// and Focus handle suppression — there's no public API to read those, and
/// second-guessing them is how an app earns a mute.
@MainActor
final class NudgeNotifier: NSObject, UNUserNotificationCenterDelegate {
    /// `UNUserNotificationCenter.current()` traps in a process with no app
    /// bundle, which is exactly how `swift run` launches us. Dev builds
    /// therefore have no notifications; the peek rung still works.
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    nonisolated private static let log =
        Logger(subsystem: "com.reviewbar.app", category: "notifications")

    private let onOpenRequested: () -> Void
    /// Nil until asked; false means denied — don't ask again.
    private var isAuthorized: Bool?

    init(onOpenRequested: @escaping () -> Void) {
        self.onOpenRequested = onOpenRequested
        super.init()
        if Self.isAvailable {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    func post(body: String) async {
        guard Self.isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        if isAuthorized == nil {
            do {
                isAuthorized = try await center.requestAuthorization(options: [.alert, .badge])
            } catch {
                // Left nil so a later nudge retries. Logged because this failure
                // is otherwise invisible and disables the whole rung: code 1,
                // "Notifications are not allowed", means Launch Services doesn't
                // know this bundle — e.g. it's running from a build directory
                // rather than an installed .app (see `make install-dev`).
                Self.log.error("authorization failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        guard isAuthorized == true else { return }

        let content = UNMutableNotificationContent()
        content.title = "Anki reviews waiting"
        content.body = body
        do {
            try await center.add(UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil))
        } catch {
            Self.log.error("post failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Tapping the notification opens the review — the whole point of it.
    /// Delivered on the main thread by UserNotifications.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        MainActor.assumeIsolated { onOpenRequested() }
        completionHandler()
    }
}
