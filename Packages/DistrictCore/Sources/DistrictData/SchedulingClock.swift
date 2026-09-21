import Foundation

/// The wall-clock fields of an instant, in one IANA zone.
///
/// ⛔ THE PORT OF THE WEB DASHBOARD'S `zonedParts`, AND EVERY SCHEDULING TIMESTAMP ON
/// THIS CLIENT GOES THROUGH IT. The scheduler stores
/// instants and the operator reads them in the timezone on their scheduler PROFILE,
/// which is not the device's: a Toronto operator checking a booking from a hotel in
/// Tokyo must still see the hour the customer was told. Formatting off
/// `Date.formatted` would silently use the device zone and be wrong exactly when
/// somebody is travelling — which is also when they are most likely to be reading a
/// booking on a phone.
///
/// ⚠️ `hour` IS 0...23 AND MIDNIGHT IS `0`, NEVER `24`. The TypeScript takes
/// `Number(values.hour) % 24` because `Intl.DateTimeFormat` with `hourCycle` unset
/// can emit `24` for midnight; `Calendar` never does, so the modulo has no port. The
/// property is stated because it is what the two implementations have to agree on.
public struct SchedulingZonedParts: Equatable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int
    public let hour: Int
    public let minute: Int

    public init(year: Int, month: Int, day: Int, hour: Int, minute: Int) {
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
    }
}

/// Parsing the scheduler's timestamps, and rendering them the way each surface does.
///
/// ⛔ THE PADDING IS INCONSISTENT ACROSS THE SURFACES **ON PURPOSE** AND MUST NOT BE
/// TIDIED. Measured against the web rather than assumed: the overview register and the
/// bookings table render an UNPADDED hour (`9:05`), the recordings table renders a
/// PADDED one (`09:05`), and the minute is padded everywhere. Normalising them here
/// would make one of the two clients disagree with the other on a value a person can
/// read side by side, which is the class of difference that gets reported as a bug
/// against whichever was seen second. Each renderer below names which shape it is.
///
/// ⚠️ THE MONTH NAMES ARE A TABLE RATHER THAN A `DateFormatter`. Four separate arrays
/// of them exist on the web and all four are the same English abbreviations; a
/// locale-aware formatter here would render `sept.` under a French device locale while
/// the web rendered `Sep`, on a surface whose French twin does not exist yet. When it
/// does, this is the one place that changes.
public enum SchedulingClock {
    /// ⚠️ `Jan`...`Dec`, matching all four of the web's copies verbatim.
    public static let monthNames = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ]

    /// Parse one of the scheduler's ISO-8601 instants.
    ///
    /// ⚠️ TWO FORMATS ARE TRIED BECAUSE ONE IS NOT ENOUGH, the same pair
    /// ``SchedulingTimestamp`` in the App target already pays for: a `Date` serialised
    /// through `JSON.stringify` carries fractional seconds, and `ISO8601DateFormatter`
    /// REJECTS those unless `withFractionalSeconds` is set while rejecting a string
    /// without them when it is. Neither option parses both.
    ///
    /// ⛔ nil IS "THIS IS NOT A TIME" AND EVERY CALLER MUST SAY SO RATHER THAN GUESS.
    /// The web renders the word `Unknown` and never `Invalid Date`; a screen that fell
    /// back to `Date()` would show today's date for a row whose timestamp was corrupt.
    public static func parse(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    /// The wall-clock fields of `date` in `timezone`.
    ///
    /// ⚠️ AN UNKNOWN ZONE FALLS BACK TO UTC RATHER THAN RETURNING nil. A profile
    /// carrying a zone this platform's database does not have is a row that still has a
    /// real instant in it, and refusing to render the row would hide a booking; UTC is
    /// the honest neutral answer and is what `Intl` does with an invalid zone only after
    /// throwing, which the web guards the same way.
    ///
    /// ⚠️ `.gmt` IS THE UTC FALLBACK: zero offset, no daylight saving, so every field
    /// below comes out as UTC's. A second lookup of `"UTC"` by name used to sit between
    /// the two and could never fail, and `component(_:from:)` replaces a
    /// `dateComponents` read whose `?? 0` fallbacks could never run either: a Gregorian
    /// calendar always yields the fields it is asked for.
    public static func parts(of date: Date, timezone: String) -> SchedulingZonedParts {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone) ?? .gmt
        return SchedulingZonedParts(
            year: calendar.component(.year, from: date),
            month: calendar.component(.month, from: date),
            day: calendar.component(.day, from: date),
            hour: calendar.component(.hour, from: date),
            minute: calendar.component(.minute, from: date)
        )
    }

    /// `9:05` — UNPADDED hour, padded minute. The register, the bookings table and the
    /// reschedule slot list.
    public static func clock(_ parts: SchedulingZonedParts) -> String {
        "\(parts.hour):\(paddedTwo(parts.minute))"
    }

    /// `09:05` — PADDED hour and minute. The recordings table only; see the ⛔ on this
    /// type.
    public static func paddedClock(_ parts: SchedulingZonedParts) -> String {
        "\(paddedTwo(parts.hour)):\(paddedTwo(parts.minute))"
    }

    /// ⚠️ THE MONTH NAME FOR A 1-BASED MONTH, OR nil. A `month` outside 1...12 is a
    /// value no calendar produced, and the callers render the raw input rather than
    /// indexing past the end of the table — which in Swift is a crash rather than the
    /// `undefined` the TypeScript would have shown.
    public static func monthName(_ month: Int) -> String? {
        guard month >= 1, month <= monthNames.count else { return nil }
        return monthNames[month - 1]
    }

    /// ⚠️ `String(format:)` IS AVOIDED THROUGHOUT THIS MODULE. It is locale-sensitive
    /// for numbers on some platforms and this value is a wire-shaped fragment, not
    /// prose.
    public static func paddedTwo(_ value: Int) -> String {
        value < 10 && value >= 0 ? "0\(value)" : String(value)
    }

    /// Whole days between two zoned calendar DATES, ignoring the clock.
    ///
    /// ⛔ IT COMPARES CALENDAR DAYS AND NEVER ELAPSED MILLISECONDS, WHICH IS THE WHOLE
    /// REASON IT EXISTS. "Tomorrow" is a property of the date in the operator's zone: a
    /// booking twenty-three hours away is tomorrow when it crosses midnight and today
    /// when it does not, and an elapsed-time subtraction answers the same number for
    /// both. The web builds `Date.UTC(y, m - 1, d)` for each side for exactly this
    /// reason; the port uses a UTC calendar over the already-zoned fields, which is the
    /// same trick and keeps DST out of the subtraction.
    ///
    /// ⚠️ nil FOR A YEAR NO CALENDAR CAN HOLD. `Calendar` refuses a date hundreds of
    /// billions of years out rather than wrapping, and the callers render nothing for a
    /// nil delta instead of a wrong day.
    public static func dayDelta(from: SchedulingZonedParts, to: SchedulingZonedParts) -> Int? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        var start = DateComponents()
        start.year = from.year
        start.month = from.month
        start.day = from.day
        var end = DateComponents()
        end.year = to.year
        end.month = to.month
        end.day = to.day
        guard let startDate = calendar.date(from: start), let endDate = calendar.date(from: end) else {
            return nil
        }
        return calendar.dateComponents([.day], from: startDate, to: endDate).day
    }
}
