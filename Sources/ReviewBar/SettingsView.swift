import SwiftUI
import ReviewBarKit

/// The preferences window (SwiftUI `Settings` scene): a form over
/// `ReminderSettings` plus deck scope and the AnkiConnect endpoint. Everything
/// edits `AppState` directly — its `didSet`s persist and re-plan, so there is
/// no Apply button and no second copy of the settings to drift.
///
/// Classic two-column settings layout (a `Grid` with a trailing label column),
/// not grouped-form cards: each tab has to fit without scrolling.
struct SettingsView: View {
    let state: AppState

    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            RemindersSettingsTab(state: state)
                .tabItem { Label("Reminders", systemImage: "bell") }
            ReviewSettingsTab(state: state)
                .tabItem { Label("Review", systemImage: "rectangle.stack") }
            ShortcutsSettingsTab(state: state)
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .frame(width: 520)
    }
}

private struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - General

/// App-level behaviour. `LaunchAtLogin` reads macOS for the current state
/// rather than keeping a copy, so this tab holds no settings of its own — it
/// re-reads on appear, because System Settings can flip the login item while
/// the app is running.
private struct GeneralSettingsTab: View {
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var needsApproval = LaunchAtLogin.needsApproval

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline,
             horizontalSpacing: 10, verticalSpacing: 12) {
            GridRow {
                Text("Startup:")
                    .gridColumnAlignment(.trailing)
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Open ReviewBar at login", isOn: launchBinding)
                        .disabled(!LaunchAtLogin.isAvailable)
                    if needsApproval {
                        HStack(spacing: 6) {
                            Label("Blocked in System Settings", systemImage:
                                    "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Button("Open Login Items") {
                                LaunchAtLogin.openLoginItemsSettings()
                            }
                            .controlSize(.small)
                        }
                    }
                    Caption(caption)
                }
                .gridColumnAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider().gridCellUnsizedAxes(.horizontal)

            GridRow {
                Text("Support:")
                    .gridColumnAlignment(.trailing)
                VStack(alignment: .leading, spacing: 6) {
                    BuyMeACoffeeButton()
                    Caption("ReviewBar is free. If it helps you keep your streak, a coffee is a nice way to say so.")
                }
                .gridColumnAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear(perform: syncFromSystem)
    }

    private var caption: String {
        LaunchAtLogin.isAvailable
            ? "ReviewBar starts hidden in the menu bar — no window, no Dock icon."
            : "Only available in an installed app; this build is running from the command line."
    }

    /// macOS is the source of truth: the toggle shows whatever the system
    /// reports after the attempt, so a refused registration snaps back.
    private var launchBinding: Binding<Bool> {
        Binding(get: { launchAtLogin },
                set: { on in
                    LaunchAtLogin.setEnabled(on)
                    syncFromSystem()
                })
    }

    private func syncFromSystem() {
        launchAtLogin = LaunchAtLogin.isEnabled
        needsApproval = LaunchAtLogin.needsApproval
    }
}

/// The Buy Me a Coffee brand button, drawn natively: their own yellow
/// (#FFDD00) and black-on-yellow wordmark, but at settings scale and with no
/// network fetch — the official badge image is ~217×60 pt and would dwarf the
/// pane. Hover lightens it the way the web button does.
private struct BuyMeACoffeeButton: View {
    private static let url = URL(string: "https://buymeacoffee.com/gpressutto5")!
    private static let brandYellow = Color(red: 1.0, green: 0.867, blue: 0.0)

    @State private var isHovering = false

    var body: some View {
        Link(destination: Self.url) {
            HStack(spacing: 6) {
                Image(systemName: "cup.and.saucer.fill")
                    .font(.system(size: 13))
                Text("Buy me a coffee")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Self.brandYellow.opacity(isHovering ? 0.85 : 1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.black.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Support ReviewBar on Buy Me a Coffee")
    }
}

// MARK: - Reminders

private struct RemindersSettingsTab: View {
    @Bindable var state: AppState

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline,
             horizontalSpacing: 10, verticalSpacing: 12) {
            row("Reminders:") {
                Toggle("Remind me to review", isOn: remindersEnabled)
                Caption("A quiet nudge when you haven't reviewed for a while and cards are waiting — never paced off how many are due.")
            }

            divider

            Group {
                row("Nudge after:") {
                    picker(selection: $state.reminderSettings.interval,
                           options: intervalOptions)
                }
                row("Active hours:") {
                    HStack(spacing: 6) {
                        DatePicker("", selection: time(\.activeStart),
                                   displayedComponents: .hourAndMinute)
                            .labelsHidden()
                        Text("to").foregroundStyle(.secondary)
                        DatePicker("", selection: time(\.activeEnd),
                                   displayedComponents: .hourAndMinute)
                            .labelsHidden()
                    }
                }
                row("When I'm away:") {
                    HStack(spacing: 6) {
                        Text("Hold nudges after").foregroundStyle(.secondary)
                        picker(selection: $state.reminderSettings.idleThreshold,
                               options: idleOptions)
                    }
                }

                divider

                row("Nudges:") {
                    Toggle("Quiet down when ignored",
                           isOn: $state.reminderSettings.backoffEnabled)
                    Toggle("Count learning steps as waiting", isOn: countLearning)
                    Toggle("Open the review panel by itself",
                           isOn: $state.reminderSettings.autoOpenPanel)
                }
                row("A nudge opens:") {
                    Picker("", selection: $state.reminderSettings.nudgeOpensOntoCard) {
                        Text("A card, ready to review").tag(true)
                        Text("What's waiting, until I start").tag(false)
                    }
                    .labelsHidden()
                    .fixedSize()
                }

                divider

                row("Next day starts:") {
                    Stepper(value: $state.reminderSettings.dayRolloverHour, in: 0...23) {
                        Text(String(format: "%02d:00", state.reminderSettings.dayRolloverHour))
                            .monospacedDigit()
                    }
                    .fixedSize()
                    Caption("Match Anki's “Next day starts at” preference.")
                }
            }
            .disabled(!state.reminderSettings.isNudging)
        }
        .padding(20)
    }

    private var divider: some View {
        Divider().gridCellUnsizedAxes(.horizontal)
    }

    /// One settings line: right-aligned label, stacked controls beside it.
    private func row(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        GridRow {
            Text(label)
                .gridColumnAlignment(.trailing)
            VStack(alignment: .leading, spacing: 6) { content() }
                .gridColumnAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func picker(selection: Binding<TimeInterval>,
                        options: [TimeInterval]) -> some View {
        Picker("", selection: selection) {
            ForEach(options, id: \.self) { value in
                Text(Self.durationLabel(value)).tag(value)
            }
        }
        .labelsHidden()
        .fixedSize()
    }

    private var remindersEnabled: Binding<Bool> {
        Binding(get: { state.reminderSettings.isNudging },
                set: { state.reminderSettings.mode = $0 ? .nudge : .off })
    }

    /// The stored flag says "ignore learning cards"; the toggle reads better
    /// stated positively.
    private var countLearning: Binding<Bool> {
        Binding(get: { !state.reminderSettings.gateIgnoresLearningCards },
                set: { state.reminderSettings.gateIgnoresLearningCards = !$0 })
    }

    /// TimeOfDay ⇄ Date for `DatePicker`, anchored to today — only the
    /// hour/minute components survive the round trip.
    private func time(_ keyPath: WritableKeyPath<ReminderSettings, TimeOfDay>) -> Binding<Date> {
        Binding(
            get: {
                let t = state.reminderSettings[keyPath: keyPath]
                return Calendar.current.date(bySettingHour: t.hour, minute: t.minute,
                                             second: 0, of: Date()) ?? Date()
            },
            set: {
                let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
                state.reminderSettings[keyPath: keyPath] =
                    TimeOfDay(hour: c.hour ?? 0, minute: c.minute ?? 0)
            })
    }

    /// A Picker whose selection isn't among its tags renders empty, and the
    /// stored value can be anything (old blob, env override) — so the current
    /// value always appears as an option.
    private var intervalOptions: [TimeInterval] {
        Self.options([1800, 2700, 3600, 5400, 7200, 10800],
                     current: state.reminderSettings.interval)
    }

    private var idleOptions: [TimeInterval] {
        Self.options([300, 600, 1200, 1800, 3600],
                     current: state.reminderSettings.idleThreshold)
    }

    private static func options(_ presets: [TimeInterval], current: TimeInterval) -> [TimeInterval] {
        presets.contains(current) ? presets : (presets + [current]).sorted()
    }

    private static func durationLabel(_ interval: TimeInterval) -> String {
        let minutes = Int((interval / 60).rounded())
        if minutes < 60 { return "\(minutes) minutes" }
        if minutes % 60 == 0 {
            let hours = minutes / 60
            return hours == 1 ? "1 hour" : "\(hours) hours"
        }
        return String(format: "%.1f hours", Double(minutes) / 60)
    }
}

// MARK: - Review

private struct ReviewSettingsTab: View {
    @Bindable var state: AppState
    @State private var endpointDraft = ""

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline,
             horizontalSpacing: 10, verticalSpacing: 12) {
            GridRow {
                Text("Session:")
                    .gridColumnAlignment(.trailing)
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Review in short sessions", isOn: $state.sessionSettings.isLimited)
                    HStack(spacing: 6) {
                        Stepper(value: $state.sessionSettings.cardsPerBatch,
                                in: 1...200, step: 5) {
                            Text("\(state.sessionSettings.cardsPerBatch) cards")
                                .monospacedDigit()
                        }
                        .fixedSize()
                        Text("then offer to stop").foregroundStyle(.secondary)
                    }
                    .disabled(!state.sessionSettings.isLimited)
                    Caption("A short sitting, then quiet — reminders start their next countdown from the cards you just did, so the rest come back later in the day.")
                }
                .gridColumnAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider().gridCellUnsizedAxes(.horizontal)

            GridRow {
                Text("When done:")
                    .gridColumnAlignment(.trailing)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("Close the panel after").foregroundStyle(.secondary)
                        Picker("", selection: $state.sessionSettings.autoCloseDelay) {
                            ForEach(closeOptions, id: \.self) { value in
                                Text(Self.closeLabel(value)).tag(value)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    Caption("Applies when a session ends and when you're caught up — the button counts down, and anything you click cancels it. Errors always wait for you.")
                }
                .gridColumnAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider().gridCellUnsizedAxes(.horizontal)

            GridRow {
                Text("Decks:")
                    .gridColumnAlignment(.trailing)
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("All decks", isOn: allDecks)
                    if !state.reviewDeckScope.isEmpty {
                        deckList
                    }
                    Caption(deckFooter)
                }
                .gridColumnAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider().gridCellUnsizedAxes(.horizontal)

            GridRow {
                Text("AnkiConnect URL:")
                    .gridColumnAlignment(.trailing)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("", text: $endpointDraft)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            .frame(width: 220)
                            .onSubmit(commitEndpoint)
                        Button("Use Default") {
                            endpointDraft = AnkiConnectHTTPClient.defaultEndpoint.absoluteString
                            commitEndpoint()
                        }
                        .disabled(endpointDraft
                                  == AnkiConnectHTTPClient.defaultEndpoint.absoluteString)
                    }
                    Caption(endpointCaption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .onAppear { endpointDraft = state.ankiConnectEndpoint }
    }

    // MARK: Session

    /// The stored value always appears as an option — an env override or an
    /// older blob can hold something off-preset, and a Picker whose selection
    /// isn't among its tags renders empty.
    private var closeOptions: [TimeInterval] {
        let presets: [TimeInterval] = [0, 5, 10, 20, 30]
        let current = state.sessionSettings.autoCloseDelay
        return presets.contains(current) ? presets : (presets + [current]).sorted()
    }

    private static func closeLabel(_ delay: TimeInterval) -> String {
        delay <= 0 ? "when I say so" : "\(Int(delay.rounded())) seconds"
    }

    // MARK: Decks

    /// Bounded: a big collection shouldn't stretch the window — the list
    /// scrolls internally past ~8 decks instead.
    private var deckList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(deckChoices, id: \.self) { deck in
                    Toggle(deck, isOn: included(deck))
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 180)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
    }

    /// Everything selectable: the live top-level decks, plus any scoped names
    /// no longer among them (deck renamed or deleted) so they can be unchecked.
    private var deckChoices: [String] {
        let stale = state.reviewDeckScope.subtracting(state.topLevelDecks)
        return state.topLevelDecks + stale.sorted()
    }

    private var deckFooter: String {
        if state.reviewDeckScope.isEmpty {
            return state.topLevelDecks.isEmpty && !state.connection.isConnected
                ? "Reviews and the due count cover every deck. Connect to Anki to pick specific decks."
                : "Reviews and the due count cover every deck."
        }
        return "Review Now, the due count and reminders only see the checked decks."
    }

    private var allDecks: Binding<Bool> {
        Binding(
            get: { state.reviewDeckScope.isEmpty },
            set: { on in
                // Scoping starts from everything checked, so nothing changes
                // until a deck is actually unchecked.
                state.reviewDeckScope = on ? [] : Set(state.topLevelDecks)
            })
    }

    private func included(_ deck: String) -> Binding<Bool> {
        Binding(
            get: { state.reviewDeckScope.contains(deck) },
            set: { on in
                if on { state.reviewDeckScope.insert(deck) }
                else { state.reviewDeckScope.remove(deck) }
            })
    }

    // MARK: Endpoint

    private var endpointCaption: String {
        if AnkiConnectHTTPClient.endpoint(from: endpointDraft) == nil {
            return "Not a valid http(s) URL."
        }
        if endpointDraft != state.ankiConnectEndpoint {
            return "Press Return to apply."
        }
        return "Where the AnkiConnect add-on listens. Only change this if you changed it in Anki too."
    }

    /// Only valid URLs reach `AppState` — an invalid draft stays local to the
    /// field with the caption explaining why.
    private func commitEndpoint() {
        guard AnkiConnectHTTPClient.endpoint(from: endpointDraft) != nil else { return }
        state.ankiConnectEndpoint = endpointDraft
    }
}

// MARK: - Shortcuts

/// Anki-style reviewer keys. Deliberately narrow: one plain character per
/// rating plus the space/Return behaviour, no modifier combos — the panel
/// leaves modified presses to the responder chain (⌘, still opens Settings).
private struct ShortcutsSettingsTab: View {
    @Bindable var state: AppState

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline,
             horizontalSpacing: 10, verticalSpacing: 12) {
            GridRow {
                Text("Spacebar:")
                    .gridColumnAlignment(.trailing)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Shows the answer")
                    Toggle("Then answers Good, like Anki",
                           isOn: $state.reviewShortcuts.spaceAnswersGood)
                    Caption("Return does whatever the spacebar does.")
                }
                .gridColumnAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider().gridCellUnsizedAxes(.horizontal)

            ForEach(Ease.allCases, id: \.rawValue) { ease in
                GridRow {
                    Text("\(ease.label):")
                        .gridColumnAlignment(.trailing)
                    HStack(spacing: 8) {
                        KeyField(key: binding(for: ease))
                        if conflicts.contains(ease) {
                            Label("Already used", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            GridRow {
                Color.clear.frame(height: 0)
                VStack(alignment: .leading, spacing: 6) {
                    Button("Use Anki Defaults") {
                        state.reviewShortcuts = ReviewShortcuts()
                    }
                    .disabled(state.reviewShortcuts == ReviewShortcuts())
                    Caption("Rating keys only apply once the answer is showing.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
    }

    private var conflicts: Set<Ease> { state.reviewShortcuts.conflicts }

    private func binding(for ease: Ease) -> Binding<String> {
        Binding(get: { state.reviewShortcuts[ease] },
                set: { state.reviewShortcuts[ease] = $0 })
    }
}

/// A one-character field. The text always shows the bound key, so typing
/// anywhere in it rebinds to the newest character and anything unusable — a
/// deletion, the spacebar, a dead key — snaps back.
private struct KeyField: View {
    @Binding var key: String
    @State private var draft = ""

    var body: some View {
        TextField("", text: $draft)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.center)
            .autocorrectionDisabled()
            .frame(width: 44)
            .onAppear { draft = label(key) }
            .onChange(of: key) { _, new in
                if draft != label(new) { draft = label(new) }
            }
            .onChange(of: draft) { _, new in
                guard new != label(key) else { return }
                guard let typed = new.last.map(String.init),
                      let normalized = ReviewShortcuts.normalized(key: typed),
                      normalized != ReviewShortcuts.revealKey else {
                    draft = label(key)
                    return
                }
                key = normalized
                draft = label(normalized)
            }
    }

    private func label(_ key: String) -> String {
        ReviewShortcuts.displayLabel(for: key)
    }
}
