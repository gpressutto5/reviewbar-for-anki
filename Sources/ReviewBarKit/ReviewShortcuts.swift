import Foundation

/// Keyboard shortcuts for the review panel, mirroring Anki's reviewer: space
/// (or Return) flips the card and — like Anki — can double as "Good" once the
/// answer is showing, with one key per rating button, plus Anki's bury and
/// suspend keys.
///
/// Pure value type with the resolution logic here rather than in the panel, so
/// "which key does what, in which phase" is unit-testable without a window.
public struct ReviewShortcuts: Codable, Equatable, Sendable {
    /// What a key press means at a given point in the review flow.
    public enum Action: Equatable, Sendable {
        case showAnswer
        case rate(Ease)
        /// Fold the panel away. Escape always does this; `close` is an extra
        /// plain key for people who find Escape a reach.
        case close
        /// Bury or suspend the card on screen. Works on either side of the
        /// card, as in Anki.
        case cardAction(CardAction)
    }

    public var again: String
    public var hard: String
    public var good: String
    public var easy: String
    /// Anki's behaviour: with the answer showing, space rates the card Good.
    /// Off, space only ever flips the card.
    public var spaceAnswersGood: Bool
    /// An additional key that closes the panel in any phase, on top of
    /// Escape (which is bound by the panel's close button and can't be
    /// remapped). Nil means Escape only. Optional so that blobs stored
    /// before this key existed still decode.
    public var close: String?
    /// Anki's card keys: `-` / `=` bury the card / note, `@` / `!` suspend
    /// them. Nil means unbound. Unlike `close`, these default *on*, so a blob
    /// that lacks them gets the defaults and only an explicit null clears one
    /// — see `init(from:)`.
    public var buryCard: String?
    public var buryNote: String?
    public var suspendCard: String?
    public var suspendNote: String?

    public init(again: String = "1", hard: String = "2",
                good: String = "3", easy: String = "4",
                spaceAnswersGood: Bool = true,
                close: String? = nil,
                buryCard: String? = "-", buryNote: String? = "=",
                suspendCard: String? = "@", suspendNote: String? = "!") {
        self.again = again
        self.hard = hard
        self.good = good
        self.easy = easy
        self.spaceAnswersGood = spaceAnswersGood
        self.close = close
        self.buryCard = buryCard
        self.buryNote = buryNote
        self.suspendCard = suspendCard
        self.suspendNote = suspendNote
    }

    public subscript(ease: Ease) -> String {
        get {
            switch ease {
            case .again: again
            case .hard: hard
            case .good: good
            case .easy: easy
            }
        }
        set {
            switch ease {
            case .again: again = newValue
            case .hard: hard = newValue
            case .good: good = newValue
            case .easy: easy = newValue
            }
        }
    }

    public subscript(action: CardAction) -> String? {
        get {
            switch action {
            case .buryCard: buryCard
            case .buryNote: buryNote
            case .suspendCard: suspendCard
            case .suspendNote: suspendNote
            }
        }
        set {
            switch action {
            case .buryCard: buryCard = newValue
            case .buryNote: buryNote = newValue
            case .suspendCard: suspendCard = newValue
            case .suspendNote: suspendNote = newValue
            }
        }
    }

    /// The key that reveals the answer, and the only one bound to two
    /// meanings. Return is treated as this key too (see `normalized(key:)`).
    public static let revealKey = " "

    /// Canonical form of a pressed key: a single lowercased character, with
    /// Return/Enter folded onto the reveal key. Nil for anything that can't be
    /// a shortcut (modifiers-only, function keys, multi-character input).
    public static func normalized(key raw: String) -> String? {
        if raw == "\r" || raw == "\n" || raw == "\u{3}" { return revealKey }
        let lowered = raw.lowercased()
        guard lowered.count == 1, let scalar = lowered.unicodeScalars.first,
              scalar.value >= 0x20, scalar.value != 0x7F else { return nil }
        return lowered
    }

    /// What the given key press should do. `answerShown` distinguishes the
    /// question phase (only the reveal key does anything) from the answer
    /// phase. Ratings resolve regardless of whether the card actually offers
    /// that button — `ReviewSession.submit` is the authority there.
    public func action(forKey raw: String, answerShown: Bool) -> Action? {
        guard let key = Self.normalized(key: raw) else { return nil }
        // Closing wins over a rating: it is the one action that must work in
        // every phase, and a close key that sometimes rates a card instead
        // would be a trap. The reveal key is the exception — space has to
        // keep flipping the card — so a close binding on it is inert. The
        // preferences UI flags both collisions.
        if let close, let closeKey = Self.normalized(key: close),
           closeKey != Self.revealKey, closeKey == key { return .close }
        if key == Self.revealKey {
            if !answerShown { return .showAnswer }
            return spaceAnswersGood ? .rate(.good) : nil
        }
        // Card actions resolve ahead of ratings for the same reason as close:
        // they apply on both sides of the card, and a key that buried on the
        // front but graded on the back would be a trap.
        if let action = CardAction.allCases.first(where: { normalizedKey(for: $0) == key }) {
            return .cardAction(action)
        }
        guard answerShown else { return nil }
        // First match wins, so a duplicated key stays predictable rather than
        // ambiguous; the preferences UI flags the duplicate.
        return Ease.allCases.first { Self.normalized(key: self[$0]) == key }.map(Action.rate)
    }

    private func normalizedKey(for action: CardAction) -> String? {
        self[action].flatMap(Self.normalized(key:))
    }

    /// Eases whose key collides with another ease's, with the reveal key,
    /// with the close key or with a card action's key. Nothing rejects these
    /// — they just can't all fire, so preferences warn.
    public var conflicts: Set<Ease> {
        var seen: [String: Ease] = [:]
        var conflicting: Set<Ease> = []
        let reserved = Set([close.flatMap(Self.normalized(key:))]
            .compactMap { $0 } + CardAction.allCases.compactMap(normalizedKey(for:)))
        for ease in Ease.allCases {
            guard let key = Self.normalized(key: self[ease]) else {
                conflicting.insert(ease)
                continue
            }
            if key == Self.revealKey || reserved.contains(key) {
                conflicting.insert(ease)
            } else if let other = seen[key] {
                conflicting.insert(ease)
                conflicting.insert(other)
            } else {
                seen[key] = ease
            }
        }
        return conflicting
    }

    /// Card actions whose key can't fire as intended: unusable, the reveal
    /// key (which keeps flipping the card), the close key (which wins), a
    /// duplicate of another card action's key, or a rating key — that last
    /// one fires, but hides the rating, so both sides are flagged. Unbound
    /// actions are fine.
    public var cardActionConflicts: Set<CardAction> {
        var seen: [String: CardAction] = [:]
        var conflicting: Set<CardAction> = []
        let closeKey = close.flatMap(Self.normalized(key:))
        let ratingKeys = Set(Ease.allCases.compactMap { Self.normalized(key: self[$0]) })
        for action in CardAction.allCases {
            guard let raw = self[action] else { continue }
            guard let key = Self.normalized(key: raw) else {
                conflicting.insert(action)
                continue
            }
            if key == Self.revealKey || key == closeKey || ratingKeys.contains(key) {
                conflicting.insert(action)
            }
            if let other = seen[key] {
                conflicting.insert(action)
                conflicting.insert(other)
            } else {
                seen[key] = action
            }
        }
        return conflicting
    }

    /// True when the close key is set but can never fire as intended: it is
    /// unusable, or it shadows the reveal key (space/Return would close the
    /// panel instead of flipping the card). Collisions with rating keys are
    /// reported on the rating side, via `conflicts`.
    public var closeKeyConflicts: Bool {
        guard let close else { return false }
        guard let key = Self.normalized(key: close) else { return true }
        return key == Self.revealKey
    }

    /// Display form for a key in the UI: uppercased, with space spelled out.
    public static func displayLabel(for key: String) -> String {
        guard let key = normalized(key: key) else { return "—" }
        return key == revealKey ? "Space" : key.uppercased()
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case again, hard, good, easy, spaceAnswersGood, close
        case buryCard, buryNote, suspendCard, suspendNote
    }

    /// Hand-written so a blob from before a key existed still decodes to the
    /// defaults, and so a key the user *cleared* (stored as null) stays
    /// cleared instead of snapping back to its default.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ReviewShortcuts()
        again = try c.decodeIfPresent(String.self, forKey: .again) ?? d.again
        hard = try c.decodeIfPresent(String.self, forKey: .hard) ?? d.hard
        good = try c.decodeIfPresent(String.self, forKey: .good) ?? d.good
        easy = try c.decodeIfPresent(String.self, forKey: .easy) ?? d.easy
        spaceAnswersGood = try c.decodeIfPresent(Bool.self, forKey: .spaceAnswersGood)
            ?? d.spaceAnswersGood
        close = try c.decodeIfPresent(String.self, forKey: .close)
        buryCard = try Self.clearableKey(.buryCard, in: c, default: d.buryCard)
        buryNote = try Self.clearableKey(.buryNote, in: c, default: d.buryNote)
        suspendCard = try Self.clearableKey(.suspendCard, in: c, default: d.suspendCard)
        suspendNote = try Self.clearableKey(.suspendNote, in: c, default: d.suspendNote)
    }

    /// Absent → the default (an older blob); present-but-null → cleared.
    private static func clearableKey(_ key: CodingKeys,
                                     in container: KeyedDecodingContainer<CodingKeys>,
                                     default fallback: String?) throws -> String? {
        guard container.contains(key) else { return fallback }
        return try container.decodeIfPresent(String.self, forKey: key)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(again, forKey: .again)
        try c.encode(hard, forKey: .hard)
        try c.encode(good, forKey: .good)
        try c.encode(easy, forKey: .easy)
        try c.encode(spaceAnswersGood, forKey: .spaceAnswersGood)
        try c.encodeIfPresent(close, forKey: .close)
        // Written even when nil — the null is what records "cleared".
        for action in CardAction.allCases {
            let key: CodingKeys
            switch action {
            case .buryCard: key = .buryCard
            case .buryNote: key = .buryNote
            case .suspendCard: key = .suspendCard
            case .suspendNote: key = .suspendNote
            }
            if let value = self[action] {
                try c.encode(value, forKey: key)
            } else {
                try c.encodeNil(forKey: key)
            }
        }
    }
}
