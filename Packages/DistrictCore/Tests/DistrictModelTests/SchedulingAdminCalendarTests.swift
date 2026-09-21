import DistrictModel
import Foundation
import XCTest

/// The `calendar.*` and `zoom.status` row DTOs, decoded from inline bytes.
///
/// ⛔ THE NULL BRANCH OF `calendar.status` LIVES HERE AND NOT IN THE ALLOWLIST,
/// AND THAT IS THE POINT OF THE FILE. `providers` and `unconfigured_providers`
/// are `.nullish()` on the server — Go slices the fork marshals without
/// `omitempty` — but the committed fixture carries REAL ARRAYS for both, and an
/// `allowedExplicitNulls` entry is permission for a null the bytes demonstrate.
/// Granting one for a null nobody has seen would widen the single escape the
/// gate's no-nulls invariant has, so the branch is proved from inline bytes
/// instead. `AllowedExplicitNulls+Inbox.swift` makes the same call for
/// `message.type`.
final class SchedulingAdminCalendarTests: XCTestCase {
    private let decoder = JSONDecoder()

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try decoder.decode(type, from: Data(json.utf8))
    }

    // MARK: - Status

    func testAConfiguredStatusCarriesBothProviderListsAndItsConnections() throws {
        let status = try decode(
            SchedulingCalendarStatus.self,
            #"""
            {"connected":true,"configured":true,"providers":["google","caldav"],
             "connections":[{"id":"c_1","provider":"google","account_email":"a@test",
                             "is_destination":true,"check_conflicts":true}],
             "unconfigured_providers":["microsoft"],"provider":"google"}
            """#
        )
        XCTAssertTrue(status.connected)
        XCTAssertTrue(status.configured)
        XCTAssertEqual(status.providers, ["google", "caldav"])
        XCTAssertEqual(status.unconfiguredProviders, ["microsoft"])
        XCTAssertEqual(status.provider, "google")
        XCTAssertEqual(status.connections.count, 1)
        XCTAssertEqual(status.connections[0].id, "c_1")
        XCTAssertEqual(status.connections[0].provider, "google")
        XCTAssertEqual(status.connections[0].accountEmail, "a@test")
        XCTAssertTrue(status.connections[0].isDestination)
        XCTAssertTrue(status.connections[0].checkConflicts)
    }

    /// ⛔ THE SHAPE THAT BREAKS THE CALENDAR PAGE WHEN MISSED. Both lists arrive
    /// as EXPLICIT NULLS on a fully configured instance — `unconfigured_providers`
    /// is nil exactly when Google and Microsoft are both set up, i.e. on every
    /// production tenant — and typing either `.optional()` rather than nullable
    /// makes the whole calendar page read "could not be read" for every customer.
    func testBothProviderListsDecodeFromAnExplicitNull() throws {
        let status = try decode(
            SchedulingCalendarStatus.self,
            #"""
            {"connected":true,"configured":true,"providers":null,"connections":[],
             "unconfigured_providers":null}
            """#
        )
        XCTAssertNil(status.providers)
        XCTAssertNil(status.unconfiguredProviders)
        // ⚠️ AND `provider` IS ABSENT HERE RATHER THAN NULL, which is a third
        // spelling of "nothing" on one object. A Swift Optional flattens all three.
        XCTAssertNil(status.provider)
        XCTAssertTrue(status.connections.isEmpty)
    }

    /// ⚠️ THE SAME FIELDS ALSO DECODE FROM AN ABSENT KEY. `.nullish()` permits
    /// both, and a DTO that handled only the null would throw on the other.
    func testBothProviderListsAlsoDecodeFromAnAbsentKey() throws {
        let status = try decode(
            SchedulingCalendarStatus.self,
            #"{"connected":false,"configured":false,"connections":[]}"#
        )
        XCTAssertNil(status.providers)
        XCTAssertNil(status.unconfiguredProviders)
        XCTAssertFalse(status.connected)
        XCTAssertFalse(status.configured)
    }

    /// ⛔ `connections` IS NOT NULLABLE AND MUST NOT BECOME SO BY SYMPATHY WITH ITS
    /// TWO NEIGHBOURS. The schema requires the key, so a body without it is drift.
    func testAStatusWithoutConnectionsIsRefused() {
        XCTAssertThrowsError(
            try decode(SchedulingCalendarStatus.self, #"{"connected":false,"configured":true}"#)
        )
    }

    // MARK: - CalDAV

    /// ⚠️ A CONFIRMATION, NOT A CONNECTION ROW: no id and no provider, so it cannot
    /// be appended to a cached `connections` array.
    func testACaldavConnectionCarriesTheResolvedAddress() throws {
        let connection = try decode(
            SchedulingCaldavConnection.self,
            #"{"connected":true,"account_email":"contract@fastmail.test"}"#
        )
        XCTAssertTrue(connection.connected)
        XCTAssertEqual(connection.accountEmail, "contract@fastmail.test")
    }

    // MARK: - The calendars inside a connection

    func testAFullySpecifiedCalendarCarriesAllFourFlags() throws {
        let selection = try decode(
            SchedulingCalendarSelection.self,
            #"""
            {"id":"a@test","name":"Contract Member","primary":true,"writable":true,
             "check_conflicts":true,"is_destination":true}
            """#
        )
        XCTAssertEqual(selection.id, "a@test")
        XCTAssertEqual(selection.name, "Contract Member")
        XCTAssertEqual(selection.primary, true)
        XCTAssertEqual(selection.writable, true)
        XCTAssertEqual(selection.checkConflicts, true)
        XCTAssertEqual(selection.isDestination, true)
    }

    /// ⛔ TWO KEYS IS A LEGAL CALENDAR, AND ALMOST EVERY GOOGLE ACCOUNT HAS ONE — a
    /// read-only subscription such as a holidays feed. ⚠️ Absent is not `false`:
    /// they render the same and they say different things, so nothing should
    /// substitute one for the other.
    func testASubscriptionCalendarCarriesOnlyItsIdAndName() throws {
        let selection = try decode(
            SchedulingCalendarSelection.self,
            #"{"id":"holidays@group.test","name":"Statutory holidays"}"#
        )
        XCTAssertNil(selection.primary)
        XCTAssertNil(selection.writable)
        XCTAssertNil(selection.checkConflicts)
        XCTAssertNil(selection.isDestination)
    }

    /// ⛔ THE CONTAINER KEY IS `calendars`, NOT `items`. Three envelope conventions
    /// live on this API and guessing gets it wrong a third of the time.
    func testTheCalendarsContainerUsesItsOwnKey() throws {
        let container = try decode(
            SchedulingCalendarSelections.self,
            #"{"calendars":[{"id":"a@test","name":"Work"}]}"#
        )
        XCTAssertEqual(container.calendars.count, 1)
        XCTAssertEqual(container.calendars[0].name, "Work")
        XCTAssertThrowsError(
            try decode(SchedulingCalendarSelections.self, #"{"items":[{"id":"a@test","name":"Work"}]}"#)
        )
    }

    // MARK: - Zoom

    /// ⚠️ THE PAIR THAT MATTERS: an instance WITH Zoom credentials whose member has
    /// not linked an account. It is the ordinary state of a new member and the one
    /// combination a screen has to offer an action for.
    func testZoomStatusSeparatesTheInstanceFromTheCaller() throws {
        let status = try decode(SchedulingZoomStatus.self, #"{"configured":true,"connected":false}"#)
        XCTAssertTrue(status.configured)
        XCTAssertFalse(status.connected)
    }

    func testZoomStatusRequiresBothFlags() {
        XCTAssertThrowsError(try decode(SchedulingZoomStatus.self, #"{"configured":true}"#))
    }
}
