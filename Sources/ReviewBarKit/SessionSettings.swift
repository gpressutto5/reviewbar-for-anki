import Foundation

/// The "soft session": how many cards one sitting is worth before the panel
/// pauses and offers to stop.
///
/// This is a *local* budget, not scheduling — Anki still owns the queue. The
/// session simply stops asking for the next card once the batch is spent; the
/// reviewer stays in review state, so continuing picks up exactly where it
/// left off with no card skipped or re-gathered.
///
/// It pairs with the nudge ladder: finishing a batch records a review, which
/// resets the inactivity clock, so the next nudge lands one interval later.
/// That loop — a short batch, then quiet for an hour — is what spreads the
/// day's reviews out instead of front-loading them into one long sitting.
public struct SessionSettings: Codable, Equatable, Sendable {
    /// Off means "review until the decks run dry", the pre-batch behaviour.
    public var isLimited: Bool
    /// Cards per batch. Clamped when used; a stored zero would otherwise
    /// pause before the first card.
    public var cardsPerBatch: Int
    /// Seconds an end-of-session screen stays up before the panel folds away.
    /// Zero means it waits for the user. Long enough to read the summary and
    /// change your mind — a countdown you can only catch the tail of reads as
    /// the panel vanishing on its own.
    public var autoCloseDelay: TimeInterval

    public init(isLimited: Bool = true,
                cardsPerBatch: Int = 10,
                autoCloseDelay: TimeInterval = 10) {
        self.isLimited = isLimited
        self.cardsPerBatch = cardsPerBatch
        self.autoCloseDelay = autoCloseDelay
    }

    /// The number `ReviewSession` should be started with: nil = unlimited.
    public var cardLimit: Int? {
        isLimited ? max(1, cardsPerBatch) : nil
    }

    public var autoCloses: Bool { autoCloseDelay > 0 }

    /// Every key optional, like `ReminderSettings`: adding a setting later
    /// must not invalidate a blob already in `UserDefaults`. Defaults live in
    /// the memberwise `init`, not here.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SessionSettings.fallback
        isLimited = try c.decodeIfPresent(Bool.self, forKey: .isLimited) ?? d.isLimited
        cardsPerBatch = try c.decodeIfPresent(Int.self, forKey: .cardsPerBatch) ?? d.cardsPerBatch
        autoCloseDelay = try c.decodeIfPresent(TimeInterval.self, forKey: .autoCloseDelay) ?? d.autoCloseDelay
    }

    private static let fallback = SessionSettings()
}
