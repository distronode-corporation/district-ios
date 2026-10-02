import DistrictModel
import Foundation

/// The recordings screen's read half, ported from `recording-format.ts`.
public enum SchedulingRecordingFormat {
    /// `Sep 3, 2026, 14:05`, or nil.
    ///
    /// ⛔ THE HOUR IS ZERO-PADDED HERE AND UNPADDED IN THE BOOKINGS TABLE, AND THAT IS
    /// THE SOURCE'S INCONSISTENCY PRESERVED RATHER THAN A MISTAKE. See the ⛔ on
    /// ``SchedulingClock``: making the two agree would put this client out of step with
    /// the browser on a value an operator can compare directly.
    public static func recordedWhen(createdAt: String?, timezone: String) -> String? {
        guard let createdAt, let at = WireInstant.parse(createdAt) else { return nil }
        let parts = SchedulingClock.parts(of: at, timezone: timezone)
        guard let month = SchedulingClock.monthName(parts.month) else { return nil }
        return "\(month) \(parts.day), \(parts.year), \(SchedulingClock.paddedClock(parts))"
    }

    /// `45 s`, `12 min`, `1 h`, `1 h 5 min`, or `Not finished`.
    ///
    /// ⛔ ZERO IS `Not finished` AND NEVER `0 s`. A recording still running, one that
    /// failed before it wrote anything, and one whose duration the fork has not computed
    /// all arrive as zero or absent; "0 s" would assert a completed recording of no
    /// length, which is the one thing none of them is.
    ///
    /// ⚠️ SECONDS ROUND AND MINUTES AND HOURS FLOOR. That is the source's arithmetic:
    /// 90 seconds is `1 min`, not `2 min`, and 59.6 seconds is `60 s`, not `1 min`.
    public static func recordingDuration(_ seconds: Int?) -> String {
        guard let seconds, seconds > 0 else { return "Not finished" }
        if seconds < 60 {
            return "\(seconds) s"
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes) min"
        }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    /// Recording / Complete / Failed / Unknown.
    ///
    /// ⛔ AN UNKNOWN STATUS IS **NOT** ECHOED HERE, WHICH IS THE OPPOSITE CALL FROM
    /// ``SchedulingBookingFormat/statusLabel(_:)`` AND BOTH ARE THE SOURCE'S. The
    /// difference is what the word would mean: a booking status is a business state an
    /// operator can act on, so a new one is worth showing raw; a recording status is a
    /// pipeline state, and a raw `pending_upload` in a State column reads as a fault
    /// rather than as progress. "Unknown" says exactly as much as this build knows.
    public static func recordingState(_ status: String) -> SchedulingStatusLabel {
        switch status {
        case "active": SchedulingStatusLabel(label: "Recording", kind: .inProgress)
        case "complete": SchedulingStatusLabel(label: "Complete", kind: .success)
        case "failed": SchedulingStatusLabel(label: "Failed", kind: .error)
        default: SchedulingStatusLabel(label: "Unknown", kind: .pending)
        }
    }

    /// Who the meeting was with, or `Someone`.
    public static func recordingWho(_ recording: SchedulingRecording) -> String {
        let name = recording.bookerName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "Someone" : name
    }

    /// What one participant answered when told the meeting was being recorded.
    ///
    /// ⛔ RENDER WHAT IT SAYS AND FILL NO GAPS. These rows are the evidence for a
    /// two-party-consent jurisdiction, and `pending` is a real and common state — the
    /// guest left before the prompt resolved — which is never "granted by default". The
    /// repository's own header makes the same demand on the way in.
    ///
    /// ⚠️ "No answer recorded" IS THE DEFAULT ARM, so a decision string this build does
    /// not know reads as an absence rather than as a consent. That is the safe direction
    /// for this particular value and the only one worth defaulting to.
    public static func consentDecision(_ decision: String) -> SchedulingStatusLabel {
        switch decision {
        case "continue": SchedulingStatusLabel(label: "Agreed to be recorded", kind: .success)
        case "leave": SchedulingStatusLabel(label: "Left the meeting", kind: .stopped)
        default: SchedulingStatusLabel(label: "No answer recorded", kind: .pending)
        }
    }

    /// A participant's name, their identity, or `Unnamed participant`.
    public static func consentWho(_ consent: SchedulingRecordingConsent) -> String {
        let name = consent.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !name.isEmpty {
            return name
        }
        let identity = consent.identity.trimmingCharacters(in: .whitespacesAndNewlines)
        return identity.isEmpty ? "Unnamed participant" : identity
    }

    /// `Stored` or `None`.
    ///
    /// ⚠️ ABSENT IS `None`, NOT `Stored`. A row whose `has_file` the fork did not send
    /// has no proven object behind it, and the download beside it would 404 — see the ⚠️
    /// on ``SchedulingAdminMediaRepository/recordingDownloadURL(workspaceId:recordingId:)``,
    /// which answers a 404 with a JSON body rather than a redirect and therefore arrives
    /// as a generic unknown failure.
    public static func fileLabel(_ hasFile: Bool?) -> String {
        hasFile == true ? "Stored" : "None"
    }
}
