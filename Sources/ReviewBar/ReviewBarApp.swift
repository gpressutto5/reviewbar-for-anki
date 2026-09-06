import AppKit
import SwiftUI

@main
struct ReviewBarApp: App {
    @State private var appState = AppState()

    init() {
        // Menu-bar-only app. When built as a bundle this comes from
        // LSUIElement; when run via `swift run` we set it here.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        // Plain dropdown menu; the review itself lives in the floating window.
        MenuBarExtra {
            StatusMenuView(state: appState)
        } label: {
            MenuBarLabel(state: appState)
        }

        // The floating review panel is not a SwiftUI scene: it needs to hug
        // the notch and sit above the menu bar, so AppState owns an
        // AppKit-managed ReviewPanelController instead.

        Settings {
            SettingsView(state: appState)
        }
    }
}

/// The menu bar label is the app's always-alive SwiftUI outpost: it owns the
/// app's single clock, and it hands AppState the `openSettings` environment
/// action — the AppKit-owned review panel can't reach the environment, and
/// the `showSettingsWindow:` responder-chain selector is a no-op here.
private struct MenuBarLabel: View {
    let state: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // Icon + count, the way system items show status. Both stay a
        // template image: MenuBarExtra flattens the label to the menu bar's
        // foreground colour, so tinting or a pill background would be lost.
        Label {
            Text(state.menuBarTitle).monospacedDigit()
        } icon: {
            Image(nsImage: MenuBarGlyph.image)
        }
        .labelStyle(.titleAndIcon)
        .task {
                // The label view lives as long as the app, so the app's
                // single clock hangs off it. Each tick re-plans reminders
                // and refreshes from Anki only when due — the sleep
                // duration is never trusted (see AppState.tick).
                state.openSettingsAction = { openSettings() }
                state.start()
                // Dev hook: settings live behind two clicks in the menu bar,
                // which makes layout work unobservable from a script.
                if ProcessInfo.processInfo.environment["REVIEWBAR_OPEN_SETTINGS"] == "1" {
                    state.openSettingsWindow()
                }
                while !Task.isCancelled {
                    await state.tick()
                    try? await Task.sleep(for: AppState.tickInterval)
                }
            }
    }
}
