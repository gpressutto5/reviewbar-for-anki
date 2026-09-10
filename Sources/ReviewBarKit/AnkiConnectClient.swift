import Foundation

/// Typed facade over the AnkiConnect actions ReviewBar uses.
/// UI and session logic depend on this protocol; `MockAnkiConnectClient`
/// backs tests and Anki-free UI development.
public protocol AnkiConnectClient: Sendable {
    func version() async throws -> Int
    func deckNames() async throws -> [String]
    func deckStats(decks: [String]) async throws -> [DeckStats]

    func startReview(deckName: String) async throws
    func reviewActive() async throws -> Bool
    func currentCard() async throws -> CurrentCard
    func startCardTimer() async throws
    func showAnswer() async throws
    func answerCurrentCard(ease: Ease) async throws

    func mediaDirPath() async throws -> String

    /// Cards reviewed today, counting reviews done in Anki's own reviewer.
    /// Polled as the reminder heartbeat: an increase means "a review happened".
    /// Resets at Anki's day rollover (04:00 by default), so a decrease means a
    /// new day, not activity.
    func numCardsReviewedToday() async throws -> Int

    /// Kick off a collection sync with AnkiWeb, as if the user pressed Sync.
    func sync() async throws

    /// Undo Anki's most recent operation — for ReviewBar, the last
    /// `guiAnswerCard`. Anki runs it in the background and refreshes its
    /// reviewer only while its own window is focused, so the card on screen
    /// in Anki is *stale* when this returns; see `ReviewSession.undo()` for
    /// how the reviewer is made to catch up.
    func undo() async throws

    /// Suspend cards through Anki's scheduler (`suspend`). Already-suspended
    /// cards are skipped by AnkiConnect.
    func suspend(cards: [Int64]) async throws

    /// Bury cards until Anki's next day. AnkiConnect has no bury action, so
    /// the live client writes the card's queue flag directly — the same
    /// change Anki's own bury makes for a card in a normal deck.
    func bury(cards: [Int64]) async throws

    /// The note a card belongs to (`cardsToNotes`, a plain read).
    func noteId(ofCard cardId: Int64) async throws -> Int64

    /// Card ids matching an Anki search (`findCards`, a plain read).
    func findCards(query: String) async throws -> [Int64]
}

/// Live implementation speaking AnkiConnect's JSON-over-HTTP protocol.
public actor AnkiConnectHTTPClient: AnkiConnectClient {
    public static let defaultEndpoint = URL(string: "http://127.0.0.1:8765")!
    public static let requiredAPIVersion = 6

    private var endpoint: URL
    private let session: URLSession

    public init(endpoint: URL = AnkiConnectHTTPClient.defaultEndpoint,
                timeout: TimeInterval = 10) {
        self.endpoint = endpoint
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        self.session = URLSession(configuration: config)
    }

    /// Point subsequent requests somewhere else. Preferences changes the
    /// endpoint on the live client because the session and app state hold a
    /// reference to this instance for the whole app lifetime.
    public func setEndpoint(_ url: URL) {
        endpoint = url
    }

    /// Parse a user-typed endpoint: an http(s) URL with a host, or nil.
    public static func endpoint(from string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host() != nil else { return nil }
        return url
    }

    // MARK: Actions

    public func version() async throws -> Int {
        let v: Int = try await invoke("version")
        guard v >= Self.requiredAPIVersion else {
            throw AnkiConnectError.incompatibleVersion(v)
        }
        return v
    }

    public func deckNames() async throws -> [String] {
        try await invoke("deckNames")
    }

    public func deckStats(decks: [String]) async throws -> [DeckStats] {
        let byId: [String: DeckStats] = try await invoke(
            "getDeckStats", params: ["decks": decks])
        return Array(byId.values).sorted { $0.name < $1.name }
    }

    public func startReview(deckName: String) async throws {
        let _: Bool = try await invoke("guiDeckReview", params: ["name": deckName])
    }

    public func reviewActive() async throws -> Bool {
        try await invoke("guiReviewActive")
    }

    public func currentCard() async throws -> CurrentCard {
        try await invoke("guiCurrentCard")
    }

    public func startCardTimer() async throws {
        let _: Bool = try await invoke("guiStartCardTimer")
    }

    public func showAnswer() async throws {
        let _: Bool = try await invoke("guiShowAnswer")
    }

    public func answerCurrentCard(ease: Ease) async throws {
        let _: Bool = try await invoke("guiAnswerCard", params: ["ease": ease.rawValue])
    }

    public func mediaDirPath() async throws -> String {
        try await invoke("getMediaDirPath")
    }

    public func numCardsReviewedToday() async throws -> Int {
        try await invoke("getNumCardsReviewedToday")
    }

    public func sync() async throws {
        try await invokeVoid("sync")
    }

    public func undo() async throws {
        let _: Bool = try await invoke("guiUndo")
    }

    public func suspend(cards: [Int64]) async throws {
        guard !cards.isEmpty else { return }
        // False means every card was already suspended — not a failure.
        let _: Bool = try await invoke("suspend", params: ["cards": cards])
    }

    /// Anki's `CardQueue::UserBuried`: buried by hand, unburied at the next
    /// day rollover (or by Unbury in Anki), exactly like `-` in Anki's own
    /// reviewer. `setSpecificValueOfCard` writes through `Card.flush()`, which
    /// stamps mtime/usn so the change syncs, and Anki rebuilds its study
    /// queue after any card update, so the buried card doesn't come back.
    /// What it lacks versus a scheduler op: an undo entry in Anki.
    public func bury(cards: [Int64]) async throws {
        for card in cards {
            let outcomes: [SetValueOutcome] = try await invoke(
                "setSpecificValueOfCard",
                params: ["card": card, "keys": ["queue"],
                         "newValues": [Self.userBuriedQueue],
                         "warning_check": true])
            if let failure = outcomes.compactMap(\.failure).first {
                throw AnkiConnectError.api(failure)
            }
        }
    }

    private static let userBuriedQueue = -2

    public func noteId(ofCard cardId: Int64) async throws -> Int64 {
        let notes: [Int64] = try await invoke("cardsToNotes", params: ["cards": [cardId]])
        guard let note = notes.first else { throw AnkiConnectError.malformedResponse }
        return note
    }

    public func findCards(query: String) async throws -> [Int64] {
        try await invoke("findCards", params: ["query": query])
    }

    // MARK: Transport

    private struct Envelope<T: Decodable>: Decodable {
        let result: T?
        let error: String?
    }

    /// One element of `setSpecificValueOfCard`'s result: `true`, or
    /// `[false, "message"]` when the write raised.
    private struct SetValueOutcome: Decodable {
        let failure: String?

        init(from decoder: any Decoder) throws {
            if let ok = try? decoder.singleValueContainer().decode(Bool.self) {
                failure = ok ? nil : "setSpecificValueOfCard refused the change"
                return
            }
            var parts = try decoder.unkeyedContainer()
            _ = try parts.decode(Bool.self)
            failure = try parts.decodeIfPresent(String.self)
                ?? "setSpecificValueOfCard failed"
        }
    }

    /// For actions whose success result is `null` (e.g. `sync`): only the
    /// error field matters.
    private func invokeVoid(_ action: String) async throws {
        let _: Envelope<Bool> = try await invokeRaw(action, params: nil)
    }

    private func invoke<T: Decodable>(
        _ action: String, params: [String: any Sendable]? = nil
    ) async throws -> T {
        let envelope: Envelope<T> = try await invokeRaw(action, params: params)
        guard let result = envelope.result else {
            // A null result without an error is malformed for typed results;
            // null-returning actions go through invokeVoid instead.
            throw AnkiConnectError.malformedResponse
        }
        return result
    }

    private func invokeRaw<T: Decodable>(
        _ action: String, params: [String: any Sendable]?
    ) async throws -> Envelope<T> {
        var body: [String: Any] = ["action": action, "version": Self.requiredAPIVersion]
        if let params { body["params"] = params }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        do {
            (data, _) = try await session.data(for: request)
        } catch {
            throw AnkiConnectError.unreachable(error.localizedDescription)
        }

        let envelope: Envelope<T>
        do {
            envelope = try JSONDecoder().decode(Envelope<T>.self, from: data)
        } catch {
            throw AnkiConnectError.malformedResponse
        }
        if let message = envelope.error {
            throw AnkiConnectError.api(message)
        }
        return envelope
    }
}
