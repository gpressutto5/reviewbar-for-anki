# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

ReviewBar (working title) is a macOS menu-bar companion for Anki: review due cards
from a floating panel without opening Anki's reviewer window. Anki — driven through
the AnkiConnect add-on over `http://127.0.0.1:8765` — stays the sole authority for
scheduling. Never build a competing queue or scheduler.

Requires macOS 15+, Swift 6, Anki Desktop with AnkiConnect (API v6).

## Commands

```sh
make build        # swift build
make test         # ReviewBarKit tests — no Anki needed (MockAnkiConnectClient)
make run          # swift run ReviewBar (menu-bar-only; look for the status item)
make bundle       # .app via XcodeGen + xcodebuild (needs Xcode)
make install-dev  # bundle + install to ~/Applications + lsregister
```

Run one suite with `swift test --filter ReviewSessionTests`.

No Xcode project is checked in — `ReviewBar.xcodeproj` and `Support/` are
generated from `project.yml` (which also holds `LSUIElement` and the sandbox +
network-client entitlements) and are gitignored. `project.yml` must keep
ReviewBarKit as its own target: compiling both source trees into the app breaks
`import ReviewBarKit`.

**Anything bundle-dependent has to be tested through `make install-dev`,** not
`swift run` or the build directory — see the notification note below.

## Architecture

Two SwiftPM targets, split so all logic is testable without Anki or a UI:

- **`Sources/ReviewBarKit`** — library, no AppKit/SwiftUI/WebKit.
  - `AnkiConnectClient` protocol + `AnkiConnectHTTPClient` actor (JSON envelope
    `{result, error}`) + `MockAnkiConnectClient`. All UI and session logic depends
    on the protocol, never the concrete client.
  - `ReviewSession` (`@MainActor @Observable`) — the state machine; see below.
  - `ConnectionState`, `DueCount`, `SessionSettings` (the soft-session batch),
    `AnkiConnectModels` (`CurrentCard`, `DeckStats`, `Ease`, `AnkiConnectError`).
  - `PanelGeometry` — pure CGRect math for panel/notch placement (unit-tested;
    the app layer feeds it `NSScreen` measurements).
  - `AnkiMedia` (media path/Range-header helpers), `AVTagRestorer` (audio markup).
- **`Sources/ReviewBar`** — executable app.
  - `ReviewBarApp` — `MenuBarExtra` + a `Settings` scene. The label's `.task` owns
    the app-lifetime refresh loop (initial refresh + a 300 s coarse timer),
    installs the notch hotspot, and captures SwiftUI's `openSettings` action.
  - `AppState` (`@MainActor @Observable`) — connection, due count, media dir, deck
    scope, endpoint, owns the `ReviewSession` and the panel/hotspot controllers.
    `openReviewPanel` is the single entry point (menu item, notch tap, and any
    future hotkey all call it); `dismissReview` is the matching exit.
  - `SettingsView` — the preferences window: reminders form, deck scope,
    AnkiConnect endpoint. Edits `AppState` directly (no Apply button).
  - `ReviewPanelController` — the review panel is a borderless `NSPanel`, **not** a
    SwiftUI scene: it must sit above the menu bar and hug the notch. The window is a
    fixed oversized transparent stage; all motion happens in SwiftUI inside it.
  - `NotchHotspotController` — per-screen invisible hotspot over the real notch, or a
    virtual one at top-center on external displays. Rebuilt on screen changes.
  - `ReviewPanelView`, `PanelTheme` (design tokens), `CardWebView` + `MediaSchemeHandler`.

`docs/ankiconnect-queue-findings.md` carries the research behind these choices —
read it before changing the review flow or AnkiConnect usage. `docs/implementation-plan.md`
(a private working doc, not published in the repo) holds the MVP step list and
the design history behind each decision.

## Invariants that are easy to break

**GUI-driven review flow is the only correct queue.** AnkiConnect exposes no
non-GUI wrapper for the v3 scheduler's `get_queued_cards()`. The flow is
`guiDeckReview → guiCurrentCard → guiStartCardTimer → guiShowAnswer → guiAnswerCard`.
`findCards`/`answerCards` grade correctly but *select* wrongly (miss new cards,
ignore gather/sort order, daily limits, learn-ahead, buried siblings) — fallback only.
Never use `getIntervals`: it is historical revlog data and mutates the cards table
as a side effect. Interval previews come only from `guiCurrentCard.nextReviews`.

**Never call `getLatestReviewID` either — it creates decks.** It calls
`decks().id(deck)`, which creates the deck when the name doesn't exist, so
probing a non-deck name silently writes to the collection (this happened: five
empty decks, from a shell loop that word-split deck names on spaces). Assume any
AnkiConnect `get*` may mutate until its source proves otherwise.

**"Review is not currently active" is success, not failure.** After the last due
card, Anki leaves review state and `guiCurrentCard` errors. `AnkiConnectError`
`.isReviewInactive` maps it to deck-drained → next deck → `.finished`.

**`guiDeckReview` takes one deck.** "All decks" means iterating top-level decks in
sequence (`ReviewSession.remainingDecks`), skipping empty ones. Due counts use
`getDeckStats` over top-level decks only — Anki's per-deck counts already include
subdecks.

**A soft session pauses by *not fetching*, and resumes with `guiCurrentCard`.**
After `SessionSettings.cardsPerBatch` answers `ReviewSession` goes to
`.batchComplete` **before** calling `guiCurrentCard`/`guiStartCardTimer` — fetching
one more card would start its timer and leave it sitting unanswered in the
reviewer. Anki is never left, so `continueBatch()` is a plain card fetch: no
`guiDeckReview`, no re-gather, no skipped card. `start(decks:cardLimit:)`
deliberately refuses to restart from `.batchComplete` for that reason —
`AppState.startReview()` routes re-entry (menu item, notch, nudge) to
`continueBatch()` instead.

**Batching is a pacing tool, and its partner is the nudge ladder.** Finishing a
batch records a review, which resets the inactivity clock, so the rest of the
day's cards come back one interval later. Don't "improve" it into backlog
pacing (N cards ÷ M hours) — that's the same thing the PRD dropped from
reminders. The panel's auto-close countdown is view-local `@State` in
`ReviewPanelView`, cancelled by `.task` teardown when the phase changes; it is
not app state and must not become a second clock. It runs on both end states —
a finished batch and "all caught up" — but never on `.failed`: an error the
user hasn't read has to wait for them. It counts down on the *Done* button
(the action it performs), and against a `Date` deadline rather than a chain of
1 s sleeps, for the same reason `AppState.tick()` never trusts a sleep.

**Rating buttons are labelled by position, not by ease number.** Anki's
`_answerButtonList` gives four buttons as Again/Hard/Good/Easy but three as
Again/**Good**/Easy, so on a three-button card ease 2 *is* Good and ease 3 is
Easy. Never filter `Ease.allCases` by `card.buttons` and read `Ease.label` off
the raw value — that draws a Hard button which grades Good, with Good's colour
and interval preview on it. Labels, tints and interval previews all come from
`CurrentCard.answerButtons` (`AnswerButton.meaning` is the ease whose *name* the
button wears; `.ease` is what gets submitted). Keyboard shortcuts are configured
by name, so they go through `ReviewSession.submit(rating:)` /
`answerButton(labelled:)`; `submit(ease:)` stays the authority on what the card
offers.

**The reviewed-today heartbeat lives in `ReviewCounterMonitor`, not in
`AppState`.** Counter deltas (first reading / increase / decrease = day
rollover) are ReviewBarKit logic so they can be table-tested; the app only
supplies the reading and the clock, and `reviewedToday` is derived from the
monitor rather than stored a second time.

**Duplicate answers are prevented by construction.** `submit(ease:)` only acts in
`.answer` and immediately moves to `.submitting`; eases absent from `card.buttons`
are rejected. Keep it that way rather than adding flags.

**The nudge ladder picks one rung by visibility, not by elapsed time.** A notch
peek stays out until acknowledged (hover or opening the review) — its visibility
is derived from the outstanding nudge (`ActiveNudge.isLive`), never a timer. The
notification rung is for when the notch *can't be seen* (fullscreen app,
auto-hidden menu bar); time-based escalation was tried and removed, because
notifying someone who already has a pill with the due count on screen is nagging.

**Reminders nudge on inactivity, not on backlog.** The trigger is "no review in
an interval (default 1 h) and something is waiting" — never due-count pacing
("48 cards / 8 hours = every 10 min"), which was explicitly dropped from the PRD.
The heartbeat is `getNumCardsReviewedToday` (an increase = a review happened,
including reviews done in Anki itself); `getLatestReviewID` is per-deck and
excludes subdecks, so it is useless for a global last-review time. The due count
is only a gate, and that gate ignores `learn` — otherwise an "Again" leaves a
learning card pending and you are never "caught up". See "Step 11 design" in
`docs/implementation-plan.md` (private working doc).

**One clock, and coarse polling.** `AppState.tick()` on the `MenuBarExtra` label's
`.task` is the app's only timer — screen-lock and wake observers feed it rather
than adding their own. It ticks every 30 s (local work: presence, nudge
escalation, re-planning) but asks AnkiConnect anything only every 300 s, plus on
menu open and after each answer. Never trust the sleep duration: each tick
recomputes from `Date()`, which is what keeps it correct across system sleep,
clock changes and DST.

**Menu-open refresh comes from `NSMenu.didBeginTrackingNotification`**, not from
`onAppear` inside the `MenuBarExtra` content: `MenuBarExtra` exposes neither its
status item nor its menu, and `onAppear` in `.menu`-style content isn't reliably
per-open. Any menu in the app fires it (a text field's context menu in
preferences), which is harmless. Don't drop this — the due count is the number
people open the menu to read, and without it that number is up to 300 s stale.
This regressed once already: the refresh used to hang off the popover, which
step 10 deleted, and nothing replaced it until it was caught in step 13.

**Offering to relaunch Anki means watching for it to come back.** `open -a Anki`
takes ~10–15 s to answer on 8765 and the coarse refresh is 300 s away, so
`relaunchAnki()` polls every 2 s for ~40 s. Without that, a relaunch that
worked still shows "Anki isn't available" for minutes and reads as a failure.
`isLaunchingAnki` is what puts "Starting Anki…" in the menu meanwhile.

**No app sandbox, deliberately** — it cannot read Anki's `collection.media`, so
every media request fails and script-loading note types render an error card
(measured). The target is direct distribution: Developer ID + notarization, which
doesn't need the sandbox. Don't re-add it without also implementing the
`retrieveMediaFile` base64 fallback, which is what a Mac App Store build would
require. `ENABLE_HARDENED_RUNTIME` is on because notarization requires it; it
does *not* restrict reading user files.

**ReviewBarKit must stay `library.static` in `project.yml`.** Hardened runtime
enables library validation, so an embedded framework must share the app's Team
ID — which ad-hoc signed dev builds don't have, and dyld then refuses to load it.
Static linking sidesteps it entirely.

**`make bundle` is Debug, so it carries `com.apple.security.get-task-allow`**,
which notarization rejects. Anything shipped must be a Release build.

**Register the notification delegate at launch, not on first post.** Tapping a
notification can *launch* the app; if `NudgeNotifier` is only created when a
notification is posted, that launch has no delegate and the tap is silently
dropped. `AppState.start()` exists to do this ordering — don't make the notifier
lazy again.

**"Open at Login" is `SMAppService.mainApp`, with no stored copy.** macOS owns
the state — System Settings ▸ General ▸ Login Items can flip it behind the app,
and switching it off there leaves the service in `.requiresApproval`, where
`register()` silently does nothing — so `LaunchAtLogin` reads `status` every
time and the General tab re-reads on appear. Like notifications, registration
identifies the app by its bundle, so it is guarded by
`Bundle.main.bundleIdentifier != nil` and the toggle is disabled under
`swift run`.

**Notifications need a bundle Launch Services knows about.**
`UNUserNotificationCenter.current()` traps outright without an app bundle (how
`swift run` launches us), so `NudgeNotifier` is guarded by
`Bundle.main.bundleIdentifier != nil` — don't "fix" the guard. A bundle alone
isn't enough either: run it from the build directory and authorization fails with
`UNErrorDomain` code 1, "Notifications are not allowed for this application".
`make install-dev` (copy to `~/Applications` + `lsregister -f`) is what makes the
rung work. Failures are logged via `os.Logger`; don't put `try?` back.

**Card rendering must reproduce Anki's reviewer DOM exactly** — card HTML inside
`<div id="qa">` as a direct child of `<body class="card isMac">` — because note-type
CSS matches on that shape (e.g. `.card:has(> #qa)`). Dark themes key off Anki's
`nightMode`/`night_mode` body classes, mirrored from the system color scheme by an
injected script.

**Window level beats activation, so Settings has to be lifted over the panel.**
The review panel sits at `mainMenu + 1` to hug the notch; a normal Settings
window therefore opens *underneath* it even while key. `SettingsWindowElevator`
raises the Settings window one level above the panel while it is key and drops
it to `.normal` the moment it isn't — scoped to key status because a raised
level applies across apps, and an abandoned lift would float over whatever the
user switched to. Don't "fix" this by lowering the panel instead: at `.normal`
it falls behind the menu bar and the notch illusion breaks. The window doesn't
exist until SwiftUI's `openSettings()` creates it a runloop turn later, hence
the retry in `elevateSettingsWindow`.

**Opening Settings goes through `AppState.openSettingsWindow()`, and it needs
both halves.** It activates the app first — `.accessory` apps don't come
forward on their own, so the window otherwise opens *behind* whatever is
frontmost — and it calls SwiftUI's `openSettings` environment action, captured
from the `MenuBarExtra` label at launch into `openSettingsAction`. The review
panel is an AppKit `NSPanel` and can't reach the environment; sending
`showSettingsWindow:` up the responder chain from it was tried and is a
**no-op** in this app. ⌘, is handled in the panel's `performKeyEquivalent`
because the status menu's own ⌘, item only fires while that menu is open.

**Reviewer keys come from an `NSEvent` local monitor, not `keyboardShortcut`
or `performKeyEquivalent`.** The card's `WKWebView` is the panel's first
responder and plain (unmodified) presses are not key equivalents, so space and
the rating digits would be swallowed by the page. `ReviewPanelController`
installs a `.keyDown` monitor while the panel is on screen, claims presses that
`ReviewShortcuts.action(forKey:answerShown:)` resolves, and passes everything
else through — modified presses included, so ⌘, and ⌘C still work. Escape and
arrow keys must keep falling through (`normalized(key:)` rejects control
characters; the `.function` flag keeps arrows non-empty), because Escape is the
panel's close button.

**No panel phase may show a spinner nothing will resolve.** The notch is a
one-click entry point with no menu behind it, so every failure the panel can
reach has to be *stated and actionable there* — `.failed` carries Open Anki
(via `AppState.openAnkiAndReview()`, which relaunches, waits, then starts the
review) or Try Again. `AppState.startReview()` therefore reports pre-flight
failures through `ReviewSession.fail(with:)`: setting `connection` alone leaves
the phase `.idle`, which the panel used to render as "Starting review…"
forever. `.idle` is the passive "reviews waiting" offer, and
`isStartingReview` — not `.idle` — is what spins while the deck-list fetch is
in flight. `REVIEWBAR_OPEN_REVIEW=1|idle` opens these states without a notch
click.

**An open panel covers the notch hotspot**, so click-to-close can't come from
`NotchHotspotController` — `PanelContainerView` carries its own click target
over the notch band (notch width + ear flare, expanded only). Keep that band
free of other controls; the card content is padded below it for this reason.

**Deck scope applies to the due count as well as to `startReview`.** They must
see the same world: a badge or a nudge counting decks the user excluded is
wrong. `DueCount.scoped(_:to:)` falls back to all decks when the stored scope
matches nothing (every chosen deck renamed or deleted) — otherwise the app goes
silently and permanently quiet.

**`refresh()` coalesces, it does not just guard re-entry.** A refresh requested
mid-flight re-runs afterwards. Settings changes rely on it: the in-flight
refresh is answering the *previous* deck scope or endpoint and has already
stamped `lastRefreshAt`, so dropping the new one leaves the badge stale for a
full 300 s.

**The updater tells, it cannot install — and that is a signing constraint, not
a preference.** Sparkle ships only as a framework, and library validation (which
hardened runtime turns on and notarization requires) refuses to load a framework
that doesn't share the app's Team ID — the same reason ReviewBarKit must stay
`library.static`. So `UpdateChecker` reads GitHub's `/releases/latest` and opens
the release page. Use `/releases/latest`, never `/releases`: GitHub already
excludes drafts and prereleases from it, so a tagged beta never prompts
everyone. `AppVersion` compares components numerically because `0.10.0` sorts
below `0.9.0` as a string. A build with no `CFBundleShortVersionString` (how
`swift run` launches us) is `.unsupported`, not version zero — a dev build must
never announce that it is out of date. The check is driven by `AppState.tick()`
like everything else with a schedule, and a *failed* check deliberately doesn't
stamp `lastCheckedAt`: a blip would otherwise buy a full day of silence.

**Card theme is the web view's `NSAppearance`, not a CSS override.** The
panel pins itself to `darkAqua`, so every card used to render dark. WebKit's
`prefers-color-scheme` follows the view's effective appearance, so
`CardWebView` sets `webView.appearance` per `CardAppearance` (nil = inherit
dark, `.aqua` = light, `NSApp.effectiveAppearance` + KVO = system) and the
existing night-mode script mirrors it into Anki's body classes. Don't force
the classes from Swift instead: note-type CSS also uses the media query, and
the two would disagree. `SystemAppearance` observes `NSApp` for the same
reason — SwiftUI's `colorScheme` inside the panel is always dark and can't
be used to pick the card surface colour.

**Pass/fail mode filters by `meaning`, never by ease number.**
`ReviewDisplaySettings.visibleButtons` keeps the buttons *named* Again and
Good, so on a three-button card it keeps ease 2 (which is Good there). The
same filter gates keyboard ratings in `AppState.handleReviewKey`; the panel
must never show a button the keyboard can't reach or vice versa. Anki's
scheduler is untouched — the app never tells Anki the card has two buttons.

**The close key resolves before the phase switch in `handleReviewKey`.**
Escape stays the panel's close button (it is a key equivalent and never
reaches `normalized(key:)`); the optional `ReviewShortcuts.close` key is an
addition, checked first so it works in every phase including `.failed`. It
never shadows the reveal key — a close binding on space is inert and flagged.

**`CardWebView` has one native bridge, deliberately**: the one-way `cardHeight`
message used to size the panel. Don't add more.

**`MediaSchemeHandler` must speak real HTTP** (`HTTPURLResponse` with 200/404/206,
Content-Type/Length, `Accept-Ranges` + Range, CORS). Card scripts fetch media via
fetch/XHR and a status-less `URLResponse` surfaces to JS as "HTTP 0".

**Audio needs `AVTagRestorer`.** AnkiConnect returns raw AV markers
(`[anki:play:a:0]`); plain `[sound:…]` text is not enough for note types that scan
field content for anchor/audio elements. It emits Anki-shaped
`<a class="replay-button">` anchors wrapping `<audio>`.

**Strip U+2068/U+2069** (bidi isolates) from `nextReviews` before display —
`CurrentCard.displayIntervals` does this.

**Connection reset/refused means Anki may be dead** (observed in the live spike, no
crash report). Treat it as `.unreachable`, verify, and offer relaunch — `open -a Anki`
takes ~10–15 s. Bundle ids: `net.ankiweb.anki`, legacy `net.ankiweb.dtop`.

## Testing against real Anki

**Probe scripts count as destructive experiments** — an AnkiConnect action named
`get*` can still write (see `getLatestReviewID` above). Use a disposable profile,
and do multi-step probing in Python rather than shell: deck names contain spaces,
and `for d in $(...)` word-splits them into names that then get created.

Never point destructive experiments at the production collection. Create a
disposable profile (Anki → File → Switch Profile → Add, e.g. `reviewbar-test`).
On macOS, App Nap can freeze a backgrounded Anki and stall AnkiConnect; workaround:
`defaults write net.ankiweb.dtop NSAppSleepDisabled -bool true`.
