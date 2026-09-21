import Foundation
import SwiftUI

/// The presentation arithmetic behind the analytics cards, ported from Android's
/// `AnalyticsChartMath.kt`.
///
/// ⚠️ NO SwiftUI TYPES CROSS INTO THE NUMERIC HELPERS — only ``hexColor(_:)``
/// returns a `Color`, and it does so from a plain parse. That is the same seam
/// Android drew, and it exists because the interesting inputs here are the
/// degenerate ones: an all-zero trend series, a month whose only metered row was a
/// phone-number count, a colour the server changed the format of. Every one of them
/// is a value, and keeping them out of the drawing code is what makes them readable
/// at all on a tier with no tests.
enum AnalyticsFormat {
    /// Seconds as the SHORT duration form, matching the web's KPI tiles.
    ///
    /// ⛔ TWO DURATION FORMATS SHIP IN THIS PRODUCT AND THEY DISAGREE ON THE SAME
    /// INPUT: a tile omits a zero minutes component ("45s") while a call row always
    /// emits one ("0m 45s"). This is the TILE form, because that is what
    /// ``AnalyticsMetrics/avgDuration`` feeds. The call feed does not use it — its
    /// durations arrive pre-formatted from the server precisely so the client cannot
    /// pick the wrong one.
    ///
    /// ⚠️ A NEGATIVE READS AS ZERO rather than as "-1m 30s". The value is a rounded
    /// average of non-negative durations, so a negative is corrupt input, and a
    /// minus sign in a KPI tile reads as a measurement rather than as a fault.
    /// A bar's height, said rather than drawn.
    ///
    /// ⚠️ SINGULAR AT ONE. VoiceOver reads these one bar after another while a person
    /// swipes along a chart, and "1 calls" thirty times is the kind of wrongness that
    /// makes a screen reader sound broken rather than merely terse.
    static func callCount(_ calls: Int) -> String {
        calls == 1 ? "1 call" : "\(calls) calls"
    }

    static func duration(seconds: Int) -> String {
        let safe = max(seconds, 0)
        let minutes = safe / 60
        let remainder = safe % 60
        return minutes > 0 ? "\(minutes)m \(remainder)s" : "\(remainder)s"
    }

    /// A metered amount, as a quantity rather than as a raw `Double`.
    ///
    /// ⛔ THESE ARE GENUINELY FRACTIONAL — call minutes are summed as floats
    /// server-side — so truncating to an `Int` would truncate a billing figure,
    /// while a bare interpolation renders "412.0" for a whole number of SMS. Whole
    /// values print whole and fractional ones keep two decimals.
    ///
    /// ⚠️ A NON-FINITE VALUE PRINTS AS THE ABSENT MARKER rather than "nan". Nothing
    /// the server sends can be one, which is exactly why the branch has to be
    /// decided here instead of at a call site that would never think to.
    static func amount(_ value: Double) -> String {
        guard value.isFinite else { return absent }
        let rounded = (value * 100).rounded() / 100
        // ⚠️ `String(format:)` WITH NO `locale:` FORMATS WITHOUT LOCALISATION, so the
        // separator is always a `.` — which is what the web console shows and what a
        // decimal comma here would quietly disagree with.
        guard rounded.truncatingRemainder(dividingBy: 1) != 0 else {
            return String(format: "%.0f", rounded)
        }
        // ⚠️ THE SECOND DECIMAL IS DROPPED WHEN IT IS A ZERO, which is what makes
        // 318.5 minutes read as "318.5" here and on Android rather than "318.50".
        // Two clients disagreeing on the rendering of one metered figure is the kind
        // of difference an operator reports as a billing discrepancy.
        let text = String(format: "%.2f", rounded)
        return text.hasSuffix("0") ? String(text.dropLast()) : text
    }

    /// What an ABSENT metric renders as.
    ///
    /// ⛔ WORDS RATHER THAN A DASH, AND IT SAYS "NOT METERED" RATHER THAN "0". A
    /// metric with no rows has no key on the wire, which is a different fact from
    /// one measured at zero, and these sit under billing-shaped labels — the one
    /// place a fabricated zero gets believed. Android renders an em dash here; this
    /// client spells it out, both because the repo's house style avoids em dashes
    /// and because "—" is read aloud as nothing at all by VoiceOver.
    static let absent = "Not metered"

    /// Add up several metered amounts, keeping "none of them was metered" distinct
    /// from "they summed to zero".
    ///
    /// ⛔ NIL IN EVERY POSITION IS NIL OUT, NOT `0`. Defaulting each absent metric to
    /// zero would let a month with no messaging rows render "0 messages", a
    /// billing-shaped claim nothing measured.
    ///
    /// ⚠️ A PARTIAL SUM IS A REAL ANSWER AND IS LABELLED AS ONE. If inbound minutes
    /// are metered and outbound are absent, the total is the inbound figure — which
    /// is why the caller's label says METERED rather than "total call minutes".
    static func sumMetered(_ values: Double?...) -> Double? {
        var total: Double?
        for value in values {
            guard let value, value.isFinite else { continue }
            total = (total ?? 0) + value
        }
        return total
    }

    /// Each value's share of its own maximum, for a bar scaled against its siblings.
    ///
    /// ⛔ AN ALL-ZERO OR ALL-ABSENT SERIES YIELDS ZEROS RATHER THAN `NaN`. A month
    /// whose only metered row was a phone-number count produces exactly that input,
    /// and `value / 0` does not throw in floating point — it poisons every width
    /// downstream and draws a chart that looks like a rendering bug.
    ///
    /// ⚠️ NON-FINITE VALUES ARE TREATED AS ABSENT in both the maximum and the
    /// output. A NaN admitted into the maximum makes every comparison against it
    /// false, so the whole series would scale to zero and the card would silently
    /// show flat bars over real usage.
    static func normalized(_ values: [Double?]) -> [Double] {
        let usable = values.map(plottable)
        let maximum = usable.max() ?? 0
        guard maximum > 0 else { return usable.map { _ in 0 } }
        return usable.map { $0 / maximum }
    }

    /// A `YYYY-MM` usage month as a short display label.
    ///
    /// ⛔ A FIXED LOOKUP, NOT `DateFormatter`. ``UsageMonth/month`` is a calendar key
    /// the server builds from UTC month boundaries — it is not an instant and it has
    /// no timezone — so parsing it into a date and formatting it back is how a month
    /// silently shifts by one for a reader west of UTC.
    ///
    /// ⚠️ ANYTHING UNRECOGNISED IS RETURNED VERBATIM. The raw `2026-08` is still a
    /// true statement about which month the row is, which "Unknown" is not.
    static func monthLabel(_ month: String) -> String {
        let parts = month.split(separator: "-")
        guard parts.count == 2, parts[0].count == 4, Int(parts[0]) != nil else { return month }
        guard let ordinal = Int(parts[1]), (1 ... monthNames.count).contains(ordinal) else { return month }
        return "\(monthNames[ordinal - 1]) \(parts[0])"
    }

    /// Parse a server-supplied hex colour, or nil if it cannot be read.
    ///
    /// ⛔ LENIENT AND OPTIONAL ON PURPOSE. ``SentimentSlice/color`` is chosen
    /// server-side and nothing constrains its format; the caller falls back to a
    /// theme token. Modelling it as a colour in the DTO would let a presentational
    /// detail fail the whole analytics response, losing every metric on the screen
    /// over a shade.
    ///
    /// Accepts `#rgb` and `#rrggbb`, with or without the leading `#`. ⚠️ An
    /// eight-digit `#aarrggbb` is REFUSED rather than half-read: Android accepts it
    /// because Compose packs ARGB, while ``Color/init(districtHex:)`` here takes
    /// 24 bits, and silently dropping an alpha channel would render a deliberately
    /// translucent band as opaque.
    static func hexColor(_ hex: String) -> Color? {
        var digits = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.hasPrefix("#") {
            digits.removeFirst()
        }
        let expanded = digits.count == 3 ? digits.flatMap { [$0, $0] } : Array(digits)
        guard expanded.count == 6, let value = UInt32(String(expanded), radix: 16) else { return nil }
        return Color(districtHex: value)
    }

    /// A value's contribution to a bar's geometry: absent, non-finite and negative
    /// all draw as zero.
    ///
    /// ⛔ THE ABSENCE IS FLATTENED HERE AND NOWHERE ELSE. There is no honest bar to
    /// draw for a metric nobody metered, so the geometry treats it as zero — while
    /// the LABEL beside it still comes from the nullable value and says so. Carrying
    /// the absence into the number is the mistake; carrying it into the width is
    /// unavoidable.
    private static func plottable(_ value: Double?) -> Double {
        guard let value, value.isFinite else { return 0 }
        return max(value, 0)
    }

    /// ⚠️ HERE RATHER THAN IN ANY COPY TABLE: this is a decoding table keyed by an
    /// integer the SERVER chose, not user-facing prose with a translation.
    private static let monthNames = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ]
}
