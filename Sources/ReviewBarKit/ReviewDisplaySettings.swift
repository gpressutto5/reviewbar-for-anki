import Foundation

/// How the card itself is rendered inside the panel. The panel is always the
/// dark slab; this only decides what the *card document* sees, because note
/// types (Kiku, for one) ship their own light and dark styling and key it off
/// Anki's night-mode classes and `prefers-color-scheme`.
public enum CardAppearance: String, Codable, CaseIterable, Sendable {
    /// Match the panel — the behaviour before this setting existed.
    case dark
    case light
    /// Follow the macOS appearance, like Anki itself does.
    case system

    public var label: String {
        switch self {
        case .dark: "Dark"
        case .light: "Light"
        case .system: "Match system"
        }
    }
}

/// What the review panel shows, as opposed to how the session behaves
/// (`SessionSettings`) or which keys drive it (`ReviewShortcuts`).
public struct ReviewDisplaySettings: Codable, Equatable, Sendable {
    public var cardAppearance: CardAppearance
    /// Whether the rating buttons carry Anki's next-review previews ("10m",
    /// "3d"). Some people find them a distraction, or a nudge towards
    /// grading for the interval rather than for recall.
    public var showsIntervals: Bool
    /// Pass/fail grading: only the Again and Good buttons are shown, the way
    /// the "Pass/Fail" family of Anki add-ons hides Hard and Easy. Purely a
    /// filter on what the card already offers — the buttons that remain
    /// still submit the ease Anki assigned them, so a three-button card's
    /// Good is still ease 2. Anki's scheduler is untouched.
    public var passFailOnly: Bool

    public init(cardAppearance: CardAppearance = .dark, showsIntervals: Bool = true,
                passFailOnly: Bool = false) {
        self.cardAppearance = cardAppearance
        self.showsIntervals = showsIntervals
        self.passFailOnly = passFailOnly
    }

    /// Meanings a button may carry and still be shown. Filtering happens by
    /// *meaning* (the name on the button), never by ease number: on a
    /// three-button card ease 2 is Good and must survive.
    public var allowedRatings: Set<Ease> {
        passFailOnly ? [.again, .good] : Set(Ease.allCases)
    }

    /// The card's buttons with the hidden ones removed, order preserved.
    public func visibleButtons(_ buttons: [AnswerButton]) -> [AnswerButton] {
        buttons.filter { allowedRatings.contains($0.meaning) }
    }

    /// Whether a rating reached by name (keyboard shortcut) may be submitted.
    /// A hidden button must not stay reachable from the keyboard — grading
    /// Easy while the screen offers only Again and Good would be a surprise.
    public func allows(rating: Ease) -> Bool {
        allowedRatings.contains(rating)
    }

    /// Every key optional, like `SessionSettings`: adding a setting later
    /// must not invalidate a blob already in `UserDefaults`.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ReviewDisplaySettings.fallback
        cardAppearance = try c.decodeIfPresent(CardAppearance.self, forKey: .cardAppearance)
            ?? d.cardAppearance
        showsIntervals = try c.decodeIfPresent(Bool.self, forKey: .showsIntervals)
            ?? d.showsIntervals
        passFailOnly = try c.decodeIfPresent(Bool.self, forKey: .passFailOnly)
            ?? d.passFailOnly
    }

    private static let fallback = ReviewDisplaySettings()
}
