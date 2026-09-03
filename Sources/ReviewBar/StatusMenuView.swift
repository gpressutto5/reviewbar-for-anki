import SwiftUI
import ReviewBarKit

/// Content of the menu bar dropdown: status line plus actions. The review
/// itself runs in the floating review window, not here.
struct StatusMenuView: View {
    let state: AppState

    var body: some View {
        Text(statusLine)

        if let reviewedTodaySummary = state.reviewedTodaySummary {
            Text(reviewedTodaySummary)
        }

        // Renders the scheduler's decision verbatim — also the quickest way to
        // see whether reminder logic is behaving.
        if let nudgeSummary = state.nudgeSummary {
            Text(nudgeSummary)
        }

        Button(state.session.phase == .idle ? "Review Now" : "Continue Review") {
            // MenuBarExtra doesn't expose its status item's frame, but the
            // mouse is on the menu right now — anchor the panel under it so
            // it drops from the icon (notched screens still use the notch).
            let click = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(click) }
            state.openReviewPanel(on: screen, anchorX: click.x)
            Task { await state.startReview() }
        }
        .disabled(!state.connection.isConnected)

        Button("Refresh") {
            Task { await state.refresh() }
        }

        if state.connection == .unreachable {
            Button("Open Anki") {
                Task { await state.relaunchAnki() }
            }
            .disabled(state.isLaunchingAnki)
        }

        // The pressure valve: pausing has to be cheaper than quitting the app,
        // so it lives here rather than only in preferences.
        Menu("Pause Reminders") {
            Button("For 10 minutes") { state.snoozeNudges(for: 600) }
            Button("For 30 minutes") { state.snoozeNudges(for: 1800) }
            Button("For 1 hour") { state.snoozeNudges(for: 3600) }
            Divider()
            Button("Until tomorrow") { state.snoozeNudgesUntilTomorrow() }
        }

        Divider()

        // Only shown when there is something to act on — a permanent "you're
        // up to date" line would be clutter in a menu opened for the due count.
        if let updateSummary = state.updateSummary {
            Button(updateSummary) {
                state.openLatestRelease()
            }
            Button("Skip This Version") {
                state.skipOfferedUpdate()
            }
            Divider()
        }

        Button("Settings…") {
            state.openSettingsWindow()
        }
        .keyboardShortcut(",")

        Button("Quit ReviewBar") {
            NSApplication.shared.terminate(nil)
        }
    }

    private var statusLine: String {
        if state.isLaunchingAnki { return "Starting Anki…" }
        return state.connection.isConnected ? state.dueSummary : state.connection.statusText
    }
}
