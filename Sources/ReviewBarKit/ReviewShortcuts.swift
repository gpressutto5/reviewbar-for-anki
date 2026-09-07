import Foundation

/// Keyboard shortcuts for the review panel, mirroring Anki's reviewer: space
/// (or Return) flips the card and — like Anki — can double as "Good" once the
/// answer is showing, with one key per rating button.
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

    public init(again: String = "1", hard: String = "2",
                good: String = "3", easy: String = "4",
                spaceAnswersGood: Bool = true,
                close: String? = nil) {
        self.again = again
        self.hard = hard
        self.good = good
        self.easy = easy
        self.spaceAnswersGood = spaceAnswersGood
        self.close = close
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
        guard answerShown else { return nil }
        // First match wins, so a duplicated key stays predictable rather than
        // ambiguous; the preferences UI flags the duplicate.
        return Ease.allCases.first { Self.normalized(key: self[$0]) == key }.map(Action.rate)
    }

    /// Eases whose key collides with another ease's, with the reveal key, or
    /// with the close key. Nothing rejects these — they just can't all fire,
    /// so preferences warn.
    public var conflicts: Set<Ease> {
        var seen: [String: Ease] = [:]
        var conflicting: Set<Ease> = []
        let closeKey = close.flatMap(Self.normalized(key:))
        for ease in Ease.allCases {
            guard let key = Self.normalized(key: self[ease]) else {
                conflicting.insert(ease)
                continue
            }
            if key == Self.revealKey || key == closeKey {
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
}
