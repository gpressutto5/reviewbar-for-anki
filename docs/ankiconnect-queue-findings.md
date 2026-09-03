# AnkiConnect queue-fidelity investigation

**Date:** 2026-08-28. Verified against current AnkiConnect master (API version 6) at
https://git.sr.ht/~foosoft/anki-connect (the GitHub repo `FooSoft/anki-connect` was
archived 2025-11-04 and redirects there; the foosoft.net project page is gone).

## Headline question

> Does AnkiConnect give us everything needed to reproduce the normal reviewer
> queue exactly?

**No — not headlessly.** AnkiConnect exposes **no non-GUI action wrapping the v3
scheduler's `get_queued_cards()`** (confirmed by inspecting `plugin/__init__.py`
in current source; the community has flagged the same gap in
[ankimcp/anki-mcp-server-addon#2](https://github.com/ankimcp/anki-mcp-server-addon/issues/2)).
The only queue-exact path is driving Anki's real reviewer via the `gui*` actions.

## The two possible architectures

### A. GUI-driven flow (queue-exact) — recommended primary path

Drive `mw.reviewer` remotely. This *is* Anki's reviewer, so card selection,
counts, burying, learning-step timing, button set, and interval previews are all
exact by construction.

1. `guiDeckReview {name}` — enter review state for a deck.
2. `guiReviewActive` — poll/verify review state (other `gui*` calls error otherwise).
3. `guiCurrentCard` — returns `cardId`, rendered `question`/`answer` HTML, `css`,
   `buttons` (e.g. `[1,2,3]`), and `nextReviews` (e.g. `["<1m","<10m","4d"]`).
4. `guiStartCardTimer` — call when *our* UI shows the card so answer time is logged correctly.
5. `guiShowAnswer` — required before answering (`guiAnswerCard` refuses unless
   the reviewer is in the `answer` state).
6. `guiAnswerCard {ease: 1..4}` — same code path as clicking the button in Anki.
7. `guiUndo` — undo last answer.

**Constraints / implications:**
- Anki's main window must be in review state. It can sit in the background, but
  a "review session" exists inside Anki while we review.
- **macOS App Nap:** when Anki is backgrounded, App Nap can freeze it and
  AnkiConnect stops responding (documented in the AnkiConnect README). We must
  handle this (detect stalls; document the App Nap workaround for users).
- Entering `guiDeckReview` changes what the user sees if they switch to Anki
  mid-session — acceptable, but worth handling gracefully.
- Deck scoping is per-deck (`guiDeckReview` takes one deck name); "all decks"
  means reviewing the top-level/Default hierarchy or iterating decks.

### B. Headless flow (`findCards` + `answerCards`) — approximate selection, exact grading

- `answerCards {answers:[{cardId, ease}]}` **does** go through the real Rust
  backend scheduler: FSRS, learning steps, fuzz, day cutoff, and sibling
  burying at answer time are all correct. Grading is safe.
- But **selection diverges** from the real reviewer: `findCards("is:due")`
  misses new cards, ignores gather/sort order and new/review interleaving,
  per-deck daily limits, the learn-ahead limit for sub-day learning cards, and
  already-buried siblings. It returns DB order, not queue order.
- Known wart: `answerCards` calls `card.start_timer()` immediately before
  answering, so revlog answer time is ~0 ms (review-time stats wrong).
- The backend will grade *any* card by ID, including cards the queue would not
  have served yet — nothing protects us from answering a not-yet-due card.

**Use B only as a fallback** (e.g. grading a specific known card), never to
build the queue.

## Other findings that shape the design

- **Rendered HTML without the GUI:** `cardsInfo {cards}` returns rendered
  `question`/`answer` HTML plus `css` for any card via Anki's real template
  renderer — headless rendering is fully supported. (In the GUI flow,
  `guiCurrentCard` already includes this.)
- **Interval previews (Again/Hard/Good/Easy labels):** only available from
  `guiCurrentCard.nextReviews`. No non-GUI action exposes them. `getIntervals`
  is *historical* revlog data, not previews — and its implementation performs a
  raw `update cards` mutation as a side effect. **Do not use `getIntervals`.**
- **Due counts:** `getDeckStats {decks}` → `new_count`, `learn_count`,
  `review_count` per deck, built on `deck_due_tree()`, so counts respect daily
  limits/burying like Anki's own deck list. Good for the menu-bar badge.
  There is no standalone `deckDueTree` action.
- **Media:** no HTTP media serving. Options: `getMediaDirPath` once + load
  media directly from disk (we're on the same machine — preferred for
  WKWebView), or `retrieveMediaFile` (base64) as fallback.
- **Version/compat:** `version` returns `6`. Use `apiReflect` at startup to
  probe which actions the installed build actually supports. Queue exactness
  assumes the v3 scheduler (default since Anki 2.1.45).

## Consequences for the PRD architecture

1. `AnkiConnectClient` should expose both flavors, but `ReviewSession` logic
   should be built on the **GUI review session** (A) as the primary mode.
2. Connection-state machine gains a state: *connected but reviewer unavailable*
   (e.g. App Nap stall, user closed the deck, dialog open in Anki).
3. "Cards becoming unavailable between fetching and answering" (PRD) maps to
   `guiCurrentCard` re-fetch before answering: compare `cardId`, and treat
   errors as session-invalidated → re-enter `guiDeckReview`.
4. Interval previews on buttons (PRD "show them where possible") are only
   possible in mode A — one more reason it's primary.
5. Snooze/distribution logic is unaffected (app-level, as specified).

## Live spike results (2026-08-28, real Anki install, API version 6)

Ran the full GUI flow against a live Anki using a throwaway deck
(`createDeck` → `addNote` → `guiDeckReview` → `guiCurrentCard` →
`guiStartCardTimer` → `guiShowAnswer` → `guiAnswerCard {ease:3}` →
`deleteDecks {cardsToo:true}`). Findings:

1. **The full flow works end-to-end.** `guiCurrentCard` returned rendered
   `question`/`answer` HTML, `css`, `buttons: [1,2,3,4]`, and
   `nextReviews: ["<1m","<16m","30m","7d"]`. `apiReflect` confirmed every
   action we need exists on the installed build. `getMediaDirPath` returned
   the collection.media path as expected.
2. **Anki died on the first `guiDeckReview` attempt.** The HTTP connection was
   reset mid-request-sequence, then refused; the main Anki process was gone
   (only orphaned mpv audio helpers remained) with **no macOS crash report**.
   Not reproducible on retry — the identical call sequence succeeded after
   relaunch. Data written before the crash (the added note) survived.
   *Implication:* the client must treat connection reset/refused as
   "Anki possibly dead", verify, and offer relaunch. `open -a Anki` +
   ~10–15 s wait restored connectivity.
3. **`nextReviews` strings contain Unicode bidi-isolate characters**
   (U+2068/U+2069) around numbers, e.g. `"⁨30⁩m"`. Strip them
   before display.
4. **End-of-queue behavior:** answering the last due card makes Anki leave
   review state; `guiCurrentCard` then errors with
   `"Gui review is not currently active."`. That error (with
   `guiReviewActive` returning false) is the session-finished signal —
   the state machine must treat it as "done / nothing more due now", not as
   a failure.
5. `getDeckStats` on nonexistent-due decks returns zeroed counts;
   works fine for the menu-bar badge (sum of `new+learn+review`).

## Review-history actions (verified live 2026-08-28, for reminder nudges)

Probed with `apiReflect` and called against the live collection. Relevant to
step 11, which nudges on **inactivity** rather than backlog (see
`implementation-plan.md`, a private working doc).

- **`getNumCardsReviewedToday`** — takes no params (passing `deck` errors), one
  cheap call, returns an `Int`. **This is the heartbeat to use**: poll it on the
  existing refresh cadence and treat an increase as "a review happened."
  Critically, it counts reviews done in Anki's own reviewer too, so the app
  never nudges while the user is already reviewing. A *decrease* means Anki's
  day rolled over (04:00 by default), not activity.
- **`getNumCardsReviewedByDay`** — `[[ "YYYY-MM-DD", count ], …]`, newest first.
  Free daily-stats source (PRD asks for lightweight stats).
- **`getLatestReviewID {deck}`** — ⚠️ **MUTATES THE COLLECTION. Do not call it.**
  Its body is `self.decks().id(deck)`, and Anki's `DeckManager.id()` *creates*
  the deck when the name doesn't exist. Probing five names that weren't decks
  created five empty decks in the live collection (2026-08-28: a shell loop
  word-split `Dokuen Japanese Reader` and `Game Gengo` on spaces, and each
  fragment became a deck — deck ids are creation timestamps in epoch-ms, which
  is how it was traced). Same footgun class as `getIntervals`: a `get*` action
  with a write side effect.
  It is also **per-deck and does NOT include subdecks**, unlike `getDeckStats`. It returned
  `0` for every top-level deck in the live collection and only produced a
  timestamp on a leaf deck (`日本語::From Bunpro` → `1784214025534`). So a global
  "last review time" via this action would mean iterating every deck — which is
  exactly the loop that created the junk decks. Use the reviewed-today counter.

**Lesson for any future probing:** treat every AnkiConnect action as potentially
mutating until its source says otherwise, run probes against a disposable
profile, and never let deck names reach a shell loop unquoted (`while IFS= read
-r`, or do the whole thing in Python).
- Also present, unused so far: `cardReviews`, `getReviewsOfCards`,
  `insertReviews`.

## Open uncertainties

- Whether undo history treats `answerCards` identically to reviewer answers.
- Behavior if `answerCards` fires while a GUI review session is open
  (backend handles queue invalidation, but the reviewer display may need a
  `guiShowQuestion` refresh).
- No known fork adds a `get_queued_cards` wrapper; if GUI-flow constraints
  prove too painful, shipping a tiny companion add-on that exposes it is the
  escape hatch.

Sources: current repo/README (sourcehut), archived GitHub repo,
ankimcp/anki-mcp-server-addon#2, Anki v3 scheduler FAQ,
`rslib/src/scheduler/answering/mod.rs`, anki.scheduler.v3 dev docs.
