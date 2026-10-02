import DistrictData
import DistrictModel
import Foundation
import XCTest

/// The bookings table's query, its columns and its detail.
final class SchedulingBookingFormatTests: XCTestCase {
    private typealias Booking = SchedulingBookingFormat

    // MARK: - listParams

    /// ⚠️ ONLY `upcoming` ORDERS ASCENDING, because the next booking is the one that
    /// matters; the other three are newest-first.
    func testOnlyUpcomingOrdersAscending() {
        for view in SchedulingBookingView.allCases {
            let params = Booking.listParams(for: SchedulingBookingQuery(view: view))
            XCTAssertEqual(params.order, view == .upcoming ? "asc" : "desc", "\(view)")
        }
    }

    func testEachViewNarrowsWithItsOwnPairOfKeys() {
        let upcoming = Booking.listParams(for: SchedulingBookingQuery(view: .upcoming))
        XCTAssertEqual(upcoming.when, "upcoming")
        XCTAssertEqual(upcoming.status, "confirmed")

        let past = Booking.listParams(for: SchedulingBookingQuery(view: .past))
        XCTAssertEqual(past.when, "past")
        XCTAssertEqual(past.status, "confirmed")

        let cancelled = Booking.listParams(for: SchedulingBookingQuery(view: .cancelled))
        XCTAssertNil(cancelled.when)
        XCTAssertEqual(cancelled.status, "cancelled")
    }

    /// ⚠️ `all` SENDS NEITHER KEY, which is what makes it "all".
    func testAllSendsNeitherNarrowingKey() {
        let params = Booking.listParams(for: SchedulingBookingQuery(view: .all))
        XCTAssertNil(params.when)
        XCTAssertNil(params.status)
    }

    /// ⛔ AN EMPTY FILTER IS OMITTED AND NEVER SENT AS `""`. An empty `event_type` is not
    /// "any" to the fork; it is a slug matching nothing, and the empty 200 it answers
    /// reads exactly like a workspace with no bookings.
    func testEmptyFiltersAreOmittedRatherThanSentBlank() {
        let params = Booking.listParams(for: SchedulingBookingQuery())
        XCTAssertNil(params.from)
        XCTAssertNil(params.to)
        XCTAssertNil(params.eventTypeSlug)
        XCTAssertNil(params.host)
        XCTAssertNil(params.team)
    }

    func testSetFiltersTravel() {
        let query = SchedulingBookingQuery(
            view: .all,
            from: "2026-09-01",
            to: "2026-09-30",
            eventTypeSlug: "intro",
            host: "u1",
            team: "t1",
            limit: 50,
            offset: 25,
            workspaceWide: true
        )
        let params = Booking.listParams(for: query)
        XCTAssertEqual(params.from, "2026-09-01")
        XCTAssertEqual(params.to, "2026-09-30")
        XCTAssertEqual(params.eventTypeSlug, "intro")
        XCTAssertEqual(params.host, "u1")
        XCTAssertEqual(params.team, "t1")
        XCTAssertEqual(params.limit, 50)
        XCTAssertEqual(params.offset, 25)
        XCTAssertTrue(params.allHosts)
    }

    // MARK: - statusLabel

    func testTheThreeKnownStatusesGetTheirOwnWording() {
        XCTAssertEqual(Booking.statusLabel("confirmed"), SchedulingStatusLabel(label: "Confirmed", kind: .success))
        XCTAssertEqual(Booking.statusLabel("cancelled"), SchedulingStatusLabel(label: "Cancelled", kind: .error))
        XCTAssertEqual(Booking.statusLabel("rescheduled"), SchedulingStatusLabel(label: "Rescheduled", kind: .info))
    }

    /// ⛔ AN UNKNOWN BOOKING STATUS IS ECHOED VERBATIM, which is the OPPOSITE of what
    /// `recordingState` does. Both are asserted so a tidy-up cannot unify them.
    func testAnUnknownBookingStatusIsEchoed() {
        XCTAssertEqual(Booking.statusLabel("no_show"), SchedulingStatusLabel(label: "no_show", kind: .info))
    }

    // MARK: - bookingDateTime

    /// ⛔ ABSOLUTE, WITH A YEAR, UNLIKE THE REGISTER'S RELATIVE FORM.
    func testTheTableRendersAnAbsoluteStampWithAYear() {
        XCTAssertEqual(
            Booking.bookingDateTime(startAt: "2026-09-12T10:00:00Z", timezone: "UTC"),
            "Sep 12, 2026, 10:00"
        )
    }

    /// ⚠️ UNPADDED HOUR, PADDED MINUTE — the same shape as the register and NOT the
    /// recordings table's.
    func testTheTableHourIsUnpadded() {
        XCTAssertEqual(
            Booking.bookingDateTime(startAt: "2026-09-12T09:05:00Z", timezone: "UTC"),
            "Sep 12, 2026, 9:05"
        )
    }

    func testTheTableStampIsZoned() {
        XCTAssertEqual(
            Booking.bookingDateTime(startAt: "2026-09-12T02:00:00Z", timezone: "America/Toronto"),
            "Sep 11, 2026, 22:00"
        )
    }

    func testAnUnparseableStampIsNil() {
        XCTAssertNil(Booking.bookingDateTime(startAt: "soon", timezone: "UTC"))
    }

    // MARK: - minutesLabel

    func testMinutesLabelNamesAnAbsentValue() {
        XCTAssertEqual(Booking.minutesLabel(30), "30 min")
        XCTAssertEqual(Booking.minutesLabel(nil), "Not set")
        XCTAssertEqual(Booking.minutesLabel(0), "0 min")
    }

    // MARK: - attendeeEmail

    /// ⚠️ EMPTY RATHER THAN A PLACEHOLDER: it draws a second line under the name, and a
    /// dash there would look like lost data.
    func testTheAttendeeEmailIsEmptyWhenAbsent() throws {
        XCTAssertEqual(try Booking.attendeeEmail(SchedulingFixture.booking()), "")
        XCTAssertEqual(
            try Booking.attendeeEmail(SchedulingFixture.booking(attendees: #"[{"name":"Ada"}]"#)),
            ""
        )
        XCTAssertEqual(
            try Booking.attendeeEmail(SchedulingFixture.booking(attendees: #"[{"email":"  a@b.com "}]"#)),
            "a@b.com"
        )
    }

    // MARK: - isActionable

    /// ⛔ JUDGED ON `endAt`, NOT `startAt`: a meeting that started ten minutes ago is
    /// still cancellable and one that ended ten minutes ago is not.
    func testActionabilityIsJudgedOnTheEndAndNotTheStart() throws {
        let now = try XCTUnwrap(WireInstant.parse("2026-09-12T10:10:00Z"))
        let running = try SchedulingFixture.booking(
            start: "2026-09-12T10:00:00Z",
            end: "2026-09-12T11:00:00Z"
        )
        XCTAssertTrue(Booking.isActionable(running, now: now))

        let finished = try SchedulingFixture.booking(
            start: "2026-09-12T09:00:00Z",
            end: "2026-09-12T10:00:00Z"
        )
        XCTAssertFalse(Booking.isActionable(finished, now: now))
    }

    func testACancelledBookingIsNeverActionable() throws {
        let now = try XCTUnwrap(WireInstant.parse("2026-09-12T10:00:00Z"))
        let cancelled = try SchedulingFixture.booking(
            start: "2026-09-12T14:00:00Z",
            end: "2026-09-12T15:00:00Z",
            status: "cancelled"
        )
        XCTAssertFalse(Booking.isActionable(cancelled, now: now))
    }

    func testAnUnparseableEndIsNotActionable() throws {
        let now = try XCTUnwrap(WireInstant.parse("2026-09-12T10:00:00Z"))
        let broken = try SchedulingFixture.booking(end: "later")
        XCTAssertFalse(Booking.isActionable(broken, now: now))
    }

    // MARK: - Views

    func testTheViewLabelsAreTheWebsInOrder() {
        XCTAssertEqual(
            SchedulingBookingView.allCases.map(\.label),
            ["Upcoming", "Past", "Cancelled", "All"]
        )
    }
}
