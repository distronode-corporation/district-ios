import Foundation

/// The profile, branding and booking assistant sentences, plus the two option lists
/// whose ORDER is part of the contract.
///
/// ⛔ PORTED FROM THE WEB'S PROFILE, NOTIFICATIONS, BOOKING PAGE AND BOOKING ASSISTANT
/// SETTINGS TABS AND THEIR SHARED FORMAT HELPERS. See the namespace note on
/// ``SchedulingBookingWriteCopy``.
enum SchedulingSettingsWriteCopy {
    // MARK: - Profile (me.patch)

    static let nameLimit = 200

    /// ⛔ WIRE VALUE FIRST, LABEL SECOND, AND THE VALUES ARE THE CATALOG'S `z.enum`.
    /// Anything else is a **400 `invalid_params`** naming the field.
    static var timeFormats: [(value: String, label: String)] {
        [
            ("12h", timeFormat12h),
            ("24h", timeFormat24h),
        ]
    }

    /// ⚠️ THE FORK'S OWN 0-6 NUMBERING, WHICH STARTS AT SUNDAY. Not `Calendar`'s
    /// and not the device locale's: the index crosses the wire as an integer.
    static var weekStarts: [(value: Int, label: String)] {
        [
            (0, SchedulingWriteCopy.weekdaySunday),
            (1, SchedulingWriteCopy.weekdayMonday),
            (2, SchedulingWriteCopy.weekdayTuesday),
            (3, SchedulingWriteCopy.weekdayWednesday),
            (4, SchedulingWriteCopy.weekdayThursday),
            (5, SchedulingWriteCopy.weekdayFriday),
            (6, SchedulingWriteCopy.weekdaySaturday),
        ]
    }

    /// ⚠️ THE EXAMPLES ARE THE LABELS, as on the web. A date format named `dmy`
    /// tells an operator nothing; `31/12/2026` tells them everything.
    static var dateFormats: [(value: String, label: String)] {
        [
            ("dmy", dateFormatDmy),
            ("mdy", dateFormatMdy),
            ("ymd", dateFormatYmd),
        ]
    }

    // MARK: - Branding (settings.branding.patch)

    /// ⛔ CLIENT-SIDE CLAMPS MIRRORING THE WEB'S, WHICH MIRROR THE FORK.
    /// ⚠️ They exist so a slider cannot produce a value the server refuses, not as
    /// a second validator: the catalog is the only one.
    static let logoHeightRange = 16 ... 64
    static let opacityRange = 20 ... 100
    static let businessNameLimit = 200
    static let legalUrlLimit = 500

    // MARK: - The booking assistant (settings.llm)

    /// ⚠️ THE WEB STATES THE 4000 LIMIT AND DOES NOT ENFORCE IT, so an over-long
    /// note is a zod 400 there. This client enforces it, because the refusal
    /// arrives as ``SchedulingAdminError/invalidParams`` with field NAMES only and
    /// nothing an operator could act on.
    static let assistantInstructionsLimit = 4000
}
