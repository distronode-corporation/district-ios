import DistrictModel
import Foundation

/// One notification switch, as the settings screen groups them.
public struct SchedulingNotificationSwitch: Equatable, Sendable {
    /// ⚠️ THE WIRE FIELD NAME, which is also what the write stage patches. Carried so the
    /// read screen and the eventual form agree on which row is which without a second
    /// table.
    public let field: String
    public let label: String
}

/// A heading, its explanation, and the switches under it.
public struct SchedulingNotificationGroup: Equatable, Sendable {
    public let heading: String
    public let description: String
    public let switches: [SchedulingNotificationSwitch]
}

/// The settings screen's read half, ported from `settings-format.ts`.
///
/// ⛔ THE VALIDATORS ARE NOT HERE AND THAT IS THE STAGE BOUNDARY. `brandingPatchFrom`,
/// `profilePatchFrom`, `legalUrlProblem` and `wholeNumberIn` exist to refuse a FORM, and
/// there is no form yet; each carries its own sentence, and shipping nine unreachable
/// error strings would put copy in front of the coverage gate that nothing can exercise.
/// ⚠️ What IS here is every table that turns a stored value into a label, because that is
/// what a read screen does with `me.get` and `settings.branding.get`.
public enum SchedulingSettingsFormat {
    /// ⚠️ THE FOUR TABS, IN THE WEB'S ORDER. The ids are the `?tab=` values, so a link
    /// out of the dashboard names the same tab here.
    public static let settingsTabIds = ["booking-page", "recordings", "profile", "notifications"]

    public static let settingsTabLabels = [
        "Booking page", "Recordings and notes", "Your profile", "Your notifications",
    ]

    /// `12h` → `12-hour (2:30 pm)`.
    ///
    /// ⚠️ THE EXAMPLE TIME IS PART OF THE LABEL. "12-hour" alone is ambiguous to somebody
    /// who has not thought about it; the sample is what makes the choice obvious, and it
    /// is what the web shows.
    public static func timeFormatLabel(_ value: String) -> String {
        switch value {
        case "12h": "12-hour (2:30 pm)"
        case "24h": "24-hour (14:30)"
        default: value
        }
    }

    /// `dmy` → `31/12/2026`.
    ///
    /// ⚠️ THE LABELS ARE EXAMPLES RATHER THAN PATTERNS, so nothing here is a format
    /// string and none of it is locale-aware. A `DateFormatter` would render the example
    /// in the DEVICE's locale and stop matching the stored choice it is naming.
    public static func dateFormatLabel(_ value: String) -> String {
        switch value {
        case "dmy": "31/12/2026"
        case "mdy": "12/31/2026"
        case "ymd": "2026-12-31"
        default: value
        }
    }

    /// `0` → `Sunday`.
    ///
    /// ⚠️ SUNDAY-INDEXED, LIKE THE WIRE'S `day_of_week` AND UNLIKE
    /// ``SchedulingHoursFormat/weekDayNames``, WHICH IS MONDAY-FIRST FOR THE GRID. The two
    /// live one screen apart and mean different things; the conversion between them is
    /// ``SchedulingHoursFormat/displayDay(_:)`` and neither table may be used for the
    /// other's job.
    public static func weekStartLabel(_ value: Int) -> String {
        let days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        guard value >= 0, value < days.count else { return String(value) }
        return days[value]
    }

    /// The language a visitor gets when we do not have theirs.
    ///
    /// ⚠️ THE CODE IS SHOWN WHEN THE SUPPORTED LIST DOES NOT NAME IT, rather than being
    /// blanked. A fallback locale the tenancy no longer supports is a real configuration
    /// problem, and hiding it would make the row read as unset.
    public static func localeLabel(
        code: String,
        supported: [SchedulingLocaleOption]?
    ) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Not set" }
        guard let match = supported?.first(where: { $0.code == trimmed }) else { return trimmed }
        return match.name.isEmpty ? trimmed : match.name
    }

    /// Whether recordings can be written at all, and the sentence that says why not.
    ///
    /// ⛔ THE DESCRIPTION CHANGES WITH `recordingsStorageReady`, NOT WITH THE TOGGLE. A
    /// region with no storage cannot record whatever the switch says, and describing the
    /// feature as if it were merely off would leave an operator turning it on and waiting
    /// for recordings that can never arrive.
    public static func recordingDescription(_ settings: SchedulingStorageSettings) -> String {
        settings.recordingsStorageReady == false
            ? "Recording storage is not enabled for this region yet, so meetings cannot be recorded."
            : "Meetings held on the built-in video are recorded to your workspace's storage."
    }

    /// ⚠️ THE TWO GROUPS AND THEIR SEVEN SWITCHES, IN THE WEB'S ORDER. The split is by
    /// WHOSE meeting it is — one set fires when you are booked into somebody else's, the
    /// other when somebody books yours — which is why the headings are not "Email" and
    /// "Push".
    public static let notificationGroups: [SchedulingNotificationGroup] = [
        SchedulingNotificationGroup(
            heading: "As an attendee",
            description: "When you are the one being booked into somebody else's meeting.",
            switches: [
                SchedulingNotificationSwitch(field: "notify_confirmation", label: "A booking is confirmed"),
                SchedulingNotificationSwitch(field: "notify_cancellation", label: "A booking is cancelled"),
                SchedulingNotificationSwitch(field: "notify_reschedule", label: "A booking is moved"),
                SchedulingNotificationSwitch(field: "notify_reminder", label: "A booking is coming up"),
            ]
        ),
        SchedulingNotificationGroup(
            heading: "As a host",
            description: "When somebody books one of your event types.",
            switches: [
                SchedulingNotificationSwitch(field: "notify_host_booking", label: "Somebody books you"),
                SchedulingNotificationSwitch(field: "notify_host_cancel", label: "Somebody cancels"),
                SchedulingNotificationSwitch(field: "notify_host_reschedule", label: "Somebody moves their booking"),
            ]
        ),
    ]

    /// The value of one notification switch on a profile.
    ///
    /// ⛔ A LOOKUP BY WIRE NAME RATHER THAN SEVEN KEY PATHS, so that
    /// ``notificationGroups`` stays a table and the screen stays a loop. ⚠️ An unknown
    /// field answers nil rather than false: "we do not know" and "it is off" are
    /// different, and a row that cannot be read should not be drawn as a deliberate
    /// choice the operator made.
    public static func notificationValue(_ field: String, on me: SchedulingMe) -> Bool? {
        switch field {
        case "notify_confirmation": me.notifyConfirmation
        case "notify_cancellation": me.notifyCancellation
        case "notify_reschedule": me.notifyReschedule
        case "notify_reminder": me.notifyReminder
        case "notify_host_booking": me.notifyHostBooking
        case "notify_host_cancel": me.notifyHostCancel
        case "notify_host_reschedule": me.notifyHostReschedule
        default: nil
        }
    }
}
