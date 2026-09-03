import Foundation
import Testing
@testable import ReviewBarKit

@Suite struct ReviewCounterMonitorTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var earlier: Date { now.addingTimeInterval(-3600) }

    // MARK: Deltas

    @Test(arguments: [
        (previous: Int?.none, count: 0, change: ReviewCounterMonitor.Change.firstReading(hasReviewed: false)),
        (previous: Int?.none, count: 12, change: .firstReading(hasReviewed: true)),
        (previous: Int?(7), count: 8, change: .reviewed),
        (previous: Int?(7), count: 7, change: .unchanged),
        (previous: Int?(7), count: 0, change: .dayRollover),
        (previous: Int?(0), count: 0, change: .unchanged),
    ])
    func readingIsClassifiedAgainstThePrevious(
        previous: Int?, count: Int, change: ReviewCounterMonitor.Change
    ) {
        var monitor = ReviewCounterMonitor(lastCount: previous)
        #expect(monitor.observe(count) == change)
        #expect(monitor.lastCount == count)
    }

    // MARK: Folding into the reminder state

    /// The first reading tells us *whether* they reviewed today, not when, so
    /// a reviewed day is assumed recent — launching mid-afternoon must not
    /// nudge on the first tick.
    @Test func firstReadingWithReviewsAssumesTheyWereRecent() {
        var state = ReminderState()
        var monitor = ReviewCounterMonitor()
        #expect(monitor.observe(20, at: now, applyingTo: &state)
                == .firstReading(hasReviewed: true))
        #expect(state.lastReviewAt == now)
    }

    @Test func firstReadingWithNoReviewsLeavesTheClockAtTheWindowOpening() {
        var state = ReminderState()
        var monitor = ReviewCounterMonitor()
        #expect(monitor.observe(0, at: now, applyingTo: &state)
                == .firstReading(hasReviewed: false))
        #expect(state.lastReviewAt == nil)
    }

    /// An increase resolves the outstanding nudge and clears backoff — any
    /// answered card buys the full interval.
    @Test func anIncreaseRecordsAReview() {
        var state = ReminderState(lastReviewAt: earlier,
                                  nudge: ActiveNudge(firedAt: earlier, rung: .peek),
                                  ignoredNudgeCount: 2,
                                  snoozeUntil: now.addingTimeInterval(600))
        var monitor = ReviewCounterMonitor(lastCount: 5)
        #expect(monitor.observe(6, at: now, applyingTo: &state) == .reviewed)
        #expect(state.lastReviewAt == now)
        #expect(state.nudge == nil)
        #expect(state.ignoredNudgeCount == 0)
        #expect(state.snoozeUntil == nil)
    }

    @Test func anUnchangedCounterTouchesNothing() {
        let before = ReminderState(lastReviewAt: earlier, ignoredNudgeCount: 2)
        var state = before
        var monitor = ReviewCounterMonitor(lastCount: 5)
        #expect(monitor.observe(5, at: now, applyingTo: &state) == .unchanged)
        #expect(state == before)
    }

    /// Anki rolled over to a new day: today's history is gone, so the clock,
    /// the backoff and any "not today" reset rather than the drop reading as
    /// "they un-reviewed".
    @Test func aDropIsADayRollover() {
        var state = ReminderState(lastReviewAt: earlier,
                                  nudge: ActiveNudge(firedAt: earlier, rung: .notify),
                                  ignoredNudgeCount: 3,
                                  snoozeUntil: now.addingTimeInterval(3600))
        var monitor = ReviewCounterMonitor(lastCount: 40)
        #expect(monitor.observe(0, at: now, applyingTo: &state) == .dayRollover)
        #expect(state.lastReviewAt == nil)
        #expect(state.nudge == nil)
        #expect(state.ignoredNudgeCount == 0)
        #expect(state.snoozeUntil == nil)
    }

    /// A reconnect after Anki was unreachable is just another reading — the
    /// monitor keeps its history, so an unchanged counter doesn't read as a
    /// fresh first reading and silently reset the clock.
    @Test func historySurvivesAcrossReadings() {
        var state = ReminderState()
        var monitor = ReviewCounterMonitor()
        monitor.observe(3, at: earlier, applyingTo: &state)
        monitor.observe(3, at: now, applyingTo: &state)
        #expect(state.lastReviewAt == earlier)
    }
}
