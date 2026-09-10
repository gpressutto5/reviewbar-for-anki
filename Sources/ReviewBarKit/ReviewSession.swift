import Foundation
import Observation

/// Where the session is in the review flow. UI renders directly off this.
public enum ReviewPhase: Equatable, Sendable {
    case idle
    /// `guiDeckReview` in flight (or advancing to the next deck).
    case entering
    /// Front of the card is showing.
    case question(CurrentCard)
    /// Back is showing; rating buttons enabled.
    case answer(CurrentCard)
    /// `guiAnswerCard` in flight — input must stay disabled.
    case submitting(CurrentCard)
    /// The soft session's batch is spent. Cards may well remain: Anki's
    /// reviewer is left in review state, so `continueBatch()` resumes with the
    /// very next card. `answered` counts this batch, not the whole sitting.
    case batchComplete(answered: Int)
    /// Every queued deck is out of due cards.
    case finished
    case failed(ConnectionState)

    public var card: CurrentCard? {
        switch self {
        case .question(let card), .answer(let card), .submitting(let card): card
        case .idle, .entering, .batchComplete, .finished, .failed: nil
        }
    }
}

/// State machine over AnkiConnect's GUI review flow
/// (`guiDeckReview → guiCurrentCard → guiStartCardTimer → guiShowAnswer →
/// guiAnswerCard`). `guiDeckReview` takes a single deck, so the session holds
/// a deck queue and moves to the next deck when one runs dry.
@MainActor
@Observable
public final class ReviewSession {
    public private(set) var phase: ReviewPhase = .idle
    /// Cards answered since `start` — the whole sitting, across batches.
    public private(set) var answeredCount = 0
    /// An undo is in flight — `.entering` that the panel can label honestly.
    public private(set) var isUndoing = false

    private let client: any AnkiConnectClient
    private var remainingDecks: [String] = []
    /// The deck `guiDeckReview` was last entered on. Re-entering it is how
    /// Anki's reviewer is made to re-fetch after an undo, bury or suspend.
    private var activeDeck: String?
    /// Cards per batch; nil reviews until the decks run dry.
    private var batchSize: Int?
    /// `answeredCount` when the current batch began.
    private var batchStart = 0
    /// Answers Anki can still take back, most recent last. Anki's undo undoes
    /// its *latest* operation whatever that was, so this is cleared whenever
    /// the session does something else undoable-in-Anki (entering another
    /// deck, suspending) or not undoable at all (burying).
    private var undoable: [Int64] = []

    /// `guiUndo` returns before Anki has applied the undo, so the re-fetch is
    /// retried until the undone card is back — briefly, since a card that
    /// legitimately isn't first (Anki showed something else) must still land.
    private static let undoPollAttempts = 15
    private static let undoPollInterval: Duration = .milliseconds(100)

    public init(client: any AnkiConnectClient) {
        self.client = client
    }

    /// Begin reviewing the given decks in order, pausing after `cardLimit`
    /// cards (nil = until the decks run dry). Ignored mid-session; callable
    /// again from `finished`/`failed` to start over.
    ///
    /// A `.batchComplete` session is *not* restartable through here — that
    /// would re-enter `guiDeckReview` and re-gather the queue. Use
    /// `continueBatch()`, which resumes the reviewer already standing.
    public func start(decks: [String], cardLimit: Int? = nil) async {
        switch phase {
        case .idle, .finished, .failed: break
        case .entering, .question, .answer, .submitting, .batchComplete: return
        }
        answeredCount = 0
        batchSize = cardLimit
        batchStart = 0
        remainingDecks = decks
        undoable = []
        activeDeck = nil
        await advanceToNextDeck()
    }

    /// Grant another batch and show the next card. The reviewer was never
    /// left, so this is a plain `guiCurrentCard` — no deck is re-entered, and
    /// no card was gathered early and lost. If the deck drained in the
    /// meantime (finished inside Anki, say), this lands on the next deck or
    /// on `.finished`, the same as any other card fetch.
    public func continueBatch() async {
        guard case .batchComplete = phase else { return }
        batchStart = answeredCount
        phase = .entering
        await showNextCard()
    }

    /// Flip the current card. No-op outside the question phase.
    public func revealAnswer() async {
        guard case .question(let card) = phase else { return }
        do {
            try await client.showAnswer()
            phase = .answer(card)
        } catch {
            fail(error)
        }
    }

    /// Rate the current card. Only valid with the answer showing — while a
    /// submission is in flight the phase is `.submitting`, so double-clicks
    /// and repeated key presses fall through here harmlessly.
    public func submit(ease: Ease) async {
        guard case .answer(let card) = phase, card.buttons.contains(ease.rawValue) else { return }
        phase = .submitting(card)
        do {
            try await client.answerCurrentCard(ease: ease)
            answeredCount += 1
            undoable.append(card.cardId)
            if let batchSize, answeredCount - batchStart >= batchSize {
                // Stop *before* fetching: an un-shown card fetched here would
                // have its timer started and sit in the reviewer unanswered.
                phase = .batchComplete(answered: answeredCount - batchStart)
                return
            }
            await showNextCard()
        } catch {
            if (error as? AnkiConnectError)?.isReviewInactive == true {
                // Reviewer closed under us (deck drained between fetch and
                // answer, or the user finished in Anki itself).
                await advanceToNextDeck()
            } else {
                fail(error)
            }
        }
    }

    /// Rate the current card by the *name* on its button (Again, Good…),
    /// which is how keyboard shortcuts are configured. On a three-button card
    /// the ease behind a name shifts — see `CurrentCard.answerButtons` — so a
    /// name that card doesn't offer is a no-op rather than a mis-grade.
    public func submit(rating: Ease) async {
        guard case .answer(let card) = phase,
              let button = card.answerButton(labelled: rating) else { return }
        await submit(ease: button.ease)
    }

    // MARK: Undo

    /// Whether `undo()` has an answer to take back right now. False while a
    /// request is in flight, and false for answers given before the session
    /// moved on to another deck (see `undoable`).
    public var canUndo: Bool {
        guard !undoable.isEmpty else { return false }
        switch phase {
        case .question, .answer, .batchComplete, .finished: return true
        case .idle, .entering, .submitting, .failed: return false
        }
    }

    /// Take back the last answer, like Anki's Edit ▸ Undo: the card comes
    /// back on its question side and the count drops by one. Works from the
    /// next card, from a finished batch and from "all caught up" — the last
    /// card of the day is the one people most want to re-grade.
    ///
    /// `guiUndo` only *schedules* the undo (Anki runs it in the background),
    /// and Anki's reviewer refreshes itself only while Anki's own window is
    /// focused — which, with ReviewBar in front, it isn't. Re-entering the
    /// current deck (`guiDeckReview`) forces the reviewer to re-fetch, and
    /// because the deck is unchanged Anki keeps its study queue, with the
    /// undone card restored at its front. The fetch is then polled until
    /// that card shows up, in case it ran ahead of the undo.
    ///
    /// Returns whether an answer was undone.
    @discardableResult
    public func undo() async -> Bool {
        guard canUndo, let undoneId = undoable.last, let deck = activeDeck else { return false }
        phase = .entering
        isUndoing = true
        defer { isUndoing = false }
        do {
            try await client.undo()
            var card = try await reenterAndFetch(deck: deck)
            var attempts = 0
            while card?.cardId != undoneId, attempts < Self.undoPollAttempts {
                attempts += 1
                try await Task.sleep(for: Self.undoPollInterval)
                card = try await reenterAndFetch(deck: deck)
            }
            undoable.removeLast()
            answeredCount -= 1
            // Undoing back into the previous batch: that batch is open again.
            batchStart = min(batchStart, answeredCount)
            guard let card else {
                // The deck has nothing to show even so — treat it as drained.
                await advanceToNextDeck()
                return true
            }
            try await client.startCardTimer()
            phase = .question(card)
            return true
        } catch {
            fail(error)
            return false
        }
    }

    /// `guiDeckReview` on the deck already being reviewed, then the card it
    /// now shows. Nil when the reviewer reports no active review.
    private func reenterAndFetch(deck: String) async throws -> CurrentCard? {
        try await client.startReview(deckName: deck)
        do {
            return try await client.currentCard()
        } catch {
            if (error as? AnkiConnectError)?.isReviewInactive == true { return nil }
            throw error
        }
    }

    /// Report a failure that happened *before* the flow started — the app
    /// couldn't even get the deck list, say. Without this the phase stays
    /// `.idle` and the panel spins forever on a review that never began.
    public func fail(with state: ConnectionState) {
        phase = .failed(state)
    }

    /// Abandon the session locally. Anki's reviewer is left as-is.
    public func stop() {
        phase = .idle
        remainingDecks = []
        undoable = []
        activeDeck = nil
    }

    /// Cards answered in the batch that just ended — for the summary line.
    public var batchAnsweredCount: Int { answeredCount - batchStart }

    // MARK: Flow

    private func advanceToNextDeck() async {
        phase = .entering
        while !remainingDecks.isEmpty {
            let deck = remainingDecks.removeFirst()
            // Entering a deck is itself an operation on Anki's undo stack, so
            // answers in the deck before it are out of reach from here on.
            undoable = []
            activeDeck = deck
            do {
                try await client.startReview(deckName: deck)
                if await showNextCard(deckDrainedIsFinished: false) { return }
                if case .failed = phase { return }
                // Deck had nothing due — try the next one.
            } catch {
                fail(error)
                return
            }
        }
        phase = .finished
    }

    /// Fetch and present the reviewer's current card. Returns false when the
    /// reviewer reports no active review (deck drained); by default that
    /// advances to the next deck.
    @discardableResult
    private func showNextCard(deckDrainedIsFinished: Bool = true) async -> Bool {
        do {
            let card = try await client.currentCard()
            try await client.startCardTimer()
            phase = .question(card)
            return true
        } catch {
            if (error as? AnkiConnectError)?.isReviewInactive == true {
                if deckDrainedIsFinished { await advanceToNextDeck() }
                return false
            }
            fail(error)
            return false
        }
    }

    private func fail(_ error: any Error) {
        phase = .failed(.from(error))
    }
}
