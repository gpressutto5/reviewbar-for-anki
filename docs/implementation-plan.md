# ReviewBar — technical implementation plan

**Internal name:** ReviewBar (temporary; final branding TBD, "… for Anki" style).
**Prerequisite reading:** `ankiconnect-queue-findings.md` — the investigation that
fixed the core architectural decision.

## Architecture

_As built (this section drifted during steps 5–11; corrected 2026-08-28)._

Two-module Swift Package; the XcodeGen `project.yml` mirrors it for bundling.

- **ReviewBarKit** (library, no AppKit/SwiftUI/WebKit — testable without Anki):
  - `AnkiConnectClient` — protocol + `AnkiConnectHTTPClient` actor (URLSession,
    typed actions, JSON envelope `{result, error}`), plus `MockAnkiConnectClient`.
  - `ConnectionState` — `unknown / connected(apiVersion:) / unreachable /
    incompatibleVersion(Int) / error(String)`, plus `.from(any Error)`.
  - `DueCount` / `DueBreakdown` — top-level-deck due sums; the breakdown splits
    `learn` out for the nudge gate.
  - `ReviewSession` (@MainActor @Observable) — state machine over the **GUI
    review flow** (see findings): `idle → entering → question → answer →
    submitting → question | finished`, plus `failed(ConnectionState)`.
    Duplicate submissions are impossible by construction.
  - `ReminderScheduler` — pure inactivity-nudge decision function, with
    `ReminderSettings` / `ReminderState` / `TimeOfDay`; see "Step 11 design".
  - `PanelGeometry` — panel/notch frame math. `AnkiMedia`, `AVTagRestorer`.
- **ReviewBar** (executable app):
  - `ReviewBarApp` — `MenuBarExtra` + a `Settings` scene. The menu bar label's
    `.task` owns the app's single clock, calls `AppState.start()`, and hands
    over SwiftUI's `openSettings` action.
  - `AppState` (@MainActor @Observable) — connection, due count, reviewed-today,
    media dir, deck scope, endpoint, the `ReviewSession`, the reminder state,
    and the panel/hotspot controllers. `openReviewPanel` / `dismissReview` /
    `openSettingsWindow` are the one entry point each.
  - `StatusMenuView` — the dropdown: status, reviewed-today, next nudge,
    Review Now, Refresh, Pause Reminders, Settings, Quit. (There is no popover;
    the review lives in the panel. `StatusPopoverView` was deleted in step 10.)
  - `SettingsView` — the preferences window (`Settings` scene): reminders form,
    deck scope, AnkiConnect endpoint. Edits `AppState` directly.
  - `ReviewPanelController` (+ `PanelAnimator`) — borderless `NSPanel`, not a
    SwiftUI scene: it must sit above the menu bar and hug the notch.
  - `ReviewPanelView`, `PanelTheme`, `CardWebView` + `MediaSchemeHandler`.
  - `NotchHotspotController` — per-screen notch hotspot; also the nudge peek
    and the acknowledgement signal.
  - `SystemPresence` (idle seconds, notch visibility), `NudgeNotifier`.

## Key decisions (from the investigation + live spike)

1. **GUI-driven review flow is primary** (`guiDeckReview → guiCurrentCard →
   guiStartCardTimer → guiShowAnswer → guiAnswerCard`). Only queue-exact path;
   only source of interval previews. `answerCards` kept as fallback only.
2. **Due count**: `getDeckStats` over top-level decks (counts include subdecks),
   sum `new + learn + review`. Refresh on menu open, after each answer, and
   on a coarse timer (≥5 min) — no tight polling.
3. **Card rendering**: WKWebView, non-persistent data store, JS enabled but no
   native bridge. Media via custom `WKURLSchemeHandler` reading from
   `getMediaDirPath` (same machine; `retrieveMediaFile` base64 as fallback).
4. **Resilience** (spike-proven): connection reset/refused ⇒ verify Anki alive,
   offer relaunch (`open -a Anki`, ~12 s to ready). `guiCurrentCard` error
   "Gui review is not currently active" + `guiReviewActive == false` ⇒ session
   finished, not an error. Strip U+2068/U+2069 from `nextReviews`.
5. **Startup handshake**: `version` (expect ≥6) then `apiReflect` to verify the
   gui actions exist; degrade to explicit "incompatible AnkiConnect" state.
6. **Tooling reality**: no Xcode on this machine (CLT only). The package builds
   with `swift build`; `MenuBarExtra` app runs via `swift run` with
   `.accessory` activation policy. `project.yml` + entitlements are committed
   for XcodeGen once Xcode is available (needed for signing/notarization,
   Info.plist `LSUIElement`, sandbox entitlements).

## MVP order (PRD) and status

_Last updated: 2026-09-03._

1. Menu bar shell — **done**
2. AnkiConnect client (+ mock) — **done**
3. Connection-status UI — **done**
4. Due-card count — **done**
5. Fetch one reviewable card (ReviewSession + guiDeckReview) — **done**
6. Question rendering (WKWebView + media handler) — **done**
7. Answer rendering — **done**
8. Rating submission (+ duplicate-answer guard) — **done** (session + popover
   buttons with interval previews; UI shell only, card body still plain text)
9. Next-card flow / finished state — **done** (sequential top-level decks,
   finished/failed states)
10. Review-window redesign (added 2026-08-28) — **done**: menu bar is a plain
    dropdown menu (status, Review Now/Continue, Refresh, Open Anki, Quit);
    the review runs in a chromeless floating `Window` scene (`.plain` style,
    `.floating` level, material background, background-draggable, Esc stops)
    placed top-center under the notch by `defaultWindowPlacement`. Needs
    macOS 15 (platform bumped from 14). `StatusPopoverView` deleted; the
    coarse refresh timer moved onto the `MenuBarExtra` label's `.task`.
11. Reminder scheduling — inactivity nudges — **done**, all rungs verified in
    a bundle (design decided 2026-08-28, see "Step 11 design"; supersedes the
    PRD's interval/smart-distribution modes)
12. Preferences window — **done** (2026-08-28, see "Current state (step 12)";
    panel position/size and configurable snooze durations deliberately dropped)
13. Tests & cleanup (parsing, connectivity failures, ease mapping,
    scheduler math, duplicate-answer prevention) — **done** (2026-09-03, see
    "Step 13 — tests & cleanup"; the staleness fixes under "Step 13 —
    staleness fixes" landed the same step)
14. Soft sessions — batch of N cards, then offer to stop (added 2026-08-29) —
    **done**, see "Step 14 — soft sessions" below
15. Panel states when Anki is closed (added 2026-09-03) — **done**, see
    "Step 15 — panel states when Anki is closed" below

## Current state (steps 1–4)

What exists and works today:

- `ReviewBarKit` library: `AnkiConnectClient` protocol,
  `AnkiConnectHTTPClient` actor (version handshake, `apiReflect` capability
  check, `getDeckStats` due counts), `MockAnkiConnectClient`, and
  `ConnectionState`. Covered by 8 passing unit tests (`make test`, no Anki
  needed).
- `ReviewBar` app: `MenuBarExtra` with due-count badge, `AppState` driving
  refresh (popover open, coarse timer), and `StatusPopoverView` showing
  connection status with an "Open Anki" button (tries bundle ids
  `net.ankiweb.anki` then legacy `net.ankiweb.dtop`).
- `Makefile` wrapping the Swift Testing framework search-path flags needed on
  a CLT-only machine; `project.yml` + entitlements ready for XcodeGen when
  Xcode is available.

## Current state (step 5, 2026-08-28)

- `ReviewSession` (@MainActor @Observable, ReviewBarKit): phases
  `idle → entering → question → answer → submitting → question | finished`,
  plus `failed(ConnectionState)`. Duplicate submissions are impossible by
  construction (`submit` only acts in `.answer`; in-flight is `.submitting`),
  eases not offered in `card.buttons` are rejected, and
  "Gui review is not currently active" maps to deck-drained, not error.
- "All decks" decision resolved as planned: the session holds a queue of
  top-level decks and runs `guiDeckReview` on each in sequence, skipping
  empty ones.
- App wiring: `Review Now` in the popover starts the session;
  `ReviewPanelView` shows deck name, card text (plain-text placeholder until
  step 6), Show Answer, and rating buttons with `displayIntervals` previews;
  due count refreshes after each answer. Review UI lives in the popover (MVP
  decision).
- 6 new unit tests (14 total) including a per-deck `MultiDeckClient` double
  for the deck-iteration path.

## Current state (steps 6–7, 2026-08-28)

- `CardWebView` (app): WKWebView, non-persistent store, JS on, no bridge.
  Card sides wrapped via `AnkiMedia.documentHTML` (note CSS +
  `color-scheme: light dark`); external links open in the browser, all other
  navigation cancelled.
- `MediaSchemeHandler` serves `anki-media://collection/<name>` from
  `getMediaDirPath`; `AnkiMedia.fileURL` (ReviewBarKit, unit-tested) rejects
  anything but a single plain path component. Card HTML loads with
  `anki-media://collection/` as base URL so relative `src`s route to it.
- Rendering fidelity (found against the live collection's Kiku note type):
  the document reproduces Anki's reviewer DOM exactly — card HTML inside
  `<div id="qa">` as a direct child of `<body class="card isMac">` — because
  note-type CSS matches on that shape (e.g. `.card:has(> #qa)`). Dark themes
  key off Anki's `nightMode`/`night_mode` body classes, mirrored from the
  system color scheme by an injected script.
- The popover sizes itself to the card: a `ResizeObserver` posts
  `body.scrollHeight` through a one-way `cardHeight` message handler (the
  sole, documented exception to "no native bridge"), clamped between 120 pt
  and screen height − 220 pt; panel width 400 pt. Each side is sized
  independently — no per-card stickiness (tried; back is always taller than
  front, so it never helped).
- Controls sit ABOVE the card in a fixed-height (40 pt) band under the deck
  header: the popover hangs from the menu bar, so Show Answer and the rating
  buttons occupy the same screen position regardless of card resizing —
  reveal and rate without moving the mouse.
- Media handler speaks real HTTP: `HTTPURLResponse` with 200/404/206,
  Content-Type/Length, `Accept-Ranges` + Range support, and CORS headers.
  Card scripts read responses via fetch/XHR — a status-less `URLResponse`
  surfaces to JS as "HTTP 0" and breaks them (found via the Kiku WaniKani
  plugin fetching `_kiku-plugin-wanikani.json`).
- Audio: AnkiConnect returns rendered HTML with raw AV markers
  (`[anki:play:a:0]`) — Anki's own GUI normally swaps these for native replay
  buttons. `AVTagRestorer` (ReviewBarKit) replaces each marker with an
  Anki-shaped `<a class="replay-button">` anchor embedding an `<audio>`
  element, resolving files from `guiCurrentCard`'s `fields` (preferring an
  enclosing `<template data-field>` wrapper, falling back to field order).
  Plain `[sound:…]` text is NOT enough: Kiku's root-card path never parses
  it — it scans field content for anchor/audio elements and clicks/plays
  them (verified live against the real collection via a localhost replica of
  the card document; both floating buttons render and play with this markup).
  `mediaTypesRequiringUserActionForPlayback = []` so scripted playback works.
- Not yet handled: the base64 `retrieveMediaFile` fallback for sandboxed
  builds. 25 tests passing.

All of the above is user-validated against the live collection (Kiku note
type: theme, kanji hover, WaniKani plugin, both audio buttons playing).

## Next steps

1. ~~**Step 13 — tests & cleanup**~~ — done 2026-09-03, see "Step 13 — tests &
   cleanup" below. Both of its trailing TODOs are now closed rather than
   deferred:
   - **Audio double-play: not happening.** Verified by use against the live
     collection — Anki's own reviewer doesn't re-announce the card we drive it
     to, and nothing in our code autoplays (`AVTagRestorer` emits replay
     buttons; only card scripts start playback).
   - **`retrieveMediaFile` base64 fallback: dropped**, not deferred (decided
     2026-09-03). It only ever existed to make a sandboxed Mac App Store build
     possible, and the App Store is not a target. It is also strictly worse
     where it would be used: base64 over the AnkiConnect HTTP API, one whole
     file per request with no Range support, so seeking and large audio/video
     break — the reason `MediaSchemeHandler` speaks real HTTP in the first
     place. Reinstating it means reinstating the sandbox *and* the range
     handling; see the sandbox decision under Risks.
2. **Packaging** (post-MVP). Already done: XcodeGen spec matching the two
   modules, `LSUIElement`, no sandbox, `ENABLE_HARDENED_RUNTIME`, ReviewBarKit
   as a static library, and `make bundle` / `make install-dev`. Still needed:
   Apple Developer Program membership, a Developer ID Application certificate,
   a **Release** configuration (Debug carries `get-task-allow`, which
   notarization rejects), `notarytool submit` + `stapler staple`, and the
   Sparkle-or-manual updates decision.

## Step 11 design — review reminders (decided 2026-08-28)

**This supersedes the PRD's "Review reminders / distribution" interval mode and
its "Smart distribution" section (PRD lines 389–457).** Smart distribution is
dropped, not deferred: pacing off the due count was the most complex and most
annoying part of the plan, and the model below replaces it.

### Core rule

Nudge on **inactivity, not on backlog**: "you haven't reviewed in an interval
(default 1 h) and there is something to review." Never "N cards due over M
hours, therefore every M/N minutes." The due count is a *gate*, never a pacing
input — it is a daily-rollover artifact that spikes after a break, exactly when
pacing off it nags hardest.

### The heartbeat: reviewed-today counter, not a timestamp

`getNumCardsReviewedToday` — one cheap call, already on the existing refresh
cadence. Each tick, compare against the previously observed value; an increase
means "a review happened" and resets the clock. Resolution equals the tick
interval, irrelevant at hour scale.

Two reasons this beats a local "last time you used ReviewBar" timer:

- It counts reviews done **inside Anki itself**, so the app never nudges while
  the user is already reviewing.
- It survives relaunch without persisting a timestamp we could get wrong.

Do **not** use `getLatestReviewID` for this (verified 2026-08-28 — see the
findings doc): it is per-deck and excludes subdecks, returning 0 for every
top-level deck in the live collection. A global last-review time via that
action means iterating every deck.

A counter *decrease* means Anki's day rolled over (04:00 by default), not
activity. At the start of a day there is no last-review time: start the clock
at the beginning of the active window, so the first nudge lands an hour into
the user's day rather than at 04:00.

### What resets the clock

**Any single answered card buys the full interval.** One card = an hour of
peace. This is the load-bearing decision for "little by little": if complying
with a nudge costs a whole session rather than one card, nudges become
negotiations and get dismissed.

A **soft session size** (default ~10 cards, then the panel closes itself) is a
drift target, not a reset requirement. ~10 fits the observed collection
(~120 reviews/day over a ~12 h window, hourly nudges).

### The gate

`dueTotal > 0` is too naive: answering anything "Again" leaves a learning card
due in <10 min, so the user is never at zero and an hour later gets nudged over
a single learning step. **Gate on `new + review`, ignoring `learn`** — "caught
up" should mean "nothing new waiting," not "no learning steps pending."

### Nudge ladder (revised 2026-08-28 after seeing it run)

Not a time-based escalation. **Exactly one rung fires per cycle, chosen by
whether the notch can be seen.**

1. **Passive** — menu bar badge state. Always on; zero interruption.
2. **Notch peek** — the hotspot pokes out with the due count and **stays out
   until acknowledged** (hover, or opening the review). Not a 3-second
   animation: a peek you have to be looking at for three seconds isn't a
   reminder. Visibility is *derived* from the outstanding nudge
   (`ActiveNudge.isLive`), never a timer, so it retracts on acknowledgement,
   review, snooze or lifetime end without anything remembering to retract it.
3. **Notification** — when the notch **can't be seen** (fullscreen app or
   auto-hidden menu bar). Not "the peek was ignored": the hotspot joins every
   Space, so other Spaces were never a gap, and once a pill with the due count
   is sitting on screen, notifying anyway is nagging someone who has a visible
   reminder in front of them.
4. **Auto-open the panel** — opt-in; also yields to a hidden notch.

Time-based escalation (`escalationDelay`, `NudgeWaitReason.escalation`, the
rung-upgrade path in `recordNudge`) was **removed**, not deferred. Persistence
made it redundant, and it was the one part of the ladder that could nag.

Self-limiting falls out of existing rules: a nudge lives one interval, so an
unanswered pill is replaced seamlessly by the next cycle's; after two ignored
cycles backoff goes silent until a review or the day rollover. Worst case the
pill is out for about three cycles in a day, not permanently.

### Acting on a nudge (decided: configurable, default straight onto a card)

Two independent axes — don't conflate them:

- **Does the panel open by itself?** No by default; the peek is passive and
  clicking it opens the panel, which is what `NotchHotspotController` →
  `toggleReviewFromNotch` already does. Auto-open is ladder step 4, opt-in.
- **When the panel does open from a nudge, what's in it?** Default: **a live
  card**, review state already entered — lowest friction, the point of the app.
  Configurable to a "reviews waiting" state that doesn't enter review state
  until the user asks, for users who don't want Anki put into review state on a
  timer.

### Snooze, dismiss, backoff

- Snooze 10 / 30 / 60 min, plus **"not today"** — the valve that stops someone
  quitting the app on a bad day. Also expose pause in the menu, so it doesn't
  require opening prefs.
- An **ignored nudge is an implicit snooze of one interval** — it must not
  re-fire immediately.
- **A nudge lives for one interval** — the span the pill stays out, and the
  bound that stops a stale nudge being treated as current. Past it the nudge is
  history and the next cycle, with backoff, takes over.
- **Back off on repeated ignores**: 1 h → 2 h → silent until a review happens
  or the day rolls over. A nudger that gets quieter when ignored is the
  difference between a tool and an irritant. Any answered card resets backoff.
- Snoozing is app-level only and never touches card scheduling (PRD).

### Don't nudge into the void

- **User away from keyboard**: `CGEventSourceSecondsSinceLastEventType` (public
  API) gives system idle time. Idle beyond a threshold (default ~20 min) holds
  the nudge until shortly after they return. This single rule buys most of the
  "feels smart" for almost no logic.
- **Screen locked / screen saver** (`com.apple.screenIsLocked` distributed
  notification) — hold.
- **Fullscreen app** — passive/notification at most, never auto-open.
- Do Not Disturb / Focus has no public API: don't detect it. Notifications go
  through `UNUserNotificationCenter`, which respects it already.

### Shape of the code

`ReminderScheduler` stays a **pure decision function** — no timer, no stored
state:

    static func plan(settings:, state:, now:, calendar:) -> ReminderPlan

`state` carries the observed reviewed-today counter and when it was observed,
snooze/backoff state, gate counts, panel visibility, and system idle seconds.
Every rule above becomes a table-driven test with a fixed `now`. Rendering
`plan()` as the menu's "next nudge" line doubles as the development debugger.

**One clock only.** Extend the existing tick loop on the `MenuBarExtra` label's
`.task`; do not add a second timer. Never trust the sleep duration — tick
coarsely (30–60 s) and recompute from `Date()`, which is what makes this correct
across system sleep/wake, clock changes and DST. Tick immediately on
`NSWorkspace.didWakeNotification`. Re-plan on tick, refresh, session end,
settings change, and snooze.

### Configuration (defaults now, UI in step 12)

Interval; active window / quiet hours; snooze backoff on/off; soft session size; gate mode (ignore learning cards);
idle threshold; deck scope; whether a nudge opens a card or just announces.
Ship step 11 with defaults behind plain `UserDefaults` keys and no UI — step 12
then becomes a form over already-working behavior.

Also worth surfacing, cheap once the counter is polled: **"N reviewed today"**
in the menu (PRD asks for lightweight daily stats).

## Current state (step 11, 2026-08-28)

Pure layer and app wiring done; no preferences UI yet (step 12).

- `ReminderScheduler.plan(settings:state:now:calendar:)` (ReviewBarKit) — the
  whole decision as one pure function returning
  `.nudge(rung) / .wait(until:reason:) / .idle(reason)`. Precedence: disabled →
  panel open → caught up → snoozed → backed off → outside window → away/locked
  → escalation → interval. No timer, no clock, no system APIs.
- `ReminderSettings` (Codable, every key optional on decode so adding a setting
  later doesn't invalidate a stored blob), `ReminderState` with the lifecycle
  transitions (`recordReview`, `recordNudge`, `acknowledgeNudge`, `snooze`),
  `TimeOfDay`, `DueBreakdown` + `DueCount.breakdown(from:)`.
- Defaults: 1 h interval, 4 min peek→notify escalation, 20 min idle threshold,
  09:00–21:00 window, 04:00 rollover, learn-cards ignored by the gate, backoff
  on, auto-open off, nudge lands on a card.
- 29 new tests (61 total, all passing) covering each gate, interval anchoring,
  the no-review-yet window-open fallback, presence holds, midnight-wrapping
  windows, snooze, peek→notify escalation and the stale-peek bound, rung
  selection under fullscreen, both backoff steps, the transitions, and partial
  settings decode.

App wiring:

- `AnkiConnectClient.numCardsReviewedToday()` (`getNumCardsReviewedToday`) —
  added to the protocol, HTTP client, mock (returns `answered.count`) and the
  `MultiDeckClient` test double.
- `AppState.tick()` — **one clock**, owned by the `MenuBarExtra` label's
  `.task`. Ticks every 30 s (cheap and local: presence, escalation, re-plan)
  and only asks Anki anything every 300 s. Never trusts the sleep duration.
  `observeSystemState()` adds screen lock/unlock and `didWakeNotification`,
  which feed the same tick rather than a second timer.
- `observeReviewCounter` — increase ⇒ `recordReview`; decrease ⇒
  `recordDayRollover`. On the *first* reading we know whether the user reviewed
  today but not when, so a nonzero count anchors to now — otherwise launching
  mid-afternoon nudges instantly. A 2-minute startup grace (as a snooze)
  prevents nudging into a login storm.
- `SystemPresence` — idle seconds via `CGEventSource.secondsSinceLastEventType`
  (minimum over input event types: `CGEventType` is a Swift enum, so the C
  `kCGAnyInputEventType` (~0) idiom isn't expressible), plus a fullscreen
  heuristic reusing `PanelGeometry.menuBarHeight == 0`.
- `NudgeNotifier` — authorization requested on first use only, never re-asked
  when denied; default interruption level so DND/Focus suppress it; tapping
  opens the review. **Guarded by `Bundle.main.bundleIdentifier != nil`:**
  `UNUserNotificationCenter.current()` traps in a process with no app bundle,
  which is exactly how `swift run` launches us — so the notify rung is inert in
  dev builds and needs the XcodeGen bundle to verify.
- Notch hotspot — a nudge reuses the hover animation (`hovering ||
  state.isPeeking`) and stays out until hovered; hovering calls
  `acknowledgeNudge()`. Opening the panel from any entry point acknowledges too.
  Verified visually: the pill sits at top-centre of an external display with the
  due count on it, still there 12 s later.
- Menu — "N reviewed today", the decision rendered as "Next nudge 5:30 PM" /
  "Snoozed until…" / "Paused until…" (also the quickest way to eyeball the
  scheduler), and a "Pause Reminders" submenu (10/30/60 min, Until tomorrow).
- `ReminderSettings` persisted as JSON in `UserDefaults` under
  `reminderSettings`.

Verified live (2026-08-28) through the real Swift client, not just curl:
`reviewedToday=15`, due total 37, and a 4000 s-old last review yields
`.nudge(.peek)`. The app launches and ticks without crashing under
`swift run`.

Dev overrides, because a feature on hour timescales (and one rung reachable
only from a fullscreen app) is otherwise unobservable:
`REVIEWBAR_STARTUP_GRACE`, `REVIEWBAR_NUDGE_INTERVAL`,
`REVIEWBAR_FORCE_NOTCH_HIDDEN`, `REVIEWBAR_AUTO_OPEN` (the `.openPanel` rung,
otherwise reachable only by opting in). E.g.
`REVIEWBAR_STARTUP_GRACE=2 REVIEWBAR_NUDGE_INTERVAL=20 make run`.
Step 12 adds `REVIEWBAR_OPEN_SETTINGS`.

Notification rung verified 2026-08-28 in a real bundle (Xcode now installed):
`authorized=true`, `delivered=1`. Getting there needed two fixes worth knowing:

- **`project.yml` was wrong** — it compiled `Sources/ReviewBar` *and*
  `Sources/ReviewBarKit` into one app target, so `import ReviewBarKit` couldn't
  resolve; and its test target depended on the app rather than the library. It
  had never been validated because the machine had no Xcode. Now ReviewBarKit is
  its own framework target (with `GENERATE_INFOPLIST_FILE`, or it can't be
  signed) and the app depends on it.
- **A bundle isn't enough — Launch Services has to know it.** Running the
  binary out of the build directory fails with `UNErrorDomain` code 1,
  "Notifications are not allowed for this application", even though
  `Bundle.main.bundleIdentifier` is set. `make install-dev` copies to
  `~/Applications` and `lsregister -f`s it, after which authorization
  succeeds. `NudgeNotifier` now logs authorization/post failures via `os.Logger`
  rather than swallowing them with `try?` — that silent failure cost a debug
  cycle.

Bare `swift test` works now that Xcode is installed, so the Makefile's
Swift-Testing search-path flags are gone.

Tap-to-open verified 2026-08-28 — after fixing a bug it exposed: `notifier` was
`lazy`, so the `UNUserNotificationCenter` delegate was only registered on the
first *post*. Tapping a notification can **launch** the app, and on that launch
nothing posted, so no delegate existed and the response was silently dropped.
Startup is now consolidated into `AppState.start()` (hotspot + observers +
delegate registration), called from the app's `.task`. Registering a delegate
does not request authorization, so it stays quiet until a nudge needs it.

**The sandbox entitlement breaks card media in the bundle.** Measured with the
same code, same card, on 2026-08-28:

| Build | `_kiku.js` |
| --- | --- |
| Sandboxed bundle (`make install-dev`) | read FAILED — "you don't have permission to view it" |
| Unsandboxed (`swift run`) | read ok, 40358 B |

Anki's `collection.media` lives in `~/Library/Application Support/Anki2/…`,
which an app-sandboxed process can't read, so every media request 404s and note
types that load scripts (Kiku) render an error card instead. **Resolved the same day: the sandbox is dropped**, targeting direct
distribution (Developer ID + notarization), which does not require it. A Mac App
Store build would, and would need the `retrieveMediaFile` base64 fallback first —
that fallback stays on the list as the bridge, so this isn't a one-way door.

`ENABLE_HARDENED_RUNTIME` added at the same time: notarization requires it, and
unlike the sandbox it doesn't restrict reading user files or localhost traffic.
Two things that cost a build each:

- **Hardened runtime turns on library validation**, so the ad-hoc signed
  ReviewBarKit.framework failed to load: "mapping process and mapped file
  (non-platform) have different Team IDs". ReviewBarKit is now
  `type: library.static` — nothing to load at runtime, no Team ID to match,
  leaner bundle, and it matches how SwiftPM builds it. (Signing both with one
  real Developer ID would also fix it; static fixes it for dev builds too.)
- **Debug builds carry `com.apple.security.get-task-allow`**, which
  notarization rejects. Notarized builds must be Release — `make bundle` is
  Debug, for local use only.

Verified in the resulting bundle (own TCC identity, not the terminal's):
24 media reads, 0 failures, including `_kiku.js`. No permission prompt, so
`~/Library/Application Support/Anki2` is not TCC-protected for an unsandboxed app.

Not yet done: preferences UI (step 12).

## Current state (step 12, 2026-08-28)

Preferences window done: a SwiftUI `Settings` scene (`SettingsView`), two tabs,
both editing `AppState` directly — its `didSet`s persist and re-plan, so there
is no Apply button and no second copy of settings to drift.

- **Reminders tab** — the form over `ReminderSettings`: on/off, interval and
  idle-threshold pickers (preset lists that always include the stored value, so
  a value set by an env override or old blob still renders), active window as
  two hour/minute `DatePicker`s over `TimeOfDay`, backoff, gate mode (stated
  positively as "count learning steps as waiting"), auto-open, what a nudge
  opens onto, and Anki's day-rollover hour.
- **Review tab** — deck scope and connection:
  - `reviewDeckScope: Set<String>` (`UserDefaults` key `reviewDecks`, empty =
    all decks). `DueCount.scoped(_:to:)` (ReviewBarKit, tested) applies it to
    **both** `startReview` and the due-count refresh, so the badge, the nudge
    gate and Review Now all see the same world — nudging over decks the user
    excluded would be wrong. A scope matching nothing (decks renamed/deleted)
    falls back to all decks rather than silently going quiet forever; stale
    scoped names still show in the list so they can be unchecked. Turning off
    "All decks" starts from everything checked.
  - AnkiConnect endpoint (`UserDefaults` key `ankiConnectEndpoint`): a text
    field committing on Return, validated by
    `AnkiConnectHTTPClient.endpoint(from:)` (http(s) + host, tested); invalid
    drafts never leave the field. Applied to the **live** client via a new
    `setEndpoint` actor method — the session holds the client for the app's
    lifetime, so rebuilding it was not an option.

**Layout: two columns, and every tab fits without scrolling.** The first cut
used `.formStyle(.grouped)`, whose card padding pushed the Reminders tab past
the window height — a preference pane you have to scroll to see is one where
settings go unfound. Each tab is now a `Grid` with a trailing label column
(the classic macOS shape), related settings collapsed onto one line each
("09:00 to 21:00", "Hold nudges after · 20 minutes", the three nudge toggles
under one label), and section footers demoted to captions under the control
they explain. The deck list scrolls internally past ~180 pt so a large
collection can't stretch the window instead.

**Opening it: one path, `AppState.openSettingsWindow()`.** The menu item and
the review panel's ⌘, both call it. Two things it has to do that aren't
obvious:

- **Activate first.** `.accessory` apps don't come forward on their own, so
  the window would open behind whatever is frontmost.
- **Go through SwiftUI's `openSettings` environment action.** The review panel
  is an AppKit `NSPanel`, which can't reach the environment; sending
  `showSettingsWindow:` up the responder chain from there was tried and is a
  no-op in this app (verified — that was the first attempt at ⌘, and it
  silently did nothing). Instead the `MenuBarExtra` label — the app's one
  always-alive SwiftUI view, which already owns the clock — captures the
  action into `AppState.openSettingsAction` at launch. The panel handles ⌘,
  in `performKeyEquivalent`, because the status menu's own ⌘, item only fires
  while that menu is open.

**Clicking the notch again closes the review.** `toggleReviewFromNotch` always
had the toggle, but an open panel physically covers the hotspot window, so the
second click never arrived. `PanelContainerView` now carries its own
click target over the notch band (notch width + ear flare, only while
expanded) calling `dismissReview()`. That band holds no other controls — card
content is padded below it — so nothing else can swallow the click.
`dismissReview()` is also where the three copies of "stop session + hide panel
+ finish" (close button/Esc, notch toggle, notch band) were consolidated.

**`refresh()` coalesces rather than merely guarding re-entry.** A refresh asked
for while one is in flight now runs again afterwards instead of returning
early. The settings paths need it: an in-flight refresh is answering the
*previous* deck scope or endpoint and has already stamped `lastRefreshAt`, so
dropping the new one would leave the badge stale for another 300 s.

Dev override, since the window is two clicks deep in the menu bar and so
unobservable from a script: `REVIEWBAR_OPEN_SETTINGS=1` opens it at launch.
That plus `screencapture -l<windowID>` is how the layout above was checked.

Deliberately dropped from the step-12 list:

- **Panel position/size** — the panel is notch-anchored and sizes itself to
  the card by design; a position setting would contradict both.
- **Configurable snooze durations** — the 10/30/60/tomorrow menu presets are
  the feature; a knob over them is preference-pane clutter.
- **Soft session size** — the panel doesn't auto-close after N cards yet, and
  a setting over unbuilt behavior is a lie; add both together if ever.

65 tests passing (4 new: deck scoping incl. the empty/stale fallbacks, and
endpoint parsing). Verified: `make build`, `make test`, `make bundle`, a
`swift run` smoke test, and both tabs screenshotted — including the deck list
against the live collection.

## Step 13 — staleness fixes (2026-08-29)

Two bugs found reviewing step 12, both "the menu shows something that stopped
being true". Neither was in the plan; both were doc/code drift.

**The due count didn't refresh when the menu opened**, despite key decision 2
and CLAUDE.md both claiming it did. The refresh hung off the *popover*, which
step 10 deleted, and nothing replaced it — so the number you open the menu to
read could be up to 300 s old. Fixed with an
`NSMenu.didBeginTrackingNotification` observer feeding the existing `refresh()`
(`MenuBarExtra` exposes neither its status item nor its menu, and `onAppear`
inside `.menu`-style content isn't reliably per-open). Verified the mechanism
in isolation: a scratch `NSMenu.popUp` fires the notification, observer
identifies the menu.

**"Open Anki" didn't check whether Anki came back.** It launched and returned;
the spike measured ~10–15 s to ready, and with the coarse refresh 300 s away
the menu kept saying "Anki isn't available" long after it was. That's the
"verify" half of the recovery path CLAUDE.md describes, which had never been
built. `AppState.relaunchAnki()` now polls every 2 s for ~40 s, `isLaunchingAnki`
shows "Starting Anki…" in the menu meanwhile, and a launch that fails outright
logs and stops rather than watching for 40 s. `openAnki` moved out of
`StatusMenuView` into `AppState` so the polling lives with the state it updates.

Also fixed while reviewing step 12: `refresh()` now coalesces instead of
dropping a refresh requested mid-flight (see the step 12 section).

## Step 13 — tests & cleanup (2026-09-03)

The two subtlest pieces of untested logic moved into ReviewBarKit, where they
are table-tested; there is no test target for the app layer, by design. 97
tests passing (15 new).

**The reviewed-today heartbeat is now `ReviewCounterMonitor`.** It compares
successive `getNumCardsReviewedToday` readings and folds the result into
`ReminderState`: first reading (whether, not when — a reviewed day is assumed
recent so launching mid-afternoon doesn't nudge on the first tick), increase =
`recordReview`, decrease = `recordDayRollover`, unchanged = nothing.
`AppState.observeReviewCounter` is now three lines that supply the reading and
the clock, and `reviewedToday` is derived from the monitor rather than stored
twice.

**Ease mapping no longer reads labels off the ease number.** Anki labels rating
buttons by *position* (`aqt.reviewer._answerButtonList`, confirmed against the
installed 25.x build): four buttons are Again/Hard/Good/Easy, but three are
Again/**Good**/Easy — so on a three-button card ease 2 means Good and ease 3
means Easy. The old panel filtered `Ease.allCases` by `card.buttons`, which drew
a *Hard* button that graded Good, coloured it orange, and paired it with Good's
interval preview. `CurrentCard.answerButtons` now returns `AnswerButton`s
carrying the ease to submit plus the `meaning` whose name and tint the button
wears, with `nextReviews` read positionally; the panel renders straight off it,
and the interval lookup that lived in the view is gone.

**Keyboard ratings resolve by name, not by number.** Shortcuts are configured
per rating name, so `ReviewSession.submit(rating:)` looks the name up through
`card.answerButton(labelled:)` — the "Good" key answers ease 2 on a
three-button card, and "Hard", which such a card doesn't offer, is a no-op
instead of grading Good. `submit(ease:)` is unchanged and still the authority
for what the card actually offers.

## Step 14 — soft sessions (2026-08-29)

"Ten cards, then stop" — a local budget on one sitting, so the day's reviews
spread out instead of front-loading into one long session. Anki still owns the
queue; nothing here schedules anything.

**Pausing means not fetching.** `ReviewSession.submit` counts the answer and, on
reaching the batch size, goes to `.batchComplete(answered:)` *before* the next
`guiCurrentCard`/`guiStartCardTimer`. Fetching one more card would start its
timer and strand it unanswered in the reviewer. Anki's review state is left
standing, so `continueBatch()` resumes with a plain card fetch — the same call
the normal flow makes — and a deck that drained meanwhile falls through to the
next deck or `.finished` exactly as anywhere else.

**Re-entry resumes rather than restarts.** `start(decks:cardLimit:)` refuses to
run from `.batchComplete` (it would re-enter `guiDeckReview` and re-gather), so
`AppState.startReview()` routes there to `continueBatch()`. Menu item, notch
click and nudge all go through `startReview()`, so all three continue.

**The batch screen is an offer, not a wall**: Continue / Done, plus a countdown
that folds the panel away on its own (`SessionSettings.autoCloseDelay`, default
10 s; "when I say so" = 0). The countdown rides the **Done** button — it is
Done that it performs — never Continue. It runs to a `Date` deadline recomputed
from the clock and refreshed 5×/s, not counted down by 1 s sleeps: App Nap
coalesces timers in a background app, and a label built out of sleep durations
skips numbers when one runs long. The same countdown runs on the "all caught up"
screen, which used to sit open until dismissed — both are states with nothing
left to decide. `.failed` is excluded: an unread error must wait for the user.
The countdown is view-local `@State` cancelled by `.task` teardown —
deliberately not a second app clock. The reveal key doubles as Continue in
`AppState.handleReviewKey`, since that's the key the hand is on.

**Why this pairs with nudges**: finishing a batch records a review, which resets
the inactivity clock, so the remaining cards come back one interval later. That
loop — short batch, quiet hour, short batch — is the spreading mechanism. It is
*not* backlog pacing ("48 cards ÷ 8 hours"), which step 11 explicitly dropped.

Configurable on the Review tab (`SessionSettings`, stored under
`sessionSettings`, same optional-key decoding as `ReminderSettings`). Dev
overrides: `REVIEWBAR_BATCH_CARDS`, `REVIEWBAR_BATCH_AUTOCLOSE`.

## Step 15 — panel states when Anki is closed (2026-09-03)

Found in use, and a shipping blocker: **clicking the notch with Anki closed
spun the panel forever.** `AppState.startReview()` caught the failure into
`connection` but left `ReviewSession` at `.idle`, and the panel renders `.idle`
and `.entering` identically as "Starting review…". The menu was fine — it
disables Review Now when disconnected — so the notch, which is a one-click
entry point with no menu behind it, was the only way in.

- `ReviewSession.fail(with:)` lets the app report a *pre-flight* failure (it
  couldn't even get the deck list), so the panel lands on `.failed` instead of
  a spinner nothing will resolve.
- The panel's failure state now carries the recovery action, not just the
  diagnosis: **Open Anki** when the state is `.unreachable` and Anki is
  installed, which runs `AppState.openAnkiAndReview()` — the existing ~40 s
  relaunch poll, then the review the user originally asked for — and shows
  "Starting Anki…" meanwhile. Anything else (bad endpoint, unsupported
  AnkiConnect) gets **Try Again**.
- `.idle` is no longer a spinner either. It renders the **passive "reviews
  waiting" state** the step 11 design called for and nobody had built:
  due count, Review Now, Later. That is what a nudge with
  `nudgeOpensOntoCard == false` opens onto.
- `AppState.isStartingReview` covers the gap between "review asked for" and
  `ReviewSession` reaching `.entering`: the deck-list fetch is the call that
  fails when Anki is closed, and without the flag a slow endpoint would show a
  Review Now offer over a request already in flight.
- Dev hook, since these states are otherwise only reachable by clicking the
  notch: `REVIEWBAR_OPEN_REVIEW=1` (opens onto a card) and
  `REVIEWBAR_OPEN_REVIEW=idle` (opens without asking Anki anything). Both
  states screenshotted — the unreachable one against a dead endpoint, so the
  live collection was never involved.

## Risks

- App Nap freezing backgrounded Anki (README-documented AnkiConnect issue) —
  mitigate with request timeouts + stall detection + setup help.
- Anki process death mid-session (observed once in spike) — recovery path above.
- ~~Sandbox vs. reading `collection.media` directly~~ — resolved 2026-08-28:
  sandbox dropped, direct distribution. Mac App Store would need the
  `retrieveMediaFile` base64 fallback.
- `guiDeckReview` takes one deck; "all decks" needs a decision (review each
  top-level deck in sequence for MVP).
