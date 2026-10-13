import DistrictData
import Foundation

/// The calendar half of the write copy. Split from `+Developer.swift` for the
/// 500-line `file_length` ceiling that `swiftlint --strict` promotes to an error,
/// not for a boundary in the domain.
extension SchedulingWriteCopyC {
    // MARK: - Providers

    /// ⛔ THE LABEL COMES FROM ``SchedulingCalendarFormat/providerLabel(_:)`` AND
    /// IS NOT RESTATED HERE. The read screen already renders the library's
    /// four-entry table, so a second table would let one provider be worded two ways
    /// on the same screen the day the fork adds a fifth.
    static func connectProvider(_ provider: String) -> String {
        connectProviderNamed(SchedulingCalendarFormat.providerLabel(provider))
    }

    // MARK: - CalDAV

    /// ⛔ NAMES THE ADDRESS THE SERVER RESOLVED, NOT THE USERNAME THAT WAS SENT.
    /// CalDAV usernames are frequently not email addresses, and echoing back the
    /// submitted one would label the connection with something the provider does
    /// not recognise.
    static func caldavConnectedTo(_ accountEmail: String) -> String {
        caldavConnectedToLine(accountEmail)
    }
}
