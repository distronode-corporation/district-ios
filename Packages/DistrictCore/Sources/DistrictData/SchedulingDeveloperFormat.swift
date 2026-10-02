import DistrictModel
import Foundation

/// The developer screen's read half, ported from `developer-format.ts`.
public enum SchedulingDeveloperFormat {
    /// ⚠️ THE THREE TABS, IN THE WEB'S ORDER, WITH ITS `?tab=` IDS.
    public static let tabIds = ["keys", "apps", "webhooks"]

    public static let tabLabels = ["API keys", "Connected apps", "Webhooks"]

    /// ⛔ THE LITERAL PLACEHOLDER, AND A REAL KEY MUST NEVER BE INTERPOLATED IN ITS
    /// PLACE. The configuration snippet is copyable and a copied snippet ends up in a
    /// file, a chat message and a screenshot; the web holds a minted key in a modal and
    /// drops it when the modal closes, precisely so it never reaches a document. See the
    /// ⛔ on ``SchedulingAdminRepository/createAPIKey(workspaceId:name:)``.
    public static let mcpKeyPlaceholder = "<your API key>"

    /// ⛔ THE FOUR FIELDS THAT CARRY THE BOOKER'S OWN DETAILS OUT OF THIS PLATFORM. They
    /// are off by default in the console for that reason, and a screen that lists a
    /// webhook's fields should be able to say which of them are personal data without
    /// re-deriving the set. ⚠️ `host_name` and `host_email` are personal data too but are
    /// ON by default, because a host is a member of the workspace receiving the delivery;
    /// ``isPersonalDataField(_:)`` covers all six and this constant covers only the four
    /// that also default off.
    public static let attendeeWebhookFields = [
        "attendee_name", "attendee_email", "attendee_timezone", "answers",
    ]

    public static let personalDataWebhookFields =
        ["host_name", "host_email"] + attendeeWebhookFields

    public static func isPersonalDataField(_ field: String) -> Bool {
        personalDataWebhookFields.contains(field)
    }

    /// `https://<host>/mcp`, or empty when the host is not known yet.
    ///
    /// ⚠️ EMPTY RATHER THAN A GUESS. A tenancy still provisioning has no public host, and
    /// the screen says so in words instead of publishing an address that would not
    /// resolve.
    public static func mcpUrl(publicHost: String) -> String {
        let host = publicHost.trimmingCharacters(in: .whitespacesAndNewlines)
        return host.isEmpty ? "" : "https://\(host)/mcp"
    }

    /// Delivered / Waiting / Rejected with 500 / No answer, or the raw status.
    ///
    /// ⛔ A `failed` ROW WITH NO RESPONSE STATUS MEANS NOBODY ANSWERED, WHICH IS A
    /// DIFFERENT FACT FROM A REJECTION and the only way the row can say so. There is no
    /// error text anywhere to show, so this label is the whole diagnosis: "No answer"
    /// points at DNS, a firewall or a dead host, and "Rejected with 500" points at the
    /// receiving application.
    ///
    /// ⚠️ A RESPONSE STATUS OF ZERO IS TREATED AS ABSENT, matching the source's
    /// truthiness test. No HTTP response is status 0, so a stored zero is the fork's way
    /// of recording that there was none.
    public static func deliveryOutcome(status: String, responseStatus: Int?) -> SchedulingStatusLabel {
        switch status {
        case "success":
            return SchedulingStatusLabel(label: "Delivered", kind: .success)
        case "pending":
            return SchedulingStatusLabel(label: "Waiting", kind: .pending)
        case "failed":
            guard let code = responseStatus, code != 0 else {
                return SchedulingStatusLabel(label: "No answer", kind: .error)
            }
            return SchedulingStatusLabel(label: "Rejected with \(code)", kind: .error)
        default:
            return SchedulingStatusLabel(label: status, kind: .info)
        }
    }

    /// A timestamp for one of the developer tables, or the absent marker.
    ///
    /// ⛔ TWELVE-HOUR, WHICH IS INHERITED RATHER THAN CHOSEN AND IS THE ONE PLACE ON THIS
    /// SURFACE THAT IS. The web's `stamp` calls `formatInUserTimezone`, whose defaults set
    /// `hour12: true` and which `stamp` does not override — so `Sep 12, 2026, 10:05 AM` is
    /// what a browser renders in these four columns while every other scheduling table
    /// renders a 24-hour clock. Measured from the source rather than assumed, and
    /// reproduced so the two clients agree.
    ///
    /// ⚠️ THE DEFAULT ABSENT MARKER IS AN EM DASH (U+2014), and the callers pass their own
    /// where the column wants a word: `Never` for a key that has not been used, `Not tried
    /// yet` for a delivery that has not run. Those are per-column on purpose and are not
    /// interchangeable.
    public static func stamp(
        _ value: String?,
        timezone: String,
        absent: String = "—"
    ) -> String {
        guard let value, !value.isEmpty else { return absent }
        guard let date = WireInstant.parse(value) else { return "Unknown Date" }
        let parts = SchedulingClock.parts(of: date, timezone: timezone)
        guard let month = SchedulingClock.monthName(parts.month) else { return "Unknown Date" }
        let suffix = parts.hour < 12 ? "AM" : "PM"
        // ⚠️ 0 AND 12 BOTH RENDER AS 12, which is what a 12-hour clock does and what
        // `Intl` emits: midnight is `12:05 AM` and noon is `12:05 PM`.
        let rawHour = parts.hour % 12
        let hour = rawHour == 0 ? 12 : rawHour
        let minute = SchedulingClock.paddedTwo(parts.minute)
        return "\(month) \(parts.day), \(parts.year), \(SchedulingClock.paddedTwo(hour)):\(minute) \(suffix)"
    }
}
