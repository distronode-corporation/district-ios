import DistrictData
import DistrictModel
import Foundation
import XCTest

/// The calendar screen's connection summaries.
final class SchedulingCalendarFormatTests: XCTestCase {
    private typealias Calendar = SchedulingCalendarFormat

    func testTheFourKnownProvidersGetRealNames() {
        XCTAssertEqual(Calendar.providerLabel("google"), "Google Calendar")
        XCTAssertEqual(Calendar.providerLabel("microsoft"), "Microsoft 365")
        XCTAssertEqual(Calendar.providerLabel("caldav"), "CalDAV")
        XCTAssertEqual(Calendar.providerLabel("apple"), "Apple Calendar")
    }

    /// ⚠️ AN UNKNOWN PROVIDER IS ITS OWN RAW VALUE — a provider this build has not heard
    /// of, not an error.
    func testAnUnknownProviderIsEchoed() {
        XCTAssertEqual(Calendar.providerLabel("fastmail"), "fastmail")
    }

    // MARK: - conflictSummary

    /// ⛔ THREE DIFFERENT ANSWERS AND THE DIFFERENCE MATTERS. nil means the per-connection
    /// read failed, so the coarse connection-level boolean is the honest answer; an empty
    /// ARRAY means the read succeeded and nothing is selected. Reporting "None" for the
    /// first would tell an operator conflict checking is off when it may well be on.
    func testAFailedCalendarReadFallsBackToTheConnectionBoolean() throws {
        let checking = try SchedulingFixture.calendarConnection(checkConflicts: true)
        XCTAssertEqual(Calendar.conflictSummary(connection: checking, calendars: nil), "Checked")

        let notChecking = try SchedulingFixture.calendarConnection(checkConflicts: false)
        XCTAssertEqual(Calendar.conflictSummary(connection: notChecking, calendars: nil), "Not checked")
    }

    func testAnEmptySelectionIsNoneAndNotAFallback() throws {
        let connection = try SchedulingFixture.calendarConnection(checkConflicts: true)
        XCTAssertEqual(Calendar.conflictSummary(connection: connection, calendars: []), "None")
    }

    func testSelectedCalendarsAreListedInOrder() throws {
        let connection = try SchedulingFixture.calendarConnection()
        let calendars = try [
            SchedulingFixture.calendarSelection(id: "a", name: "Work", checkConflicts: true),
            SchedulingFixture.calendarSelection(id: "b", name: "Personal", checkConflicts: false),
            SchedulingFixture.calendarSelection(id: "c", name: "Travel", checkConflicts: true),
        ]
        XCTAssertEqual(
            Calendar.conflictSummary(connection: connection, calendars: calendars),
            "Work, Travel"
        )
    }

    /// ⚠️ AN ABSENT `check_conflicts` ON A SELECTION IS NOT SELECTED. The comparison is
    /// against `true` explicitly, so nil does not count.
    func testAnAbsentFlagOnASelectionDoesNotCount() throws {
        let connection = try SchedulingFixture.calendarConnection()
        let calendars = try [SchedulingFixture.calendarSelection(name: "Work")]
        XCTAssertEqual(Calendar.conflictSummary(connection: connection, calendars: calendars), "None")
    }

    // MARK: - destinationSummary

    func testAChosenDestinationCalendarWins() throws {
        let connection = try SchedulingFixture.calendarConnection(isDestination: true)
        let calendars = try [
            SchedulingFixture.calendarSelection(id: "a", name: "Work", isDestination: false),
            SchedulingFixture.calendarSelection(id: "b", name: "Bookings", isDestination: true),
        ]
        XCTAssertEqual(
            Calendar.destinationSummary(connection: connection, calendars: calendars),
            "Bookings"
        )
    }

    /// ⚠️ "This account" AND "No calendar in this account" ARE DIFFERENT FACTS. The first
    /// means bookings are written somewhere here; the second means they are not written
    /// here at all.
    func testTheTwoAccountLevelAnswersAreDifferentFacts() throws {
        let destination = try SchedulingFixture.calendarConnection(isDestination: true)
        XCTAssertEqual(
            Calendar.destinationSummary(connection: destination, calendars: nil),
            "This account"
        )

        let notDestination = try SchedulingFixture.calendarConnection(isDestination: false)
        XCTAssertEqual(
            Calendar.destinationSummary(connection: notDestination, calendars: []),
            "No calendar in this account"
        )
    }
}
