import Foundation

/// One card as served by Anki's reviewer via `guiCurrentCard`.
public struct CurrentCard: Decodable, Sendable, Equatable {
    public let cardId: Int64
    public let question: String
    public let answer: String
    public let css: String
    public let buttons: [Int]
    public let nextReviews: [String]
    public let modelName: String
    public let deckName: String
    public let fields: [String: CardField]

    /// `nextReviews` labels with Anki's Unicode bidi-isolate characters
    /// (U+2068/U+2069) removed, safe for direct display.
    public var displayIntervals: [String] {
        nextReviews.map { $0.strippingBidiIsolates() }
    }

    /// Side HTML for the web view: AV markers replaced with replay-button
    /// anchors + `<audio>` elements (see `AVTagRestorer`).
    public var webQuestion: String {
        AVTagRestorer.replaceAVMarkers(in: question, fields: fields)
    }

    public var webAnswer: String {
        AVTagRestorer.replaceAVMarkers(in: answer, fields: fields)
    }
}

/// One note field from `guiCurrentCard`'s `fields` map. `value` is the raw
/// field text, where audio is still `[sound:file]` tags.
public struct CardField: Decodable, Sendable, Equatable {
    public let value: String
    public let order: Int

    public init(value: String, order: Int) {
        self.value = value
        self.order = order
    }
}

/// Per-deck due counts from `getDeckStats`. Parent decks include subdecks.
public struct DeckStats: Decodable, Sendable, Equatable {
    public let deckId: Int64
    public let name: String
    public let newCount: Int
    public let learnCount: Int
    public let reviewCount: Int

    enum CodingKeys: String, CodingKey {
        case deckId = "deck_id"
        case name
        case newCount = "new_count"
        case learnCount = "learn_count"
        case reviewCount = "review_count"
    }

    public var dueTotal: Int { newCount + learnCount + reviewCount }
}

/// The Again/Hard/Good/Easy rating, using Anki's ease numbering.
public enum Ease: Int, Sendable, CaseIterable {
    case again = 1, hard = 2, good = 3, easy = 4

    public var label: String {
        switch self {
        case .again: "Again"
        case .hard: "Hard"
        case .good: "Good"
        case .easy: "Easy"
        }
    }
}

public enum AnkiConnectError: Error, Equatable, Sendable {
    /// TCP connect refused/reset — Anki not running, AnkiConnect missing, or Anki died.
    case unreachable(String)
    /// AnkiConnect returned an error string in its response envelope.
    case api(String)
    /// Response was not the expected `{result, error}` envelope.
    case malformedResponse
    /// `version` returned something below what we require.
    case incompatibleVersion(Int)

    /// True when the error is `guiCurrentCard` outside review state —
    /// the normal "queue finished" signal, not a failure.
    public var isReviewInactive: Bool {
        if case .api(let message) = self {
            return message.localizedCaseInsensitiveContains("review is not currently active")
        }
        return false
    }
}

extension String {
    func strippingBidiIsolates() -> String {
        filter { $0 != "\u{2068}" && $0 != "\u{2069}" }
    }
}
