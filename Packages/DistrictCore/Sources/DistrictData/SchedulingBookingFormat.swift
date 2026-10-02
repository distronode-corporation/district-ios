import DistrictModel
import Foundation

/// Which slice of the bookings feed a screen is asking for.
///
/// ⚠️ FOUR VIEWS AND ONLY ONE OF THEM ORDERS ASCENDING. `upcoming` is read
/// soonest-first because the next booking is the one that matters; the other three are
/// newest-first. That is the source's rule and it is why ``SchedulingBookingFormat`` owns
/// the whole query rather than the screen assembling it.
public enum SchedulingBookingView: String, Equatable, Sendable, CaseIterable {
    case upcoming
    case past
    case cancelled
    case all

    /// ⚠️ The filter control's labels, in the web's order.
    public var label: String {
        switch self {
        case .upcoming: "Upcoming"
        case .past: "Past"
        case .cancelled: "Cancelled"
        case .all: "All"
        }
    }
}

/// Everything the bookings screen filters on, before it becomes wire parameters.
public struct SchedulingBookingQuery: Equatable, Sendable {
    public var view: SchedulingBookingView
    /// `YYYY-MM-DD`, or empty for "any".
    public var from: String
    public var to: String
    /// ⚠️ A SLUG, NOT AN ID. `bookings.list` filters event types by slug, and an unknown
    /// one is an empty 200 rather than a 404 — so an empty page is never evidence the
    /// filter was understood. See the ⚠️ on the repository's `bookings` method.
    public var eventTypeSlug: String
    public var host: String
    public var team: String
    public var limit: Int
    public var offset: Int
    /// ⛔ HONOURED ONLY FOR A SCHEDULER ADMIN AND SILENTLY IGNORED OTHERWISE, so a screen
    /// must not present the result as the whole tenancy's bookings on the strength of
    /// having asked.
    public var workspaceWide: Bool

    public init(
        view: SchedulingBookingView = .upcoming,
        from: String = "",
        to: String = "",
        eventTypeSlug: String = "",
        host: String = "",
        team: String = "",
        limit: Int = 25,
        offset: Int = 0,
        workspaceWide: Bool = false
    ) {
        self.view = view
        self.from = from
        self.to = to
        self.eventTypeSlug = eventTypeSlug
        self.host = host
        self.team = team
        self.limit = limit
        self.offset = offset
        self.workspaceWide = workspaceWide
    }
}

/// The arguments one page of `bookings.list` is fetched with.
///
/// ⚠️ A VALUE RATHER THAN A CALL, so that the mapping from a filter row to the wire can
/// be asserted without a transport. Every field lines up with a parameter of the
/// repository method, and ``SchedulingBookingFormat/listParams(for:)`` is the only thing
/// that builds one.
public struct SchedulingBookingListParams: Equatable, Sendable {
    public let status: String?
    public let when: String?
    public let from: String?
    public let to: String?
    public let eventTypeSlug: String?
    public let host: String?
    public let team: String?
    public let limit: Int
    public let offset: Int
    public let allHosts: Bool
    public let order: String
}

/// The bookings table and the booking detail, ported from `booking-format.ts`.
public enum SchedulingBookingFormat {
    /// Turn the filter row into the read's parameters.
    ///
    /// ⛔ AN EMPTY FILTER IS OMITTED AND NEVER SENT AS `""`. The catalog validates these,
    /// and an empty `event_type` is not "any event type" to the fork — it is a slug that
    /// matches nothing, which comes back as an empty 200 that reads exactly like a
    /// workspace with no bookings. ⚠️ And an unknown slug answers the same empty 200, so
    /// an empty page is never evidence the filter was understood.
    ///
    /// ⚠️ `all` SETS NEITHER `when` NOR `status`, which is what makes it "all": the two
    /// keys are the narrowing, so the view that narrows nothing sends neither.
    public static func listParams(for query: SchedulingBookingQuery) -> SchedulingBookingListParams {
        var status: String?
        var when: String?
        switch query.view {
        case .upcoming:
            when = "upcoming"
            status = "confirmed"
        case .past:
            when = "past"
            status = "confirmed"
        case .cancelled:
            status = "cancelled"
        case .all:
            break
        }
        return SchedulingBookingListParams(
            status: status,
            when: when,
            from: blankAsNil(query.from),
            to: blankAsNil(query.to),
            eventTypeSlug: blankAsNil(query.eventTypeSlug),
            host: blankAsNil(query.host),
            team: blankAsNil(query.team),
            limit: query.limit,
            offset: query.offset,
            allHosts: query.workspaceWide,
            order: query.view == .upcoming ? "asc" : "desc"
        )
    }

    /// Confirmed / Cancelled / Rescheduled, or the raw status.
    ///
    /// ⚠️ AN UNKNOWN STATUS IS ECHOED VERBATIM rather than shown as "Unknown". A status
    /// the fork added since this build shipped is still meaningful to an operator, and
    /// replacing it would throw away the only information the row had.
    /// ⛔ ``SchedulingRecordingFormat/recordingState(_:)`` makes the OPPOSITE call on
    /// purpose; the difference is noted there.
    public static func statusLabel(_ status: String) -> SchedulingStatusLabel {
        switch status {
        case "confirmed": SchedulingStatusLabel(label: "Confirmed", kind: .success)
        case "cancelled": SchedulingStatusLabel(label: "Cancelled", kind: .error)
        case "rescheduled": SchedulingStatusLabel(label: "Rescheduled", kind: .info)
        default: SchedulingStatusLabel(label: status, kind: .info)
        }
    }

    /// `Sep 12, 2026, 10:00`, or nil.
    ///
    /// ⛔ ABSOLUTE AND WITH A YEAR, UNLIKE THE REGISTER'S
    /// ``SchedulingOverviewSummary/bookingWhen(startAt:timezone:now:)``. This table is a
    /// record rather than a glance, and "Today" in a row somebody scrolled to yesterday
    /// is a claim that goes stale while it is on screen.
    ///
    /// ⚠️ UNPADDED HOUR, PADDED MINUTE. See the ⛔ on ``SchedulingClock``.
    public static func bookingDateTime(startAt: String, timezone: String) -> String? {
        guard let start = WireInstant.parse(startAt) else { return nil }
        let at = SchedulingClock.parts(of: start, timezone: timezone)
        guard let month = SchedulingClock.monthName(at.month) else { return nil }
        return "\(month) \(at.day), \(at.year), \(SchedulingClock.clock(at))"
    }

    /// `30 min`, or `Not set`.
    ///
    /// ⚠️ THE PORT OF `minutesLabel` FROM `event-type-format.ts`, WHICH IS WHERE THE
    /// EVENT-TYPES TABLE GETS ITS DURATION AND ITS INTERVAL COLUMNS. It lives here rather
    /// than in a ninth file because it is one function.
    public static func minutesLabel(_ minutes: Int?) -> String {
        guard let minutes else { return "Not set" }
        return "\(minutes) min"
    }

    /// The first attendee's email, trimmed, or empty.
    ///
    /// ⚠️ EMPTY RATHER THAN A PLACEHOLDER. It sits UNDER the name in the Who column, so
    /// an absent address draws no second line at all; a dash there would be a row that
    /// looks like it lost data.
    public static func attendeeEmail(_ booking: SchedulingBooking) -> String {
        booking.attendees?.first?.email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Whether a booking can still be acted on, judged on when it ENDS.
    ///
    /// ⛔ ON `endAt` AND NOT ON `startAt`, which is the difference between "this meeting
    /// is running" and "this meeting is over". A booking that started ten minutes ago is
    /// still cancellable; one that ended ten minutes ago is not. ⚠️ Nothing in this READ
    /// stage calls it — it is what the write stage's Cancel and Reschedule controls gate
    /// on, and it is ported here because it is a property of the row rather than of the
    /// form.
    public static func isActionable(_ booking: SchedulingBooking, now: Date = Date()) -> Bool {
        guard booking.status == "confirmed" else { return false }
        guard let end = WireInstant.parse(booking.endAt) else { return false }
        return end > now
    }

    static func blankAsNil(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }
}
