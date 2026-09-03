import Foundation

/// The reminder heartbeat: successive readings of `getNumCardsReviewedToday`.
/// An increase means a review happened — including one done inside Anki's own
/// reviewer, which is why this beats a local "last time you used ReviewBar"
/// timer. A decrease means Anki's day rolled over.
///
/// The comparison lives here rather than in `AppState` so it can be
/// table-tested like `ReminderScheduler`; the app layer supplies the counter
/// and the clock and never reasons about the deltas itself.
public struct ReviewCounterMonitor: Equatable, Sendable {
    /// What one reading meant, relative to the reading before it.
    public enum Change: Equatable, Sendable {
        /// Nothing to compare against yet. `hasReviewed` says only *whether*
        /// they reviewed today, never when.
        case firstReading(hasReviewed: Bool)
        /// At least one card was answered since the last reading.
        case reviewed
        case unchanged
        /// The counter went down: today's history is gone.
        case dayRollover
    }

    /// The last counter value seen, or nil before the first reading.
    public private(set) var lastCount: Int?

    public init(lastCount: Int? = nil) {
        self.lastCount = lastCount
    }

    /// Record a reading and report what it meant.
    public mutating func observe(_ count: Int) -> Change {
        defer { lastCount = count }
        guard let previous = lastCount else {
            return .firstReading(hasReviewed: count > 0)
        }
        if count > previous { return .reviewed }
        if count < previous { return .dayRollover }
        return .unchanged
    }

    /// Record a reading and fold it into the reminder state.
    @discardableResult
    public mutating func observe(_ count: Int, at date: Date,
                                 applyingTo state: inout ReminderState) -> Change {
        let change = observe(count)
        switch change {
        case .firstReading(let hasReviewed):
            // We know *whether* they reviewed today, not when. Assume recent,
            // so launching mid-afternoon over a reviewed day doesn't nudge on
            // the first tick.
            if hasReviewed { state.lastReviewAt = date }
        case .reviewed:
            state.recordReview(at: date)
        case .dayRollover:
            state.recordDayRollover()
        case .unchanged:
            break
        }
        return change
    }
}
