import DistrictData
import Foundation

/// The wording for the hours, bookings, calendar, team, recordings, settings and
/// developer sections.
///
/// ⚠️ ONE FILE FOR SEVEN SECTIONS RATHER THAN SEVEN FILES, because every one of them is a
/// short table of labels and SwiftLint's 500-line file limit is comfortably met. The
/// overview and the event types have their own files because each carries a
/// derivation as well as a table.
extension SchedulingCopy {
    // MARK: - Working hours

    /// ⚠️ THE WEB'S OWN SENTENCE FOR A WEEK WITH NO RULES AT ALL. "No working hours" would
    /// read as a load failure; this states the consequence.
    static let hoursNoneAtAll = "Not bookable on any day yet."

    static let overridesEyebrow = "Date overrides"
    static let overridesSubtitle = "Days you are away, or working different hours from usual."
    static let overridesEmpty = "No overrides ahead."

    /// ⛔ "Not bookable" RATHER THAN A BLANK FOR A DAY WITH NO HOURS. An empty value beside
    /// a weekday is indistinguishable from a row that failed to load, which on an
    /// availability grid is the one confusion worth spending a word to avoid.
    static func dayHours(_ ranges: [SchedulingHoursRange]) -> String {
        guard !ranges.isEmpty else { return "Not bookable" }
        let show = SchedulingOverviewSummary.displayTime
        return ranges.map { "\(show($0.start)) to \(show($0.end))" }.joined(separator: ", ")
    }

    // MARK: - Bookings

    static let bookingsEmptyTitle = "No bookings"
    static let loadMore = "Load more"
    static let loadingMore = "Loading…"

    /// ⛔ THE EMPTY SENTENCE DEPENDS ON THE VIEW, because "there are none" means different
    /// things per filter. Telling somebody looking at Cancelled to "share your booking
    /// page" would be advice for a problem they do not have.
    static func bookingsEmptyBody(_ view: SchedulingBookingView) -> String {
        switch view {
        case .upcoming:
            "Nothing is booked yet. Share your booking page and bookings appear here."
        case .past:
            "No past bookings."
        case .cancelled:
            "No cancelled bookings."
        case .all:
            "Nothing is booked yet. Share your booking page and bookings appear here."
        }
    }

    static func bookingSubtitle(who: String, eventType: String, host: String) -> String {
        "\(who) · \(eventType) · \(host)"
    }

    // MARK: - Booking detail

    static let answersEyebrow = "Answers"
    static let notesEyebrow = "Notes"
    static let transcriptEyebrow = "Transcript"

    static let noNotes = "No notes for this booking."
    static let noTranscript = "No transcript for this booking."

    /// ⛔ A 424 IS AN UNCONFIGURED REGION AND NOT A FAULT. The generic sentence would send
    /// somebody hunting for an outage; this names a cause an operator can act on. See the
    /// ⚠️ on ``SchedulingBookingDetailModel`` for why it is also used for the genuinely
    /// unknown case.
    static let mediaUnavailable = "Recording storage is not enabled for this region."

    // MARK: - Calendar

    static let loadingCalendar = "Loading calendar…"
    static let calendarAccount = "Account"
    static let calendarConflicts = "Checked for conflicts"
    static let calendarDestination = "Receives bookings"
    static let calendarZoom = "Zoom"
    static let calendarConnectEyebrow = "Connecting a calendar"

    static let connected = "Connected"
    static let notConnected = "Not connected"

    static let calendarNoneConnected = "No calendar is connected yet, so nothing is "
        + "checked for conflicts and bookings are not written anywhere."

    static let calendarConnectAnother = "Another account can be connected to check it "
        + "for conflicts as well."

    /// ⚠️ NOT A FAULT AND NOT THE OPERATOR'S TO FIX. A tenancy whose instance has no
    /// calendar providers configured cannot connect one at all.
    static let calendarNotConfigured = "Calendar connections are not set up on this "
        + "scheduler yet."

    // MARK: - Team

    static let strandedEyebrow = "Someone who has left still has bookings"
    static let membersEyebrow = "Members"
    static let membersEmpty = "Nobody else is in this workspace yet."

    /// ⛔ SHOWN INSTEAD OF ROLE LABELS WHEN THE MEMBERSHIP READ FAILED. Without it every
    /// host would be captioned "Removed from the workspace", which is a false accusation
    /// drawn from an absent read rather than from a fact.
    static let membersDegraded = "The workspace's members could not be read, so roles are "
        + "not shown."

    static let teamsEyebrow = "Teams"
    static let teamsSubtitle = "A team rotates bookings through its hosts, in "
        + "routing-priority order."
    static let teamsEmpty = "No teams yet."

    static func memberSubtitle(email: String, role: String?) -> String {
        guard let role else { return email }
        return "\(email) · \(role)"
    }

    static func memberCount(_ count: Int) -> String {
        count == 1 ? "1 member" : "\(count) members"
    }

    // MARK: - Recordings

    static let loadingRecordings = "Loading recordings…"
    static let recordingsEmptyTitle = "No recordings"
    static let recordingsEmptyBody = "A recorded meeting appears here when it ends."

    static let recordingsNoStorage = "Recording storage is not enabled for this region yet. "
        + "Meetings already recorded are listed below; new ones cannot be stored and none "
        + "can be played."

    static let recordingWith = "Meeting with"
    static let recordingDuration = "Duration"
    static let recordingFile = "File"
    static let recordingState = "State"
    static let recordingPlay = "Play"
    /// ⚠️ NO WEB ORIGINAL: the shared catch-all ("That did not save") describes a write,
    /// and pressing Play saves nothing.
    static let recordingPlayFailed = "That recording could not be opened. Try again."
    static let recordingConsent = "Consent"

    /// ⛔ "Nobody answered" IS NOT "everybody agreed". These rows are the evidence for a
    /// two-party-consent jurisdiction and an empty set means the prompt resolved for
    /// nobody, which is a fact rather than a default.
    static let consentEmpty = "Nobody answered the recording notice for this meeting."

    // MARK: - Settings

    static let brandingBusinessName = "Business name"
    static let brandingLogo = "Logo"
    static let brandingBanner = "Banner"
    static let brandingPrivacy = "Privacy policy link"
    static let brandingTerms = "Terms link"
    static let brandingLocale = "Page language"

    static let recordingsEnabled = "Record built-in video meetings"
    static let notetakerEnabled = "Write AI meeting notes"
    static let assistantEnabled = "Booking assistant"
    static let assistantInstructions = "Extra instructions"

    static let profileName = "Name"
    static let profileTimezone = "Timezone"
    static let profileTimeFormat = "Time format"
    static let profileWeekStart = "Week starts on"
    static let profileDateFormat = "Date format"

    /// ⚠️ "Set"/"Not set" FOR AN IMAGE RATHER THAN ITS URL. A logo's address is a long
    /// opaque string that tells an operator nothing they can act on, and the image itself
    /// is not what this read-only row is for.
    static let set = "Set"
    static let notSet = "Not set"

    static func onOff(_ value: Bool) -> String {
        value ? "On" : "Off"
    }

    // MARK: - Developer

    static let keysEyebrow = "Your API keys"
    static let keysSubtitle = "A key lets your own tools and scripts reach this "
        + "workspace's booking data."
    static let keysEmpty = "No API keys yet."

    static let mcpEyebrow = "Connect an AI assistant"
    static let mcpUrlLabel = "MCP URL"
    static let mcpAuthLabel = "Authorization header"
    static let mcpNoHost = "Your booking address is not ready yet. It appears here once "
        + "scheduling is set up."

    /// ⛔ IT SAYS THERE ARE NO PARTIAL PERMISSIONS, WHICH IS THE WHOLE SECURITY STORY OF
    /// THIS INTEGRATION. Anyone holding a key can do everything in the tool list, so the
    /// only way to narrow an assistant is to give it its own key and revoke that.
    static let mcpNote = "Use a key from the API keys tab. Anyone holding it can do "
        + "everything on this workspace's bookings, so give each assistant its own and "
        + "revoke it when you are done with it."

    static let appsEyebrow = "Connected apps"
    static let appsSubtitle = "Every connected app reaches the same booking data. There "
        + "are no partial permissions, so revoking is the only way to narrow one."
    static let appsEmpty = "No connected apps."

    static let webhooksEyebrow = "Webhooks"
    static let webhooksSubtitle = "Bookings already reach your District inbox and "
        + "workflows; webhooks are for other systems."
    static let webhooksEmpty = "No webhooks yet."

    static let deliveries = "Deliveries"
    static let deliveriesEmpty = "Nothing delivered yet."

    /// ⛔ THE ABSENT MARKER IS PER COLUMN AND THE THREE ARE NOT INTERCHANGEABLE. "Never"
    /// means a key that has not been used; "Not tried yet" means a delivery that has not
    /// run; the em dash means a value that is simply missing. Collapsing them would lose a
    /// distinction each column was worded for.
    static let never = "Never"
    static let notTriedYet = "Not tried yet"

    static func keyValue(created: String, lastUsed: String) -> String {
        "Created \(created) · Last used \(lastUsed)"
    }
}
