import Foundation
import Testing
@testable import ReviewBarKit

@Suite struct ReminderSchedulerTests {
    /// Fixed UTC calendar so wall-clock assertions are deterministic.
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    /// A time on 2026-08-28 (a Friday), in the fixed calendar.
    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 28) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: day,
                                           hour: hour, minute: minute))!
    }

    private var settings: ReminderSettings { ReminderSettings() }

    /// Something waiting, user present, nothing snoozed.
    private func ready(lastReviewAt: Date?) -> ReminderState {
        ReminderState(lastReviewAt: lastReviewAt,
                      due: DueBreakdown(newCount: 3, learnCount: 0, reviewCount: 9))
    }

    private func plan(_ settings: ReminderSettings, _ state: ReminderState,
                      _ now: Date) -> ReminderDecision {
        ReminderScheduler.plan(settings: settings, state: state, now: now,
                               calendar: calendar)
    }

    // MARK: Gates

    @Test func manualModeNeverNudges() {
        var settings = settings
        settings.mode = .off
        #expect(plan(settings, ready(lastReviewAt: at(9)), at(17)) == .idle(.disabled))
    }

    @Test func neverNudgesOverTheOpenPanel() {
        var state = ready(lastReviewAt: at(9))
        state.isPanelOpen = true
        #expect(plan(settings, state, at(17)) == .idle(.panelOpen))
    }

    @Test func learningCardsAloneCountAsCaughtUp() {
        // Answering "Again" leaves a card due in <10 min; that must not read as
        // work waiting, or the user is never caught up.
        let state = ReminderState(lastReviewAt: at(9),
                                  due: DueBreakdown(learnCount: 4))
        #expect(plan(settings, state, at(17)) == .idle(.caughtUp))
    }

    @Test func learningCardsCountWhenGateIncludesThem() {
        var settings = settings
        settings.gateIgnoresLearningCards = false
        let state = ReminderState(lastReviewAt: at(9),
                                  due: DueBreakdown(learnCount: 4))
        #expect(plan(settings, state, at(17)) == .nudge(.peek))
    }

    @Test func nothingDueIsCaughtUp() {
        let state = ReminderState(lastReviewAt: at(9), due: DueBreakdown())
        #expect(plan(settings, state, at(17)) == .idle(.caughtUp))
    }

    // MARK: Interval

    @Test func waitsOutTheIntervalSinceLastReview() {
        #expect(plan(settings, ready(lastReviewAt: at(16, 30)), at(17))
                == .wait(until: at(17, 30), reason: .interval))
    }

    @Test func nudgesOnceTheIntervalElapses() {
        #expect(plan(settings, ready(lastReviewAt: at(16)), at(17)) == .nudge(.peek))
    }

    @Test func withNoReviewYetTodayClockStartsAtTheWindowOpening() {
        // Not at Anki's 04:00 rollover: the first nudge lands an hour into the
        // user's day.
        #expect(plan(settings, ready(lastReviewAt: nil), at(9, 30))
                == .wait(until: at(10), reason: .interval))
        #expect(plan(settings, ready(lastReviewAt: nil), at(10, 1)) == .nudge(.peek))
    }

    // MARK: Presence

    @Test func holdsWhileTheUserIsAway() {
        var state = ready(lastReviewAt: at(16))
        state.systemIdleSeconds = 1500
        #expect(plan(settings, state, at(17)) == .idle(.userAway))
    }

    @Test func firesOnceTheUserIsBack() {
        var state = ready(lastReviewAt: at(16))
        state.systemIdleSeconds = 30
        #expect(plan(settings, state, at(17)) == .nudge(.peek))
    }

    @Test func holdsWhileTheScreenIsLocked() {
        var state = ready(lastReviewAt: at(16))
        state.isScreenLocked = true
        #expect(plan(settings, state, at(17)) == .idle(.screenLocked))
    }

    // MARK: Active window

    @Test func waitsForTheWindowToOpen() {
        #expect(plan(settings, ready(lastReviewAt: at(20)), at(22))
                == .wait(until: at(9, 0, day: 29), reason: .outsideActiveWindow))
    }

    @Test func windowWrappingPastMidnightIsHonored() {
        var settings = settings
        settings.activeStart = TimeOfDay(hour: 21)
        settings.activeEnd = TimeOfDay(hour: 2)
        #expect(settings.isWithinActiveWindow(at(23), calendar: calendar))
        #expect(settings.isWithinActiveWindow(at(1), calendar: calendar))
        #expect(!settings.isWithinActiveWindow(at(12), calendar: calendar))
    }

    // MARK: Snooze

    @Test func snoozeSuppressesUntilItExpires() {
        var state = ready(lastReviewAt: at(16))
        state.snooze(until: at(17, 30))
        #expect(plan(settings, state, at(17)) == .wait(until: at(17, 30), reason: .snoozed))
        #expect(plan(settings, state, at(17, 31)) == .nudge(.peek))
    }

    // MARK: Escalation — peek, then notify

    @Test func ignoredNudgeActsAsAnImplicitSnooze() {
        var state = ready(lastReviewAt: at(16))
        state.recordNudge(rung: .peek, at: at(17))
        // The clock now runs from the nudge, not the review — and the pill is
        // still out over that whole span, so nothing needs to escalate.
        #expect(plan(settings, state, at(17, 30))
                == .wait(until: at(18), reason: .interval))
        #expect(state.nudge!.isLive(at: at(17, 30), lifetime: settings.nudgeLifetime))
    }

    // MARK: Nudge lifetime — also what keeps the notch pill out

    @Test func liveNudgeStaysOutUntilAcknowledged() {
        var state = ready(lastReviewAt: at(16))
        state.recordNudge(rung: .peek, at: at(17))
        let lifetime = settings.nudgeLifetime

        // Out for as long as it's unanswered, not for a few seconds.
        #expect(state.nudge!.isLive(at: at(17, 1), lifetime: lifetime))
        #expect(state.nudge!.isLive(at: at(17, 45), lifetime: lifetime))

        state.acknowledgeNudge()
        #expect(!state.nudge!.isLive(at: at(17, 10), lifetime: lifetime))
    }

    @Test func nudgeStopsBeingLiveAfterItsLifetime() {
        var state = ready(lastReviewAt: at(16))
        state.recordNudge(rung: .peek, at: at(17))
        #expect(!state.nudge!.isLive(at: at(18), lifetime: settings.nudgeLifetime))
    }

    // MARK: Rung selection

    @Test func aHiddenNotchNotifiesInstead() {
        // A peek can't be seen under a fullscreen app, so the notification rung
        // takes over — the only thing that promotes a nudge past the peek.
        var state = ready(lastReviewAt: at(16))
        state.isNotchHidden = true
        #expect(plan(settings, state, at(17)) == .nudge(.notify))
    }

    @Test func autoOpenIsOptInAndYieldsToAHiddenNotch() {
        var settings = settings
        settings.autoOpenPanel = true
        #expect(plan(settings, ready(lastReviewAt: at(16)), at(17)) == .nudge(.openPanel))

        var state = ready(lastReviewAt: at(16))
        state.isNotchHidden = true
        #expect(plan(settings, state, at(17)) == .nudge(.notify))
    }

    // MARK: Backoff

    @Test func secondNudgeWaitsTwiceAsLong() {
        var state = ready(lastReviewAt: at(12))
        state.recordNudge(rung: .peek, at: at(13))
        state.recordNudge(rung: .peek, at: at(14))   // previous went unresolved
        #expect(state.ignoredNudgeCount == 1)
        #expect(plan(settings, state, at(15))
                == .wait(until: at(16), reason: .interval))
    }

    @Test func goesSilentAfterTwoIgnoredNudgesUntilTheDayRolls() {
        var state = ready(lastReviewAt: at(12))
        state.recordNudge(rung: .peek, at: at(13))
        state.recordNudge(rung: .peek, at: at(14))
        state.recordNudge(rung: .peek, at: at(16))
        #expect(state.ignoredNudgeCount == 2)
        #expect(plan(settings, state, at(19))
                == .wait(until: at(4, 0, day: 29), reason: .silenced))
    }

    @Test func backoffCanBeDisabled() {
        var settings = settings
        settings.backoffEnabled = false
        var state = ready(lastReviewAt: at(12))
        state.ignoredNudgeCount = 5
        state.nudge = ActiveNudge(firedAt: at(16), rung: .notify)
        #expect(plan(settings, state, at(17)) == .nudge(.peek))
    }

    // MARK: Transitions

    @Test func anySingleReviewBuysTheFullInterval() {
        var state = ready(lastReviewAt: at(12))
        state.recordNudge(rung: .peek, at: at(13))
        state.recordNudge(rung: .peek, at: at(14))
        state.recordReview(at: at(15))

        #expect(state.nudge == nil)
        #expect(state.ignoredNudgeCount == 0)
        #expect(plan(settings, state, at(15, 30))
                == .wait(until: at(16), reason: .interval))
    }

    @Test func snoozingClearsTheOutstandingNudge() {
        var state = ready(lastReviewAt: at(16))
        state.recordNudge(rung: .peek, at: at(17))
        state.snooze(until: at(18))
        #expect(state.nudge == nil)
    }

    @Test func dayRolloverResetsTheClockBackoffAndPause() {
        // The reviewed-today counter going *down* means Anki rolled over, not
        // that the user reviewed.
        var state = ready(lastReviewAt: at(20))
        state.recordNudge(rung: .peek, at: at(20, 30))
        state.recordNudge(rung: .peek, at: at(21, 30))
        state.snooze(until: at(9, 0, day: 29))
        state.recordDayRollover()

        #expect(state.lastReviewAt == nil)
        #expect(state.nudge == nil)
        #expect(state.ignoredNudgeCount == 0)
        #expect(state.snoozeUntil == nil)
    }

    @Test func windowHelpersBracketTheActiveWindow() {
        #expect(settings.nextActiveWindowOpen(after: at(22), calendar: calendar)
                == at(9, 0, day: 29))
        #expect(settings.activeWindowOpen(atOrBefore: at(14), calendar: calendar) == at(9))
        // Before the window has opened today, the previous opening is yesterday's.
        #expect(settings.activeWindowOpen(atOrBefore: at(7), calendar: calendar)
                == at(9, 0, day: 27))
    }

    // MARK: Settings persistence

    @Test func partialStoredSettingsDecodeOntoDefaults() {
        // Adding a setting later must not invalidate a blob already stored.
        // A blob written by an older build: missing keys fall back, and a key
        // for a setting since removed (escalationDelay) is ignored rather than
        // failing the decode.
        let json = Data(#"{"interval": 900, "mode": "off", "escalationDelay": 240}"#.utf8)
        let decoded = try! JSONDecoder().decode(ReminderSettings.self, from: json)
        #expect(decoded.interval == 900)
        #expect(decoded.mode == .off)
        #expect(decoded.idleThreshold == ReminderSettings().idleThreshold)
        #expect(decoded.activeStart == TimeOfDay(hour: 9))
    }

    @Test func settingsSurviveARoundTrip() {
        var settings = settings
        settings.activeEnd = TimeOfDay(hour: 22, minute: 30)
        settings.autoOpenPanel = true
        let data = try! JSONEncoder().encode(settings)
        #expect(try! JSONDecoder().decode(ReminderSettings.self, from: data) == settings)
    }

    // MARK: Gate input

    @Test func breakdownSumsDeckStats() {
        let stats = [
            DeckStats(deckId: 1, name: "A", newCount: 2, learnCount: 3, reviewCount: 4),
            DeckStats(deckId: 2, name: "B", newCount: 1, learnCount: 1, reviewCount: 5),
        ]
        let breakdown = DueCount.breakdown(from: stats)
        #expect(breakdown.total == 16)
        #expect(breakdown.excludingLearning == 12)
    }
}
