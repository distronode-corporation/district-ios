import DistrictL10n
import DistrictModel
import Foundation

/// One API instant, as a person reads it: `Sep 12, 2026 at 2:30 PM`.
///
/// ⚠️ THE STYLE IS A `static let`, NOT BUILT PER ROW. `Date.FormatStyle` is a `Sendable`
/// value, and its default locale, calendar and zone are the AUTOUPDATING ones, so a
/// shared instance still follows a device that changes zone or language mid-session.
///
/// ⚠️ FALLS BACK TO THE RAW STRING. An unparseable instant is still true, and a blank
/// line where a date should be reads as missing data.
enum WireDate {
    private static let style = Date.FormatStyle(date: .abbreviated, time: .shortened)

    /// - Parameter zone: the zone to read the instant in. nil is the device's; a
    ///   scheduling surface passes the operator's profile zone instead.
    static func display(_ raw: String, in zone: TimeZone? = nil) -> String {
        guard let date = WireInstant.parse(raw) else { return raw }
        // ⛔ FRENCH IS THE CORE'S, NOT THE DEVICE'S: « 12 sept. 2026, 15 h 04 », as the
        // website writes it, on an fr-FR or fr-BE device too, which the system's own
        // French would write differently. English keeps the system style below.
        if AppL10n.copyLocale == .frCA {
            return unbroken(L10nFormat.dateTime(date, timezone: (zone ?? .current).identifier))
        }
        guard let zone else { return date.formatted(style) }
        var zoned = style
        zoned.timeZone = zone
        return date.formatted(zoned)
    }

    /// The French clock held on one line: `15 h 04` with no-break spaces (U+00A0), so a
    /// narrow line never ends on `15` and starts the next on `h 04`.
    ///
    /// ⚠️ HERE, NOT IN THE CORE'S `L10nFormat.time`: the core's string is compared with the
    /// website's and goes into catalog placeholders, and a change there is a core release.
    /// Only the space either side of the `h` changes; the date's spaces still wrap
    /// (3.2.0 visual QA: the call detail at accessibility XL broke `16` from `h 13`).
    static func unbroken(_ text: String) -> String {
        text.replacing(/(\d) h( \d|$)/) { match in
            let minutes = match.output.2.isEmpty ? "" : "\u{00A0}" + match.output.2.dropFirst()
            return "\(match.output.1)\u{00A0}h\(minutes)"
        }
    }
}
