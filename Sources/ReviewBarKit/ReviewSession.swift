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

    private let client: any AnkiConnectClient
    private var remainingDecks: [String] = []
    /// Cards per batch; nil reviews until the decks run dry.
    private var batchSize: Int?
    /// `answeredCount` when the current batch began.
    private var batchStart = 0

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
    }

    /// Cards answered in the batch that just ended — for the summary line.
    public var batchAnsweredCount: Int { answeredCount - batchStart }

    // MARK: Flow

    private func advanceToNextDeck() async {
        phase = .entering
        while !remainingDecks.isEmpty {
            let deck = remainingDecks.removeFirst()
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
