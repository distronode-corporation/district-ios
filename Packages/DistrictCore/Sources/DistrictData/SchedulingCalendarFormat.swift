import DistrictModel
import Foundation

/// The calendar screen's read half, ported from `calendar-format.ts`.
///
/// ⚠️ THE OAuth LEG IS NOT HERE AND IS NOT AN OVERSIGHT. `calendarConnectHref`,
/// `rememberConnectingProvider`, `takeConnectingProvider` and `calendarErrorSentence`
/// are the browser's double-encoded hand-off, its `sessionStorage` round trip and the
/// sentence for a failed return. The app's connect flow is a browser sheet the screen
/// re-reads after (`SchedulingCalendarConnectModel`), so none of the four has a caller.
public enum SchedulingCalendarFormat {
    /// ⚠️ THE FOUR THE FORK KNOWS. Anything else falls through to its own raw value,
    /// which is a provider this build has not heard of rather than an error.
    static let providerLabels = [
        "google": "Google Calendar",
        "microsoft": "Microsoft 365",
        "caldav": "CalDAV",
        "apple": "Apple Calendar",
    ]

    public static func providerLabel(_ provider: String) -> String {
        providerLabels[provider] ?? provider
    }

    /// What is checked for conflicts on one connection.
    ///
    /// ⛔ THREE DIFFERENT ANSWERS AND THE DIFFERENCE MATTERS. A nil `calendars` means the
    /// per-connection read FAILED or has not run, so the honest answer is the
    /// connection-level boolean ("Checked" / "Not checked") — a coarse but true summary.
    /// An empty selection means the read SUCCEEDED and nothing is selected, which is
    /// "None" and is a real and different state. Collapsing the two would report "None"
    /// for a connection whose calendars simply had not loaded, which is the opposite of
    /// what the operator needs to know before relying on conflict checking.
    public static func conflictSummary(
        connection: SchedulingCalendarConnection,
        calendars: [SchedulingCalendarSelection]?
    ) -> String {
        guard let calendars else {
            return connection.checkConflicts ? "Checked" : "Not checked"
        }
        let names = calendars.filter { $0.checkConflicts == true }.map(\.name)
        return names.isEmpty ? "None" : names.joined(separator: ", ")
    }

    /// Where bookings are written.
    ///
    /// ⚠️ "This account" IS NOT "No calendar in this account". The first means the fork
    /// will write somewhere in this account and has not been told which calendar; the
    /// second means it will not write here at all. Both are read off values the fork
    /// sends and neither is a guess.
    public static func destinationSummary(
        connection: SchedulingCalendarConnection,
        calendars: [SchedulingCalendarSelection]?
    ) -> String {
        if let chosen = calendars?.first(where: { $0.isDestination == true }) {
            return chosen.name
        }
        return connection.isDestination ? "This account" : "No calendar in this account"
    }
}
