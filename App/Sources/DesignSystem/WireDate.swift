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
        guard let zone else { return date.formatted(style) }
        var zoned = style
        zoned.timeZone = zone
        return date.formatted(zoned)
    }
}
