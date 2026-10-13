import Foundation

/// The weekly working hours and the dated overrides.
///
/// ⚠️ THE WEEK READS MONDAY FIRST AND THE WIRE COUNTS SUNDAY FIRST. The web editor
/// displays `["Monday", …, "Sunday"]` while `day_of_week` is 0 = Sunday, and the two
/// are bridged by `(index + 1) % 7`. Both clients therefore show the same week and
/// send the same numbers; see ``SchedulingWorkingHours/wireDay(forRow:)``.
extension SchedulingWriteCopy {
    // MARK: - Weekly rules

    /// Monday first. See the ⚠️ at the head of this file.
    static var weekDayNames: [String] {
        [
            weekdayMonday,
            weekdayTuesday,
            weekdayWednesday,
            weekdayThursday,
            weekdayFriday,
            weekdaySaturday,
            weekdaySunday,
        ]
    }

    // MARK: - Dated overrides

    /// ⛔ THE TWO KINDS THIS CLIENT WRITES ARE `day_off` AND `custom_hours`, AND
    /// `out_of_office` IS READ-ONLY IN BOTH CLIENTS. The catalog's enum has three
    /// values; the web's Tiles offer two, and a row that arrives carrying the third
    /// still renders. Offering it would be a third label for a state nothing on
    /// either client can explain the difference of.
    static var overrideKinds: [(reason: String, label: String)] {
        [
            ("day_off", overrideUnavailable),
            ("custom_hours", overrideCustomHours),
        ]
    }
}
