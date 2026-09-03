import Foundation

/// Time of day for the active review window, stored as wall-clock components
/// so a stored preference survives DST and timezone changes.
public struct TimeOfDay: Codable, Equatable, Sendable, Comparable {
    public let hour: Int
    public let minute: Int

    public init(hour: Int, minute: Int = 0) {
        self.hour = hour
        self.minute = minute
    }

    public var minutesFromMidnight: Int { hour * 60 + minute }

    public static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool {
        lhs.minutesFromMidnight < rhs.minutesFromMidnight
    }
}

public enum ReminderMode: String, Codable, Sendable {
    /// Cards only ever appear when the user asks (PRD "Manual").
    case off
    /// Nudge after an interval without a review.
    case nudge
}

/// Rungs of the nudge ladder, quietest first. The passive menu-bar badge isn't
/// here: it's always on and needs no decision.
public enum NudgeRung: String, Codable, Sendable {
    /// The notch hotspot pokes out and settles. Silent, ignorable.
    case peek
    /// User notification — reaches other apps and Spaces.
    case notify
    /// Open the review panel unprompted. Opt-in only.
    case openPanel
}

/// User-configurable reminder behavior. All of this is UI-less in step 11
/// (defaults + `UserDefaults` keys); step 12 puts a form over it.
public struct ReminderSettings: Codable, Equatable, Sendable {
    public var mode: ReminderMode
    /// Quiet time after the last review before the first nudge.
    public var interval: TimeInterval
    /// System idle time past which a nudge is held until the user returns —
    /// a peek nobody is present to see is simply lost.
    public var idleThreshold: TimeInterval
    public var activeStart: TimeOfDay
    public var activeEnd: TimeOfDay
    /// Anki's day-rollover hour; ends a backoff silence.
    public var dayRolloverHour: Int
    /// Treat learning cards as "nothing waiting": an "Again" leaves a card due
    /// in <10 min, so counting them means never being caught up.
    public var gateIgnoresLearningCards: Bool
    /// Get quieter when ignored: interval, then 2×, then silent until the next
    /// review or day rollover.
    public var backoffEnabled: Bool
    /// Escalate all the way to opening the panel by itself.
    public var autoOpenPanel: Bool
    /// Whether a panel opened from a nudge lands on a live card (entering
    /// Anki's review state) or on a passive "reviews waiting" state.
    /// Consumed by the app layer, not by `ReminderScheduler.plan`.
    public var nudgeOpensOntoCard: Bool

    public init(mode: ReminderMode = .nudge,
                interval: TimeInterval = 3600,
                idleThreshold: TimeInterval = 1200,
                activeStart: TimeOfDay = TimeOfDay(hour: 9),
                activeEnd: TimeOfDay = TimeOfDay(hour: 21),
                dayRolloverHour: Int = 4,
                gateIgnoresLearningCards: Bool = true,
                backoffEnabled: Bool = true,
                autoOpenPanel: Bool = false,
                nudgeOpensOntoCard: Bool = true) {
        self.mode = mode
        self.interval = interval
        self.idleThreshold = idleThreshold
        self.activeStart = activeStart
        self.activeEnd = activeEnd
        self.dayRolloverHour = dayRolloverHour
        self.gateIgnoresLearningCards = gateIgnoresLearningCards
        self.backoffEnabled = backoffEnabled
        self.autoOpenPanel = autoOpenPanel
        self.nudgeOpensOntoCard = nudgeOpensOntoCard
    }

    /// Every key optional so adding a setting later doesn't invalidate a blob
    /// already stored in `UserDefaults`.
    ///
    /// `fallback` only fills keys *absent from stored JSON* — it is not where
    /// the defaults live. Change a default in the memberwise `init` above, or
    /// override it for a dev run with the `REVIEWBAR_NUDGE_*` environment
    /// variables (see `AppState.loadReminderSettings`).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ReminderSettings.fallback
        mode = try c.decodeIfPresent(ReminderMode.self, forKey: .mode) ?? d.mode
        interval = try c.decodeIfPresent(TimeInterval.self, forKey: .interval) ?? d.interval
        idleThreshold = try c.decodeIfPresent(TimeInterval.self, forKey: .idleThreshold) ?? d.idleThreshold
        activeStart = try c.decodeIfPresent(TimeOfDay.self, forKey: .activeStart) ?? d.activeStart
        activeEnd = try c.decodeIfPresent(TimeOfDay.self, forKey: .activeEnd) ?? d.activeEnd
        dayRolloverHour = try c.decodeIfPresent(Int.self, forKey: .dayRolloverHour) ?? d.dayRolloverHour
        gateIgnoresLearningCards = try c.decodeIfPresent(Bool.self, forKey: .gateIgnoresLearningCards) ?? d.gateIgnoresLearningCards
        backoffEnabled = try c.decodeIfPresent(Bool.self, forKey: .backoffEnabled) ?? d.backoffEnabled
        autoOpenPanel = try c.decodeIfPresent(Bool.self, forKey: .autoOpenPanel) ?? d.autoOpenPanel
        nudgeOpensOntoCard = try c.decodeIfPresent(Bool.self, forKey: .nudgeOpensOntoCard) ?? d.nudgeOpensOntoCard
    }

    /// Next opening of the active window strictly after `date`.
    public func nextActiveWindowOpen(after date: Date, calendar: Calendar = .current) -> Date {
        calendar.nextDate(after: date, matching: startComponents,
                          matchingPolicy: .nextTime) ?? date
    }

    /// Most recent opening of the active window at or before `date` — the
    /// clock's starting point on a day with no reviews yet, so the first nudge
    /// lands an hour into the user's day rather than at Anki's 04:00 rollover.
    public func activeWindowOpen(atOrBefore date: Date, calendar: Calendar = .current) -> Date {
        calendar.nextDate(after: date, matching: startComponents,
                          matchingPolicy: .nextTime, direction: .backward) ?? date
    }

    private var startComponents: DateComponents {
        DateComponents(hour: activeStart.hour, minute: activeStart.minute)
    }

    public var isNudging: Bool { mode == .nudge }

    /// How long a fired nudge stays current — one interval, so an unanswered
    /// pill is replaced seamlessly by the next cycle's rather than blinking. A
    /// backed-off cycle waits longer, which is what makes the pill go quiet.
    public var nudgeLifetime: TimeInterval { interval }

    /// Stock values, used to fill gaps in a stored blob.
    private static let fallback = ReminderSettings()

    /// True while `now` falls inside the active window; windows wrapping past
    /// midnight (e.g. 21:00–02:00) are supported.
    public func isWithinActiveWindow(_ now: Date, calendar: Calendar) -> Bool {
        let components = calendar.dateComponents([.hour, .minute], from: now)
        let minutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        let start = activeStart.minutesFromMidnight, end = activeEnd.minutesFromMidnight
        return start <= end ? (minutes >= start && minutes < end)
                            : (minutes >= start || minutes < end)
    }
}

/// A nudge that has fired and not yet been resolved by a review.
public struct ActiveNudge: Equatable, Sendable {
    /// When the *first* rung of this nudge fired — the anchor for both
    /// escalation and the implicit one-interval snooze.
    public var firedAt: Date
    /// Highest rung reached so far.
    public var rung: NudgeRung
    /// The user showed they saw it (hovered the notch, clicked, opened the
    /// panel). Choosing not to review is a legitimate answer, so an
    /// acknowledged nudge never escalates.
    public var acknowledged: Bool

    public init(firedAt: Date, rung: NudgeRung, acknowledged: Bool = false) {
        self.firedAt = firedAt
        self.rung = rung
        self.acknowledged = acknowledged
    }

    /// Still awaiting an answer, and still within its lifetime. Drives both the
    /// escalation window and whether the notch pill stays out — the pill is not
    /// on a timer of its own: it *is* this state.
    public func isLive(at now: Date, lifetime: TimeInterval) -> Bool {
        !acknowledged && now < firedAt.addingTimeInterval(lifetime)
    }
}

/// Per-deck due counts split the way the nudge gate needs them.
public struct DueBreakdown: Equatable, Sendable {
    public let newCount: Int
    public let learnCount: Int
    public let reviewCount: Int

    public init(newCount: Int = 0, learnCount: Int = 0, reviewCount: Int = 0) {
        self.newCount = newCount
        self.learnCount = learnCount
        self.reviewCount = reviewCount
    }

    public var total: Int { newCount + learnCount + reviewCount }
    public var excludingLearning: Int { newCount + reviewCount }
}

/// Everything observed about the world that the decision depends on. The app
/// layer fills this in; `ReminderScheduler` never reads a clock or a system API.
public struct ReminderState: Equatable, Sendable {
    /// When a review was last seen to happen — the `getNumCardsReviewedToday`
    /// counter going up, so reviews done inside Anki count too. Nil means none
    /// observed yet today, and the clock starts at the active window's opening.
    public var lastReviewAt: Date?
    public var due: DueBreakdown
    public var nudge: ActiveNudge?
    /// Consecutive nudges that produced no review. Drives backoff.
    public var ignoredNudgeCount: Int
    public var snoozeUntil: Date?
    public var isPanelOpen: Bool
    /// `CGEventSourceSecondsSinceLastEventType` — the user may be away.
    public var systemIdleSeconds: TimeInterval
    public var isScreenLocked: Bool
    /// The menu bar isn't on screen (a fullscreen app, or an auto-hidden menu
    /// bar), so a peek can't be seen and auto-opening over it would be hostile.
    /// This — not elapsed time — is what promotes a nudge to a notification.
    public var isNotchHidden: Bool

    public init(lastReviewAt: Date? = nil,
                due: DueBreakdown = DueBreakdown(),
                nudge: ActiveNudge? = nil,
                ignoredNudgeCount: Int = 0,
                snoozeUntil: Date? = nil,
                isPanelOpen: Bool = false,
                systemIdleSeconds: TimeInterval = 0,
                isScreenLocked: Bool = false,
                isNotchHidden: Bool = false) {
        self.lastReviewAt = lastReviewAt
        self.due = due
        self.nudge = nudge
        self.ignoredNudgeCount = ignoredNudgeCount
        self.snoozeUntil = snoozeUntil
        self.isPanelOpen = isPanelOpen
        self.systemIdleSeconds = systemIdleSeconds
        self.isScreenLocked = isScreenLocked
        self.isNotchHidden = isNotchHidden
    }

    // MARK: Transitions
    //
    // Kept here rather than in the app so the lifecycle rules are unit-tested
    // alongside the decision they feed.

    /// A review happened: the nudge is resolved and backoff resets. Any
    /// answered card buys the full interval — that's the point of the design.
    public mutating func recordReview(at date: Date) {
        lastReviewAt = date
        nudge = nil
        ignoredNudgeCount = 0
        snoozeUntil = nil
    }

    /// A nudge fired. Each cycle fires exactly one rung — there is no
    /// escalation within a cycle — so a nudge arriving while the previous one
    /// is still unresolved means that one went ignored.
    public mutating func recordNudge(rung: NudgeRung, at date: Date) {
        if nudge != nil { ignoredNudgeCount += 1 }
        nudge = ActiveNudge(firedAt: date, rung: rung)
    }

    /// The user showed they saw the nudge without reviewing — no escalation,
    /// and the next nudge is a full interval away.
    public mutating func acknowledgeNudge() {
        nudge?.acknowledged = true
    }

    /// Anki's day rolled over (the reviewed-today counter went *down*): today's
    /// history is gone, so the clock, backoff and any "not today" all reset.
    public mutating func recordDayRollover() {
        lastReviewAt = nil
        nudge = nil
        ignoredNudgeCount = 0
        snoozeUntil = nil
    }

    public mutating func snooze(until date: Date) {
        snoozeUntil = date
        nudge = nil
    }
}

public enum NudgeWaitReason: Equatable, Sendable {
    /// Waiting out the interval since the last review or nudge.
    case interval
    case snoozed
    case outsideActiveWindow
    /// Backed off after repeated ignores — silent until the day rolls over.
    case silenced
}

public enum NudgeIdleReason: Equatable, Sendable {
    case disabled
    /// Nothing worth surfacing (see `gateIgnoresLearningCards`).
    case caughtUp
    /// Already reviewing — never nudge over the panel.
    case panelOpen
    case userAway
    case screenLocked
}

public enum ReminderDecision: Equatable, Sendable {
    case nudge(NudgeRung)
    /// Nothing to do until `until`; re-plan then, or on any state change.
    case wait(until: Date, reason: NudgeWaitReason)
    /// Nothing to do until the state changes; there's no useful deadline.
    case idle(NudgeIdleReason)
}

/// Decides whether to nudge the user toward a review, and how loudly.
///
/// Nudges are driven by **inactivity, not backlog**: "no review in an interval
/// and something is waiting", never "N cards over M hours therefore every
/// M/N minutes". The due count is a gate only. See "Step 11 design" in
/// `docs/implementation-plan.md`.
///
/// Deliberately a pure function of (settings, observed state, now) so every
/// rule is a table-driven test. It owns no timer: the app ticks it.
public enum ReminderScheduler {
    public static func plan(settings: ReminderSettings,
                            state: ReminderState,
                            now: Date,
                            calendar: Calendar = .current) -> ReminderDecision {
        guard settings.mode == .nudge else { return .idle(.disabled) }
        if state.isPanelOpen { return .idle(.panelOpen) }

        let waiting = settings.gateIgnoresLearningCards
            ? state.due.excludingLearning : state.due.total
        guard waiting > 0 else { return .idle(.caughtUp) }

        if let snoozeUntil = state.snoozeUntil, snoozeUntil > now {
            return .wait(until: snoozeUntil, reason: .snoozed)
        }

        guard let multiplier = backoffMultiplier(state.ignoredNudgeCount,
                                                 enabled: settings.backoffEnabled) else {
            return .wait(until: nextRollover(after: now, settings: settings,
                                             calendar: calendar),
                         reason: .silenced)
        }

        guard settings.isWithinActiveWindow(now, calendar: calendar) else {
            return .wait(until: settings.nextActiveWindowOpen(after: now,
                                                              calendar: calendar),
                         reason: .outsideActiveWindow)
        }

        // Holds every rung: a peek nobody sees is wasted, and it would burn
        // the interval. On return, a due escalation fires immediately.
        if state.isScreenLocked { return .idle(.screenLocked) }
        if state.systemIdleSeconds >= settings.idleThreshold { return .idle(.userAway) }

        // An un-reviewed nudge is an implicit snooze of one interval, so the
        // clock runs from whichever came last. The pill stays out across that
        // whole span (see `ActiveNudge.isLive`), so there is nothing to
        // escalate to: a visible reminder is already sitting there.
        let windowOpened = settings.activeWindowOpen(atOrBefore: now, calendar: calendar)
        let anchor = [state.lastReviewAt ?? windowOpened, state.nudge?.firedAt]
            .compactMap { $0 }.max() ?? now
        let fireAt = anchor.addingTimeInterval(settings.interval * Double(multiplier))
        guard now >= fireAt else { return .wait(until: fireAt, reason: .interval) }
        return .nudge(rung(settings: settings, state: state))
    }

    /// Quietest rung that can actually be seen. With the notch off screen a
    /// peek is invisible and auto-opening is hostile, so both give way to a
    /// notification — the only thing that promotes a nudge past the peek.
    private static func rung(settings: ReminderSettings, state: ReminderState) -> NudgeRung {
        if state.isNotchHidden { return .notify }
        return settings.autoOpenPanel ? .openPanel : .peek
    }

    /// Nil means silenced: quieter when ignored is what separates a tool from
    /// an irritant.
    private static func backoffMultiplier(_ ignored: Int, enabled: Bool) -> Int? {
        guard enabled else { return 1 }
        switch ignored {
        case ..<1: return 1
        case 1: return 2
        default: return nil
        }
    }

    private static func nextRollover(after now: Date, settings: ReminderSettings,
                                     calendar: Calendar) -> Date {
        calendar.nextDate(after: now,
                          matching: DateComponents(hour: settings.dayRolloverHour, minute: 0),
                          matchingPolicy: .nextTime) ?? now
    }
}

extension DueCount {
    /// Split counts for the nudge gate. Top-level decks only, like `total` —
    /// Anki's per-deck counts already include subdecks.
    public static func breakdown(from stats: [DeckStats]) -> DueBreakdown {
        DueBreakdown(newCount: stats.reduce(0) { $0 + $1.newCount },
                     learnCount: stats.reduce(0) { $0 + $1.learnCount },
                     reviewCount: stats.reduce(0) { $0 + $1.reviewCount })
    }
}
