import Foundation

/// The API's ISO-8601 instants, parsed once for every surface.
///
/// ⚠️ TWO FORMATS ARE TRIED BECAUSE ONE IS NOT ENOUGH. A `Date` serialised through
/// `JSON.stringify` (and Prisma's `createdAt`) carries fractional seconds, a row written
/// without them does not, and an ISO-8601 parser configured for one shape refuses the
/// other. The fractional shape is tried first because it is the common one.
///
/// ⚠️ `Date.ISO8601FormatStyle` RATHER THAN `ISO8601DateFormatter`, because the style is
/// a `Sendable` value and can be held in a `static let`; the formatter is a non-`Sendable`
/// class, so a shared one is a Swift 6 error and a per-call one was an allocation per row
/// render. The two agree on every shape the API sends; they differ only on inputs it
/// does not (the style keeps sub-millisecond digits, accepts a `:60` second and refuses
/// leading whitespace), measured on macOS and Linux alike.
///
/// ⛔ nil IS "THIS IS NOT A TIME" AND EVERY CALLER MUST SAY SO RATHER THAN GUESS. A screen
/// that fell back to `Date()` would show today's date for a row whose timestamp was
/// corrupt.
public enum WireInstant {
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plain = Date.ISO8601FormatStyle()

    public static func parse(_ raw: String) -> Date? {
        if let date = try? Date(raw, strategy: fractional) {
            return date
        }
        return try? Date(raw, strategy: plain)
    }
}
