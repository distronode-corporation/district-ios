import Foundation

/// The weekly working hours and the dated overrides.
///
/// ⚠️ THE WEEK READS MONDAY FIRST AND THE WIRE COUNTS SUNDAY FIRST. The web editor
/// displays `["Monday", …, "Sunday"]` while `day_of_week` is 0 = Sunday, and the two
/// are bridged by `(index + 1) % 7`. Both clients therefore show the same week and
/// send the same numbers; see ``SchedulingWorkingHours/wireDay(forRow:)``.
extension SchedulingWriteCopy {
    // MARK: - Weekly rules

    static let hoursTitle = "Your working hours"
    static let hoursSaved = "Working hours saved"
    /// ⚠️ AN INFORMATIONAL OUTCOME, NOT A FAILURE. A save with nothing to send
    /// spends no request at all.
    static let hoursNothingToSave = "Nothing to save."
    static let hoursNotBookable = "Not bookable"
    static let hoursAddRange = "Add range"
    static let hoursRemoveRange = "Remove"
    static let hoursCopyToWeekdays = "Copy to all weekdays"
    static let hoursNeverBookable = "Not bookable on any day yet."

    static let timeFormatError = "Enter a time as HH:MM."
    static let timeOrderError = "The end has to be after the start."
    static let timeOverlapError = "These hours overlap another range on this day."

    /// Monday first. See the ⚠️ at the head of this file.
    static let weekDayNames = [
        "Monday",
        "Tuesday",
        "Wednesday",
        "Thursday",
        "Friday",
        "Saturday",
        "Sunday",
    ]

    // MARK: - Dated overrides

    static let overridesTitle = "Date overrides"
    static let overridesHint = "Days you are away, or working different hours from usual."
    static let overridesEmpty = "No overrides ahead. Add one for a day off or different hours."
    static let overrideAddButton = "Add override"
    static let overrideAddTitle = "Add an override"
    static let overrideKindLabel = "What happens that day"
    static let overrideUnavailable = "Unavailable"
    static let overrideCustomHours = "Custom hours"
    static let overrideFirstDayLabel = "First day"
    static let overrideDateLabel = "Date"
    static let overrideLastDayLabel = "Last day"
    static let overrideLastDayHint = "Leave blank for a single day."
    static let overrideHoursLabel = "Hours that day"
    static let overrideDateMissing = "Pick a date."
    static let overrideEndBeforeStart = "The last day has to be on or after the first."
    static let overrideAdded = "Override added"
    static let overrideDeleteTitle = "Delete this override?"
    static let overrideDeleteConfirm = "Delete override"
    static let overrideDeleted = "Override deleted"
    static let overrideDeleteSingleBody = "That day goes back to your weekly hours."

    static func overrideDeleteGroupBody(days: Int) -> String {
        "All \(days) days go back to your weekly hours."
    }

    /// ⛔ THE TWO KINDS THIS CLIENT WRITES ARE `day_off` AND `custom_hours`, AND
    /// `out_of_office` IS READ-ONLY IN BOTH CLIENTS. The catalog's enum has three
    /// values; the web's Tiles offer two, and a row that arrives carrying the third
    /// still renders. Offering it would be a third label for a state nothing on
    /// either client can explain the difference of.
    static let overrideKinds: [(reason: String, label: String)] = [
        ("day_off", overrideUnavailable),
        ("custom_hours", overrideCustomHours),
    ]
}
