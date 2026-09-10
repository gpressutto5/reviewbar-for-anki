import Foundation

/// In-memory AnkiConnect stand-in for tests and Anki-free UI development.
/// Serves a fixed queue of cards and records answers.
public actor MockAnkiConnectClient: AnkiConnectClient {
    public var queue: [CurrentCard]
    public private(set) var answered: [(cardId: Int64, ease: Ease)] = []
    /// The cards behind `answered`, most recent last — what `undo` restores.
    private var answeredCards: [CurrentCard] = []
    public private(set) var suspended: Set<Int64> = []
    public private(set) var buried: Set<Int64> = []
    public private(set) var undoCount = 0
    public private(set) var reviewInProgress = false
    private var answerShown = false
    public var failWithUnreachable = false
    /// Card → note. Cards not listed are each their own note (note id = card
    /// id); list two cards under one note to make them siblings.
    private let noteIds: [Int64: Int64]

    public init(queue: [CurrentCard] = MockAnkiConnectClient.sampleQueue,
                noteIds: [Int64: Int64] = [:]) {
        self.queue = queue
        self.noteIds = noteIds
    }

    public func setUnreachable(_ value: Bool) { failWithUnreachable = value }

    private func checkReachable() throws {
        if failWithUnreachable { throw AnkiConnectError.unreachable("connection refused") }
    }

    /// Mirrors the real counter: every answer bumps it, so the reminder
    /// heartbeat sees activity.
    public func numCardsReviewedToday() async throws -> Int {
        try checkReachable()
        return answered.count
    }

    public func version() async throws -> Int {
        try checkReachable()
        return 6
    }

    public func deckNames() async throws -> [String] {
        try checkReachable()
        return ["Default", "Sample", "Sample::Sub"]
    }

    public func deckStats(decks: [String]) async throws -> [DeckStats] {
        try checkReachable()
        return decks.enumerated().map { index, name in
            DeckStats(deckId: Int64(index), name: name,
                      newCount: name == "Sample" ? 2 : 0,
                      learnCount: 0,
                      reviewCount: name == "Sample" ? queue.count : 0)
        }
    }

    public func startReview(deckName: String) async throws {
        try checkReachable()
        reviewInProgress = !queue.isEmpty
    }

    public func reviewActive() async throws -> Bool {
        try checkReachable()
        return reviewInProgress
    }

    public func currentCard() async throws -> CurrentCard {
        try checkReachable()
        guard reviewInProgress, let card = queue.first else {
            throw AnkiConnectError.api("Gui review is not currently active.")
        }
        return card
    }

    public func startCardTimer() async throws { try checkReachable() }

    public func showAnswer() async throws {
        try checkReachable()
        answerShown = true
    }

    public func answerCurrentCard(ease: Ease) async throws {
        try checkReachable()
        guard reviewInProgress, answerShown, let card = queue.first else {
            throw AnkiConnectError.api("Not in answer state")
        }
        answered.append((card.cardId, ease))
        answeredCards.append(card)
        queue.removeFirst()
        answerShown = false
        if queue.isEmpty { reviewInProgress = false }
    }

    public func mediaDirPath() async throws -> String {
        try checkReachable()
        return "/tmp/mock-collection.media"
    }

    public private(set) var syncCount = 0

    public func sync() async throws {
        try checkReachable()
        syncCount += 1
    }

    /// Like Anki: the undone card goes back to the front of the queue, on its
    /// question side, and review state resumes if it had ended. Unlike Anki
    /// this is synchronous, so the session's first re-fetch already sees it.
    public func undo() async throws {
        try checkReachable()
        undoCount += 1
        guard let card = answeredCards.popLast() else { return }
        answered.removeLast()
        queue.insert(card, at: 0)
        answerShown = false
        reviewInProgress = true
    }

    public func suspend(cards: [Int64]) async throws {
        try checkReachable()
        suspended.formUnion(cards)
        removeFromQueue(cards)
    }

    public func bury(cards: [Int64]) async throws {
        try checkReachable()
        buried.formUnion(cards)
        removeFromQueue(cards)
    }

    private func removeFromQueue(_ cards: [Int64]) {
        queue.removeAll { cards.contains($0.cardId) }
        if queue.isEmpty { reviewInProgress = false }
    }

    public func noteId(ofCard cardId: Int64) async throws -> Int64 {
        try checkReachable()
        return noteIds[cardId] ?? cardId
    }

    /// Understands the two searches `ReviewSession` issues: `nid:N`, with
    /// optional `-is:suspended` / `-is:buried` exclusions.
    public func findCards(query: String) async throws -> [Int64] {
        try checkReachable()
        let terms = query.split(separator: " ").map(String.init)
        guard let nid = terms.first(where: { $0.hasPrefix("nid:") })
            .flatMap({ Int64($0.dropFirst(4)) }) else { return [] }
        return knownCardIds.filter { id in
            (noteIds[id] ?? id) == nid
                && !(terms.contains("-is:suspended") && suspended.contains(id))
                && !(terms.contains("-is:buried") && buried.contains(id))
        }
    }

    /// Every card the mock has seen: queued, answered, suspended or buried.
    private var knownCardIds: [Int64] {
        var seen: Set<Int64> = []
        return ((queue + answeredCards).map(\.cardId) + suspended.sorted() + buried.sorted())
            .filter { seen.insert($0).inserted }
    }

    public static let sampleQueue: [CurrentCard] = [
        CurrentCard(cardId: 1, question: "<b>What is 2+2?</b>",
                    answer: "<b>What is 2+2?</b><hr id=answer>4",
                    css: ".card { font-family: arial; }",
                    buttons: [1, 2, 3, 4],
                    nextReviews: ["\u{2068}1\u{2069}m", "\u{2068}6\u{2069}m",
                                  "\u{2068}10\u{2069}m", "\u{2068}4\u{2069}d"],
                    modelName: "Basic", deckName: "Sample",
                    fields: ["Front": CardField(value: "What is 2+2?", order: 0),
                             "Back": CardField(value: "4", order: 1)]),
        CurrentCard(cardId: 2, question: "Capital of France?",
                    answer: "Capital of France?<hr id=answer>Paris",
                    css: "", buttons: [1, 2, 3],
                    nextReviews: ["1m", "10m", "4d"],
                    modelName: "Basic", deckName: "Sample",
                    fields: ["Front": CardField(value: "Capital of France?", order: 0),
                             "Back": CardField(value: "Paris", order: 1)]),
    ]
}
