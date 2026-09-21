import DistrictModel
import Foundation

/// The status pill's label and tone.
///
/// ⚠️ A NAMED TYPE RATHER THAN A LABELLED TUPLE, which is a compile-risk decision
/// rather than a style one. ``SchedulingPresentation/badge`` is a switch EXPRESSION
/// with a `nil` branch (the shape ``OverviewEntry/caption`` already proves builds),
/// and an unlabelled tuple literal in the other branches would ask the type checker
/// to add tuple labels AND inject into an Optional across branches at the same time
/// — an error that surfaces only in the full SwiftUI build.
struct SchedulingBadge {
    let label: String
    let tone: Tone
}

/// Every sentence this screen can say.
///
/// ⚠️ HOISTED TO `String` CONSTANTS RATHER THAN WRITTEN INLINE, for the reason
/// `DevicesView` records: a `+` concatenation handed straight to an API with both
/// a `LocalizedStringKey` and a `StringProtocol` overload is an inference question
/// at the call site, and the error surfaces only in the full SwiftUI build. A
/// named `String` picks the second unambiguously.
///
/// ⚠️ ONE PLACE, SHARED WITH ``SchedulingModel``. The enable route's 403 means the
/// workspace is not on the allowlist, which is the same fact ``notEligible``
/// states, and two copies of that sentence is two copies that drift.
enum SchedulingCopy {
    static let notEligible = "Scheduling is not enabled for this workspace."

    static let switchedOff = "Scheduling is turned off for this workspace."

    static let legacy = "Scheduling is available for this workspace. "
        + "Turn it on to give customers a booking page of their own."

    static let provisioning = "Your booking page is being set up. This usually takes under a minute, "
        + "and it is re-checked automatically every hour if anything stalls."

    static let live = "Your booking page is live."

    static let failedProvision = "Setup did not finish."

    /// ⛔ THE ONE READY-STATE SENTENCE THAT IS NOT A FAILURE AND NOT A LINK. The
    /// row says `ready` and the server sent no `bookingUrl`, which is contract
    /// drift rather than an outage, so it says what it can and offers no address.
    static let liveWithoutLink = "This workspace has a booking page, but the server did not send its address."

    static let enable = "Enable scheduling"

    static let enabling = "Setting up…"

    static let refresh = "Refresh"

    /// ⛔ "Open in browser" RATHER THAN "Manage scheduling". This button is not how you
    /// manage scheduling (the nine sections are), it is how you reach what is not native
    /// YET. The label says exactly that, and ``sectionsFootnote`` says it in a sentence
    /// underneath.
    static let openInBrowser = "Open in browser"

    static let opening = "Opening…"

    static let copyLink = "Copy link"

    static let copied = "Link copied"

    static let tooManyAttempts = "Too many attempts, try again in an hour."

    static let notReadyYet = "Scheduling is not ready yet. Turn it on, or wait for setup to finish."

    /// ⚠️ USED ONLY WHEN A 202 CARRIED `ok: false` AND NO SENTENCE. The server's
    /// own `error` is the product whenever it sends one.
    static let enableFailedFallback = "Setting up scheduling did not finish, and no reason was recorded."

    static func hostLine(_ host: String) -> String {
        "Served from \(host)"
    }

    static func setupFailed(_ reason: String?) -> String {
        guard let reason, !reason.isEmpty else {
            return "\(failedProvision) No reason was recorded."
        }
        return "\(failedProvision) \(reason)"
    }

    static func lastReadyLine(_ stamp: String) -> String {
        "Last checked \(SchedulingTimestamp.display(stamp))"
    }
}

/// Turns the status route's ISO-8601 string into something a person reads.
///
/// ⛔ BUILT PER CALL RATHER THAN HELD IN A `static let`. `ISO8601DateFormatter` is
/// a reference type and is not `Sendable`, so a shared instance is a Swift 6
/// concurrency error rather than an optimisation, and this runs once per redraw of
/// one label.
///
/// ⚠️ TWO FORMATS ARE TRIED BECAUSE ONE IS NOT ENOUGH. `NextResponse.json`
/// serialises a `Date` through `JSON.stringify`, which emits fractional seconds —
/// and `ISO8601DateFormatter` REJECTS those unless `withFractionalSeconds` is set,
/// while a string without them is rejected when it is. Neither option parses both.
///
/// ⚠️ FALLS BACK TO THE RAW STRING. An unparseable stamp is still true, and a
/// blank line where a date should be reads as missing data.
enum SchedulingTimestamp {
    static func display(_ raw: String) -> String {
        guard let date = parse(raw) else { return raw }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private static func parse(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }
}

extension SchedulingPresentation {
    var sentence: String {
        switch self {
        case .notEligible: SchedulingCopy.notEligible
        case .legacy: SchedulingCopy.legacy
        case .provisioning: SchedulingCopy.provisioning
        case .live: SchedulingCopy.live
        // ⚠️ The reason itself is drawn by ``SchedulingView/detail(_:)`` so it can
        // carry the danger tone on its own line.
        case .failedProvision: SchedulingCopy.failedProvision
        case .switchedOff: SchedulingCopy.switchedOff
        }
    }

    /// ⚠️ ONLY THE ONE STATE WHERE SOMETHING WENT WRONG. "not admitted" and
    /// "switched off" are ordinary answers and painting them red would report a
    /// fault that did not happen.
    var isFailure: Bool {
        if case .failedProvision = self {
            return true
        }
        return false
    }

    /// ⚠️ A BADGE ONLY WHERE THERE IS A TENANCY ROW, matching the web card: the
    /// pill reports the ROW's status, and there is nothing to report without one.
    var badge: SchedulingBadge? {
        switch self {
        case .notEligible, .legacy: nil
        case .provisioning: SchedulingBadge(label: "Setting up", tone: .info)
        case .live: SchedulingBadge(label: "Live", tone: .success)
        case .failedProvision: SchedulingBadge(label: "Needs attention", tone: .danger)
        case .switchedOff: SchedulingBadge(label: "Switched off", tone: .neutral)
        }
    }
}

extension SchedulingCopy {
    /// ⚠️ THE EYEBROW OVER THE SECTION LIST. "Manage" rather than "Sections", because the
    /// list is the point of the screen and its own noun would describe the furniture.
    static let sectionsEyebrow = "Manage"

    /// ⛔ IT SAYS WHY THERE IS STILL A BUTTON OUT OF THE APP, AND IT MUST NOT NAME THE
    /// WEBSITE. App Store Review Guideline 3.1.1 covers steering toward an external
    /// surface as well as the purchase itself, which is also why ``FailureText``'s 402
    /// sentence names no domain. "In a browser" is a capability, not a destination.
    static let sectionsFootnote = "These sections are read-only for now. "
        + "Anything that changes a booking page opens in a browser."

    /// One row's title. ⚠️ The web's own section names, so an operator who has used the
    /// dashboard finds the same word here.
    static func sectionTitle(_ section: SchedulingSection) -> String {
        switch section {
        case .hub: "Scheduling"
        case .overview: "Overview"
        case .eventTypes: "Event types"
        case .eventType: "Event type"
        case .hours: "Working hours"
        case .bookings: "Bookings"
        case .booking: "Booking"
        case .calendar: "Calendar"
        case .team: "Team"
        case .recordings: "Recordings"
        case .settings: "Settings"
        case .developer: "Developer"
        }
    }

    /// One row's second line.
    ///
    /// ⛔ EACH ONE SAYS WHAT THE SECTION HOLDS RATHER THAN RESTATING ITS TITLE. A subtitle
    /// that paraphrases the row above it is a line of text that costs a thumb-scroll and
    /// tells nobody anything; these are compressed from the web pages' own subtitles, which
    /// were written for the same job. ⚠️ `Recordings` deliberately does not say "Your
    /// recordings": a recording belongs to the workspace, and the web's page header carries
    /// a comment making the same point.
    static func sectionSubtitle(_ section: SchedulingSection) -> String? {
        switch section {
        case .hub, .eventType, .booking: nil
        case .overview: "Your booking desk, and what is coming up"
        case .eventTypes: "The pages a customer can book, and how long each one runs"
        case .hours: "The weekly hours you are bookable, and the dates you are not"
        case .bookings: "Every booking in this workspace, upcoming and past"
        case .calendar: "The accounts bookings are written to and checked against"
        case .team: "The hosts who can be booked, and the teams they route through"
        case .recordings: "Recordings of booked meetings, with their notes and transcripts"
        case .settings: "Your booking page, your recordings, and how the scheduler treats you"
        case .developer: "API keys, connected apps and webhooks"
        }
    }
}
