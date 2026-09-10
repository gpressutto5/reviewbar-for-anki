import AppKit
import Foundation
import Observation
import ReviewBarKit
import os

@MainActor
@Observable
final class AppState {
    nonisolated private static let log =
        Logger(subsystem: "com.reviewbar.app", category: "app")

    private(set) var connection: ConnectionState = .unknown
    private(set) var dueCount: Int?
    /// Anki's reviewed-today counter — the reminder heartbeat, and a cheap
    /// daily stat for the menu.
    var reviewedToday: Int? { reviewMonitor.lastCount }
    private(set) var isRefreshing = false
    /// Anki was launched from the menu and hasn't answered yet — the menu says
    /// so, rather than leaving "Anki isn't available" up while it boots.
    private(set) var isLaunchingAnki = false
    /// A review was asked for and its pre-flight calls are in flight — the
    /// window before `ReviewSession` itself reports `.entering`.
    private(set) var isStartingReview = false
    let session: ReviewSession
    /// Checks GitHub for a newer release. Driven by `tick()` like everything
    /// else with a schedule; see `UpdateChecker` for why the app can't install
    /// the update itself.
    let updateChecker: UpdateChecker
    /// Anki's collection.media path, fetched when a review starts. Nil means
    /// media requests 404 but the card text still renders.
    private(set) var mediaDir: String?
    /// Every top-level deck, unscoped — the choices the preferences deck list
    /// offers. Refreshed alongside the due count.
    private(set) var topLevelDecks: [String] = []

    /// How often the tick loop asks Anki anything. Local ticks are much more
    /// frequent (see `tickInterval`) so escalation and presence changes land
    /// promptly without polling AnkiConnect.
    static let refreshInterval: TimeInterval = 300
    static let tickInterval: Duration = .seconds(30)
    /// No nudge in the first moments after launch: at login the user is busy,
    /// and a nudge fired into a startup storm is pure noise.
    private static let startupGrace: TimeInterval =
        AppState.envOverride("REVIEWBAR_STARTUP_GRACE") ?? 120

    // MARK: Reminders

    /// Reminder configuration: defaults plus whatever is in `UserDefaults`
    /// under `reminderSettings`, edited live by the preferences window.
    var reminderSettings: ReminderSettings {
        didSet {
            guard reminderSettings != oldValue else { return }
            persistReminderSettings()
            Task { await evaluateReminder() }
        }
    }
    /// Top-level decks "Review Now" (and the due count) covers. Empty = all.
    var reviewDeckScope: Set<String> {
        didSet {
            guard reviewDeckScope != oldValue else { return }
            defaults.set(Array(reviewDeckScope).sorted(), forKey: Self.deckScopeKey)
            Task { await refresh() }
        }
    }

    /// Soft-session budget: how many cards one sitting is worth before the
    /// panel pauses and offers to continue.
    var sessionSettings: SessionSettings {
        didSet {
            guard sessionSettings != oldValue else { return }
            guard let data = try? JSONEncoder().encode(sessionSettings) else { return }
            defaults.set(data, forKey: Self.sessionKey)
        }
    }

    /// Review-panel key bindings (space/Return to flip, one key per rating).
    var reviewShortcuts: ReviewShortcuts {
        didSet {
            guard reviewShortcuts != oldValue else { return }
            guard let data = try? JSONEncoder().encode(reviewShortcuts) else { return }
            defaults.set(data, forKey: Self.shortcutsKey)
        }
    }

    /// What the panel shows: card theme and whether rating buttons carry
    /// interval previews.
    var reviewDisplay: ReviewDisplaySettings {
        didSet {
            guard reviewDisplay != oldValue else { return }
            guard let data = try? JSONEncoder().encode(reviewDisplay) else { return }
            defaults.set(data, forKey: Self.displayKey)
        }
    }

    /// The AnkiConnect URL as typed in preferences. The UI only assigns
    /// values `AnkiConnectHTTPClient.endpoint(from:)` accepts.
    var ankiConnectEndpoint: String {
        didSet {
            guard ankiConnectEndpoint != oldValue else { return }
            defaults.set(ankiConnectEndpoint, forKey: Self.endpointKey)
            guard let httpClient,
                  let url = AnkiConnectHTTPClient.endpoint(from: ankiConnectEndpoint)
            else { return }
            Task {
                await httpClient.setEndpoint(url)
                await refresh()
            }
        }
    }

    private(set) var reminder: ReminderState
    /// Compares successive readings of Anki's reviewed-today counter and feeds
    /// `reminder`; the only owner of `reviewedToday`.
    private var reviewMonitor = ReviewCounterMonitor()
    /// Last decision, kept for the menu's "next nudge" line.
    private(set) var nudgeDecision: ReminderDecision = .idle(.disabled)
    /// True while the notch pill sits out *as a nudge*. Derived from the
    /// outstanding nudge rather than a timer of its own, so it stays visible
    /// until acknowledged — a peek you have to be looking at for three seconds
    /// isn't a reminder. Hover peeking is separate and local to the view.
    private(set) var isPeeking = false

    private let client: any AnkiConnectClient
    /// The concrete HTTP client when we created one — the handle through which
    /// an endpoint change in preferences reaches the live connection. Nil when
    /// a client was injected (tests, previews).
    @ObservationIgnored private let httpClient: AnkiConnectHTTPClient?
    private let defaults: UserDefaults
    private var lastRefreshAt: Date = .distantPast
    /// A refresh was asked for while one was in flight — see `refresh()`.
    @ObservationIgnored private var refreshRequested = false
    @ObservationIgnored private lazy var panelController = ReviewPanelController()
    @ObservationIgnored private var notchHotspot: NotchHotspotController?
    @ObservationIgnored private var settingsElevator: SettingsWindowElevator?
    @ObservationIgnored private lazy var notifier = NudgeNotifier { [weak self] in
        self?.openReviewFromNudge()
    }
    /// SwiftUI's `openSettings` environment action, captured by the menu bar
    /// label at launch. AppKit-owned windows (the review panel) can't reach
    /// the environment themselves.
    @ObservationIgnored var openSettingsAction: (() -> Void)?

    /// The repository releases are published to. Injected nowhere: an update
    /// check pointed at a fork would offer the wrong build.
    private static let releaseOwner = "gpressutto5"
    private static let releaseRepository = "reviewbar-for-anki"

    init(client: (any AnkiConnectClient)? = nil,
         feed: (any ReleaseFeed)? = nil,
         defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let endpointString = defaults.string(forKey: Self.endpointKey)
            ?? AnkiConnectHTTPClient.defaultEndpoint.absoluteString
        self.ankiConnectEndpoint = endpointString
        if let client {
            self.client = client
            self.httpClient = nil
        } else {
            let http = AnkiConnectHTTPClient(
                endpoint: AnkiConnectHTTPClient.endpoint(from: endpointString)
                    ?? AnkiConnectHTTPClient.defaultEndpoint)
            self.client = http
            self.httpClient = http
        }
        self.session = ReviewSession(client: self.client)
        self.updateChecker = UpdateChecker(
            feed: feed ?? GitHubReleaseFeed(owner: Self.releaseOwner,
                                            repository: Self.releaseRepository),
            defaults: defaults)
        self.reviewDeckScope = Set(defaults.stringArray(forKey: Self.deckScopeKey) ?? [])
        self.reviewShortcuts = Self.loadReviewShortcuts(from: defaults)
        self.reviewDisplay = Self.loadReviewDisplay(from: defaults)
        self.sessionSettings = Self.loadSessionSettings(from: defaults)
        self.reminderSettings = Self.loadReminderSettings(from: defaults)
        var reminder = ReminderState()
        reminder.snooze(until: Date().addingTimeInterval(Self.startupGrace))
        self.reminder = reminder
    }

    // MARK: Tick loop
    //
    // One clock for the whole app, owned by the MenuBarExtra label's `.task`.
    // The sleep duration is never trusted: every tick recomputes from `Date()`,
    // which is what makes this correct across system sleep, clock changes and
    // DST. `observeSystemState` ticks immediately on wake.

    func tick(now: Date = Date()) async {
        if now.timeIntervalSince(lastRefreshAt) >= Self.refreshInterval {
            await refresh()
        }
        await evaluateReminder(now: now)
        // Cheap and self-limiting: does nothing until a day has passed.
        await updateChecker.checkIfDue(now: now)
    }

    /// One-time setup once the app is running. Called from the app's `.task`.
    func start() {
        activateNotchHotspot()
        observeSystemState()
        // Creating the notifier is what registers the
        // UNUserNotificationCenter delegate, and that has to happen at launch
        // rather than on the first post: tapping a notification can *launch*
        // the app, and the pending response is dropped if no delegate is set
        // by the time launching finishes. Registering does not request
        // authorization, so this stays quiet until a nudge actually needs it.
        _ = notifier
        // Panel states are otherwise reachable only by clicking the notch,
        // which is awkward to reach while iterating — and impossible for the
        // Anki-is-closed path without closing Anki:
        //   REVIEWBAR_OPEN_REVIEW=1 make run     (opens onto a card)
        //   REVIEWBAR_OPEN_REVIEW=idle make run  (opens without asking Anki
        //                                         anything — the passive state)
        switch ProcessInfo.processInfo.environment["REVIEWBAR_OPEN_REVIEW"] {
        case "1":
            openReviewPanel(on: NSScreen.main, notchStyle: true)
            Task { await startReview() }
        case "idle":
            openReviewPanel(on: NSScreen.main, notchStyle: true)
        default:
            break
        }
    }

    /// Screen lock, system wake, and the status menu opening. All feed the
    /// existing tick/refresh — no second timer.
    func observeSystemState() {
        // Opening the menu is a request to look at the due count, so it must
        // not be up to `refreshInterval` stale. The popover this used to hang
        // off was deleted in step 10 and nothing replaced it; `MenuBarExtra`
        // exposes neither its status item nor its menu, and `onAppear` inside
        // `.menu`-style content isn't reliably per-open, so observe NSMenu
        // itself. Any menu in the app satisfies this (a text field's context
        // menu in preferences, say) — harmless, since a refresh is cheap and
        // always safe.
        NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil,
            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.refresh() }
            }
        }

        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(forName: .init("com.apple.screenIsLocked"),
                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setScreenLocked(true) }
        }
        distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"),
                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setScreenLocked(false) }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.tick() }
            }
        }
    }

    private func setScreenLocked(_ locked: Bool) {
        reminder.isScreenLocked = locked
        Task { await evaluateReminder() }
    }

    /// Decide whether to nudge, and do it. Fills in the observed world first —
    /// `ReminderScheduler` reads no clocks or system APIs of its own.
    func evaluateReminder(now: Date = Date()) async {
        reminder.isPanelOpen = panelController.isVisible
        reminder.systemIdleSeconds = SystemPresence.idleSeconds
        reminder.isNotchHidden = SystemPresence.isNotchHidden

        let decision = ReminderScheduler.plan(settings: reminderSettings,
                                              state: reminder, now: now)
        nudgeDecision = decision
        // The pill's visibility is a function of state, re-derived every tick,
        // so it retracts on acknowledgement, review, snooze or lifetime end
        // without anything having to remember to retract it.
        defer { isPeeking = reminder.nudge?.isLive(
            at: now, lifetime: reminderSettings.nudgeLifetime) ?? false }

        guard case .nudge(let rung) = decision else { return }
        // Record before firing: `recordNudge` is what counts an unresolved
        // predecessor as ignored, and it must hold even if firing awaits.
        reminder.recordNudge(rung: rung, at: now)
        await fire(rung)
    }

    private func fire(_ rung: NudgeRung) async {
        switch rung {
        case .peek:
            // Nothing to do: the pill is derived from the recorded nudge above.
            break
        case .notify:
            await notifier.post(body: nudgeBody)
        case .openPanel:
            openReviewFromNudge()
        }
    }

    private var nudgeBody: String {
        guard let dueCount, dueCount > 0 else { return "Time for a few reviews." }
        return dueCount == 1 ? "1 review waiting." : "\(dueCount) reviews waiting."
    }

    /// The user showed they saw the nudge (hovered the notch, or opened the
    /// review). Choosing not to review is a legitimate answer, so this stops
    /// the escalation to a notification.
    func acknowledgeNudge() {
        guard reminder.nudge?.acknowledged == false else { return }
        reminder.acknowledgeNudge()
        isPeeking = false
    }

    func snoozeNudges(for duration: TimeInterval) {
        reminder.snooze(until: Date().addingTimeInterval(duration))
        Task { await evaluateReminder() }
    }

    /// "Not today" — quiet until the active window opens again.
    func snoozeNudgesUntilTomorrow() {
        reminder.snooze(until: reminderSettings.nextActiveWindowOpen(after: Date()))
        Task { await evaluateReminder() }
    }

    // MARK: Review panel

    /// Single entry/exit point for the floating review panel — the menu item,
    /// notch hotspot and nudges all use it; a global hotkey would too.
    func openReviewPanel(on screen: NSScreen? = nil, anchorX: CGFloat? = nil,
                         notchStyle: Bool = false) {
        // Opening the review is the strongest acknowledgement there is, from
        // whichever entry point — so it's handled here rather than at each.
        acknowledgeNudge()
        panelController.show(state: self, on: screen, anchorX: anchorX,
                             notchStyle: notchStyle)
    }

    /// Acting on a nudge: opens the panel out of the notch and, unless the user
    /// asked for a passive announcement, lands straight on a live card.
    private func openReviewFromNudge() {
        openReviewPanel(on: NSScreen.main, notchStyle: true)
        if reminderSettings.nudgeOpensOntoCard {
            Task { await startReview() }
        }
    }

    /// Put a clickable/peeking hotspot over the notch of every screen — the
    /// real one on the built-in display, a hover-revealed virtual one on
    /// externals. Re-attaches itself when displays change.
    func activateNotchHotspot() {
        guard notchHotspot == nil else { return }
        notchHotspot = NotchHotspotController(state: self) { [weak self] screen in
            self?.toggleReviewFromNotch(on: screen)
        }
    }

    /// Clicking a notch (real or virtual) behaves like NotchNook: opens the
    /// review growing out of that notch, or folds it away if already out.
    private func toggleReviewFromNotch(on screen: NSScreen) {
        if panelController.isVisible {
            dismissReview()
        } else {
            openReviewPanel(on: screen, notchStyle: true)
            Task { await startReview() }
        }
    }

    /// Apply a review-panel key press. Returns true when the key was one of
    /// ours, so the panel can swallow it before the card's web view sees it.
    ///
    /// Phase decides what a key means, and `ReviewSession` re-checks it: a key
    /// held down through `.submitting` resolves to a rating that `submit` then
    /// ignores, so repeats can't double-answer.
    @discardableResult
    func handleReviewKey(_ key: String) -> Bool {
        // The close key is phase-independent: like Escape, it has to work on
        // the end-of-session screens and on an error just as much as on a card.
        // (Its resolution doesn't depend on `answerShown`.)
        if reviewShortcuts.action(forKey: key, answerShown: false) == .close {
            dismissReview()
            return true
        }
        let answerShown: Bool
        switch session.phase {
        case .question: answerShown = false
        case .answer: answerShown = true
        // `.submitting` still swallows its keys — the card on screen is the one
        // being graded, and passing them to the web view would be surprising.
        case .submitting: return reviewShortcuts.action(forKey: key, answerShown: true) != nil
        // A finished batch reuses the flip key as "continue" — it's the key
        // the hand is already on.
        case .batchComplete:
            guard reviewShortcuts.action(forKey: key, answerShown: false) == .showAnswer
            else { return false }
            Task { await continueReviewBatch() }
            return true
        case .idle, .entering, .finished, .failed: return false
        }
        guard let action = reviewShortcuts.action(forKey: key, answerShown: answerShown)
        else { return false }
        switch action {
        case .close:
            // Handled above; unreachable, but the switch stays exhaustive
            // rather than defaulting so a new action can't slip through.
            dismissReview()
        case .showAnswer:
            Task { await session.revealAnswer() }
        case .rate(let ease):
            // A button hidden by pass/fail mode is hidden from the keyboard
            // too; the key is still swallowed so the card doesn't see it.
            guard reviewDisplay.allows(rating: ease) else { return true }
            // Shortcuts are configured by name, so they submit by name too —
            // "Good" is ease 2 on a three-button card.
            Task {
                await session.submit(rating: ease)
                await refresh()
            }
        case .cardAction(let cardAction):
            Task { await performCardAction(cardAction) }
        }
        return true
    }

    /// Bury or suspend the card on screen — the hotkeys and the panel's
    /// "more" menu both land here. Works on either side of the card; the
    /// refresh is for the due count, which just dropped by one (or a note's
    /// worth).
    func performCardAction(_ action: CardAction) async {
        await session.perform(action)
        await refresh()
    }

    /// Take back the last answer — the panel's Undo button and ⌘Z, matching
    /// Anki's own Undo. `ReviewSession.undo()` owns the Anki side; this only
    /// keeps the reminder heartbeat honest afterwards.
    func undoReview() async {
        guard await session.undo() else { return }
        // Anki drops the undone review from its reviewed-today counter. Told
        // in advance, the monitor reads the lower count as "unchanged" rather
        // than as a day rollover, which would wipe the reminder clock.
        reviewMonitor.noteUndo()
        await refresh()
    }

    /// Take another batch without leaving Anki's reviewer. The panel stays
    /// open; nothing is re-gathered.
    func continueReviewBatch() async {
        await session.continueBatch()
    }

    /// End the session and fold the panel away — the close button, Esc, and
    /// clicking the notch again all mean the same thing.
    func dismissReview() {
        session.stop()
        closeReviewPanel()
        Task { await finishReview() }
    }

    func closeReviewPanel() {
        panelController.hide()
    }

    /// Open (or front) the Settings scene from anywhere, including AppKit
    /// contexts like the review panel's ⌘, key equivalent.
    ///
    /// SwiftUI's `openSettings()` is fire-and-forget and, in an accessory app
    /// driven from a status menu, it sometimes fires into nothing: called
    /// while the menu is still dismissing or before activation has landed,
    /// no window appears and no error is raised — the user clicks Settings…
    /// and nothing happens until they click again. So the open is verified
    /// (a visible Settings window within a beat) and re-issued if it didn't
    /// take, and a window that already exists is fronted directly instead of
    /// asking SwiftUI at all.
    func openSettingsWindow() {
        // Accessory app: without activating, the window opens behind
        // whatever is frontmost.
        NSApplication.shared.activate()
        if let window = NSApplication.shared.settingsWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            elevateSettingsWindow()
            return
        }
        requestSettingsWindow()
    }

    /// Ask SwiftUI for the window, then check it arrived. Retries are
    /// spaced a runloop-and-a-bit apart: the first request usually fails only
    /// because it raced the closing menu, and the second one lands.
    private func requestSettingsWindow(attempt: Int = 0) {
        openSettingsAction?()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            if NSApplication.shared.settingsWindow?.isVisible == true {
                elevateSettingsWindow()
                return
            }
            guard attempt < 4 else {
                Self.log.error("Settings window did not open after \(attempt + 1) requests")
                return
            }
            NSApplication.shared.activate()
            requestSettingsWindow(attempt: attempt + 1)
        }
    }

    /// Activation isn't enough to clear the review panel: it sits above the
    /// menu bar by window level, and level beats ordering. `SettingsWindowElevator`
    /// lifts the Settings window over it for as long as it's key.
    ///
    /// The window doesn't exist yet on the first open — `openSettings()` creates
    /// it on a later runloop turn — so this retries briefly rather than assuming.
    private func elevateSettingsWindow(attempt: Int = 0) {
        guard let window = NSApplication.shared.settingsWindow else {
            guard attempt < 20 else {
                Self.log.error("Settings window never appeared; not elevating it")
                return
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                elevateSettingsWindow(attempt: attempt + 1)
            }
            return
        }
        // SwiftUI reuses one Settings window, so the elevator is reused too.
        if settingsElevator?.tracks(window) == true { return }
        settingsElevator?.invalidate()
        settingsElevator = SettingsWindowElevator(window: window) { [weak self] in
            self?.panelController.visibleWindowLevel
        }
    }

    /// Runs when the review panel closes: if any cards were answered, reset
    /// the reminder clock and — only when the user opted in — ask Anki to
    /// sync with AnkiWeb (fire-and-forget: sync failures such as "no sync
    /// account" shouldn't surface as review errors), then refresh the badge.
    func finishReview() async {
        if session.answeredCount > 0 {
            // Don't wait for the counter poll to notice: any answered card
            // buys the full interval right now.
            reminder.recordReview(at: Date())
            if sessionSettings.syncOnClose {
                try? await client.sync()
            }
        }
        await refresh()
        await evaluateReminder()
    }

    // MARK: Status

    /// Count beside the menu bar glyph. The glyph alone means "caught up";
    /// text appears only when there is something to count or report.
    var menuBarTitle: String {
        switch connection {
        case .connected where dueCount ?? 0 > 0: "\(dueCount!)"
        case .connected: ""
        default: "–"
        }
    }

    var dueSummary: String {
        guard connection.isConnected, let dueCount else { return "" }
        return dueCount == 0 ? "All caught up" : "\(dueCount) due"
    }

    var reviewedTodaySummary: String? {
        guard let reviewedToday, reviewedToday > 0 else { return nil }
        return "\(reviewedToday) reviewed today"
    }

    /// The scheduler's decision in words, for the menu. Nil when there's
    /// nothing worth saying (disabled, caught up, mid-review).
    var nudgeSummary: String? {
        switch nudgeDecision {
        case .nudge:
            return "Nudging now"
        case .idle(.userAway), .idle(.screenLocked):
            return "Nudge waiting for you"
        case .idle:
            return nil
        case .wait(let until, let reason):
            let time = Self.timeFormatter.string(from: until)
            switch reason {
            case .interval, .outsideActiveWindow: return "Next nudge \(time)"
            case .snoozed: return "Snoozed until \(time)"
            case .silenced: return "Paused until \(time)"
            }
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    // MARK: Anki

    /// Launch Anki and watch for it to answer. The spike measured ~10–15 s
    /// from launch to AnkiConnect responding, and the coarse refresh is 300 s
    /// away — without polling, a relaunch that worked still reads as "Anki
    /// isn't available" for minutes, which looks like it failed.
    func relaunchAnki() async {
        guard !isLaunchingAnki, let url = Self.ankiApplicationURL else { return }
        isLaunchingAnki = true
        defer { isLaunchingAnki = false }
        do {
            try await NSWorkspace.shared.openApplication(at: url, configuration: .init())
        } catch {
            // Nothing is coming, so don't spend 40 s watching for it. Logged
            // rather than swallowed: the menu can only say "still unavailable",
            // which doesn't distinguish "won't launch" from "still booting".
            Self.log.error("launching Anki failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        for _ in 0..<Self.launchPollAttempts {
            try? await Task.sleep(for: Self.launchPollInterval)
            await refresh()
            if connection.isConnected { return }
        }
    }

    /// The review panel's recovery path: launch Anki, wait for it to answer,
    /// then start the review the user asked for. `relaunchAnki` already polls,
    /// so by the time it returns the connection is settled either way.
    func openAnkiAndReview() async {
        await relaunchAnki()
        guard connection.isConnected else { return }
        await startReview()
    }

    /// Whether an "Open Anki" action can do anything — false when Anki isn't
    /// installed, where offering it would be a dead end.
    var canOpenAnki: Bool { Self.ankiApplicationURL != nil }

    /// ~40 s of watching: comfortably past the measured ready time, and short
    /// enough that a failed launch stops claiming to be in progress.
    private static let launchPollAttempts = 20
    private static let launchPollInterval: Duration = .seconds(2)

    /// Current Anki builds use net.ankiweb.anki; pre-2024 builds used
    /// net.ankiweb.dtop.
    static var ankiApplicationURL: URL? {
        ["net.ankiweb.anki", "net.ankiweb.dtop"].lazy
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .first
    }

    /// Kick off a review session over every top-level deck, in order.
    ///
    /// Re-entering while a batch is complete means "keep going" — the menu
    /// item, the notch and a nudge all land here, and re-running
    /// `guiDeckReview` would re-gather the queue instead of resuming it.
    func startReview() async {
        if case .batchComplete = session.phase {
            await continueReviewBatch()
            return
        }
        // The deck-list fetch below happens before `ReviewSession` reaches
        // `.entering`, and it is the call that fails when Anki is closed. The
        // panel spins on this flag meanwhile, so it never shows a "Review Now"
        // offer over a request already in flight.
        isStartingReview = true
        defer { isStartingReview = false }
        do {
            mediaDir = try? await client.mediaDirPath()
            let decks = DueCount.scoped(
                DueCount.topLevelDecks(from: try await client.deckNames()),
                to: reviewDeckScope)
            await session.start(decks: decks, cardLimit: sessionSettings.cardLimit)
        } catch {
            connection = .from(error)
            // The panel is already open on this: leaving the phase `.idle`
            // would spin "Starting review…" forever over a dead connection.
            session.fail(with: connection)
        }
    }

    /// Coalescing rather than merely re-entrant: a refresh asked for while one
    /// is in flight runs again afterwards instead of being dropped. Settings
    /// changes depend on it — an in-flight refresh is answering the *previous*
    /// deck scope or endpoint, and it has already stamped `lastRefreshAt`, so a
    /// dropped one would leave the badge stale for another `refreshInterval`.
    func refresh() async {
        guard !isRefreshing else {
            refreshRequested = true
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            refreshRequested = false
            await performRefresh()
        } while refreshRequested
    }

    private func performRefresh() async {
        lastRefreshAt = Date()
        do {
            let apiVersion = try await client.version()
            let topLevel = DueCount.topLevelDecks(from: try await client.deckNames())
            topLevelDecks = topLevel
            // The badge, the gate and Review Now all see the same scoped world —
            // nudging over decks the user excluded would be wrong.
            let stats = try await client.deckStats(
                decks: DueCount.scoped(topLevel, to: reviewDeckScope))
            reminder.due = DueCount.breakdown(from: stats)
            dueCount = reminder.due.total
            observeReviewCounter(try await client.numCardsReviewedToday())
            connection = .connected(apiVersion: apiVersion)
        } catch {
            connection = .from(error)
            dueCount = nil
        }
    }

    // MARK: Updates

    /// Open the release page for the update on offer. ReviewBar can't install
    /// it, so the page — with its install steps — is where the user goes.
    func openLatestRelease() {
        guard let release = updateChecker.status.availableRelease else { return }
        NSWorkspace.shared.open(release.url)
    }

    /// "Check for Updates…": forced, so it answers even when automatic checks
    /// are off or the offered version was skipped.
    func checkForUpdates() async {
        await updateChecker.check(force: true)
    }

    func skipOfferedUpdate() {
        guard let release = updateChecker.status.availableRelease else { return }
        updateChecker.skip(release.version)
    }

    /// Menu line for an update on offer, or nil when there is nothing to say.
    var updateSummary: String? {
        guard let release = updateChecker.status.availableRelease else { return nil }
        return "Update available: \(release.version)"
    }

    /// The reminder heartbeat. The delta logic lives in
    /// `ReviewCounterMonitor` (ReviewBarKit) where it is table-tested; this
    /// only supplies the reading and the clock.
    private func observeReviewCounter(_ count: Int) {
        reviewMonitor.observe(count, at: Date(), applyingTo: &reminder)
    }

    // MARK: Settings persistence

    private static let settingsKey = "reminderSettings"
    private static let deckScopeKey = "reviewDecks"
    private static let endpointKey = "ankiConnectEndpoint"
    private static let shortcutsKey = "reviewShortcuts"
    private static let sessionKey = "sessionSettings"
    private static let displayKey = "reviewDisplay"

    private static func loadSessionSettings(from defaults: UserDefaults) -> SessionSettings {
        var settings = SessionSettings()
        if let data = defaults.data(forKey: sessionKey),
           let stored = try? JSONDecoder().decode(SessionSettings.self, from: data) {
            settings = stored
        }
        // A 10-card batch is a slow thing to watch during development:
        //   REVIEWBAR_BATCH_CARDS=2 REVIEWBAR_BATCH_AUTOCLOSE=0 make run
        if let raw = ProcessInfo.processInfo.environment["REVIEWBAR_BATCH_CARDS"],
           let cards = Int(raw) {
            settings.isLimited = cards > 0
            if cards > 0 { settings.cardsPerBatch = cards }
        }
        if let delay = envOverride("REVIEWBAR_BATCH_AUTOCLOSE") {
            settings.autoCloseDelay = delay
        }
        return settings
    }

    private static func loadReviewShortcuts(from defaults: UserDefaults) -> ReviewShortcuts {
        guard let data = defaults.data(forKey: shortcutsKey),
              let stored = try? JSONDecoder().decode(ReviewShortcuts.self, from: data)
        else { return ReviewShortcuts() }
        return stored
    }

    private static func loadReviewDisplay(from defaults: UserDefaults) -> ReviewDisplaySettings {
        guard let data = defaults.data(forKey: displayKey),
              let stored = try? JSONDecoder().decode(ReviewDisplaySettings.self, from: data)
        else { return ReviewDisplaySettings() }
        return stored
    }

    private static func loadReminderSettings(from defaults: UserDefaults) -> ReminderSettings {
        var settings = ReminderSettings()
        if let data = defaults.data(forKey: settingsKey),
           let stored = try? JSONDecoder().decode(ReminderSettings.self, from: data) {
            settings = stored
        }
        // Nudges live on hour timescales, so watching one happen would mean
        // waiting an hour. These make a dev run observable without editing
        // (and recompiling) the defaults:
        //   REVIEWBAR_STARTUP_GRACE=5 REVIEWBAR_NUDGE_INTERVAL=45 make run
        if let interval = envOverride("REVIEWBAR_NUDGE_INTERVAL") {
            settings.interval = interval
        }
        // Also the only way to exercise the .openPanel rung without waiting for
        // a user to opt in: REVIEWBAR_AUTO_OPEN=1
        if let raw = ProcessInfo.processInfo.environment["REVIEWBAR_AUTO_OPEN"] {
            settings.autoOpenPanel = raw == "1"
        }
        return settings
    }

    private static func envOverride(_ name: String) -> TimeInterval? {
        ProcessInfo.processInfo.environment[name].flatMap(TimeInterval.init)
    }

    private func persistReminderSettings() {
        guard let data = try? JSONEncoder().encode(reminderSettings) else { return }
        defaults.set(data, forKey: Self.settingsKey)
    }
}
