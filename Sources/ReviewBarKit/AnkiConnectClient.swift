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

    // MARK: Transport

    private struct Envelope<T: Decodable>: Decodable {
        let result: T?
        let error: String?
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
