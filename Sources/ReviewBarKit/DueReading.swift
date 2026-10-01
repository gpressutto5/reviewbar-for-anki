import Foundation

/// The last due count Anki reported, kept so that Anki closing doesn't blank
/// the badge or the nudge gate.
///
/// New and review counts only grow at Anki's day rollover — nothing comes due
/// mid-day without Anki — so a reading stands for the rest of the Anki day it
/// was taken in: someone who cleared their cards and quit Anki stays caught
/// up, and someone who quit with cards left gets a nudge with a number on it.
/// Past the rollover it says nothing about today, and the count is unknown.
public struct DueReading: Codable, Equatable, Sendable {
    public var due: DueBreakdown
    public var readAt: Date

    public init(due: DueBreakdown, readAt: Date) {
        self.due = due
        self.readAt = readAt
    }

    /// Taken during the Anki day `now` falls in.
    public func isCurrent(at now: Date, settings: ReminderSettings,
                          calendar: Calendar = .current) -> Bool {
        readAt >= settings.ankiDayStart(atOrBefore: now, calendar: calendar)
    }
}
