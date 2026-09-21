import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// The typed `calendar.*` and `zoom.status` wrappers.
///
/// ⛔ THE ACCOUNT ADDRESS HAS TWO WIRE SPELLINGS ACROSS ONE ENDPOINT PAIR, and
/// these tests are where that is pinned. The GET and the DELETE take it as
/// `account`; the PUT and the destination write take it as `account_email`. The
/// Swift parameter is `accountEmail` on all four so a caller never has to know,
/// and getting the mapping backwards is an `invalid_params` naming a field the
/// caller did send — which is the least legible failure on this surface.
final class SchedulingAdminCalendarRepositoryTests: XCTestCase {
    private func repository(_ transport: RepositoryTransport) -> SchedulingAdminRepository {
        SchedulingAdminRepository(client: .repositoryTest(transport), reportUnknownOp: { _ in })
    }

    /// The `NO_CONTENT` rewrite: an outer flag and an inner one.
    private static let noContent = #"{"ok":true,"data":{"ok":true}}"#

    // MARK: - Status

    /// ⚠️ A `NO_PARAMS` OP STILL SENDS `"params":{}` RATHER THAN DROPPING THE KEY.
    /// The route defaults an absent `params` to `{}` as well, so sending it makes
    /// the agreement a contract rather than a coincidence.
    func testCalendarStatusSendsAnEmptyParamsObject() async throws {
        let transport = RepositoryTransport(
            json: #"""
            {"ok":true,"data":{"connected":true,"configured":true,"providers":["google"],
             "connections":[{"id":"c_1","provider":"google","account_email":"a@test",
                             "is_destination":true,"check_conflicts":true}],
             "unconfigured_providers":null,"provider":"google"}}
            """#
        )
        let status = try await repository(transport).calendarStatus(workspaceId: "ws_1")
        XCTAssertTrue(status.connected)
        XCTAssertEqual(status.providers, ["google"])
        // ⛔ THE NULL THAT BREAKS THE CALENDAR PAGE WHEN MISTYPED, carried end to end.
        XCTAssertNil(status.unconfiguredProviders)
        XCTAssertEqual(status.connections.count, 1)
        XCTAssertEqual(transport.bodies, [#"{"op":"calendar.status","params":{},"workspaceId":"ws_1"}"#])
    }

    // MARK: - CalDAV

    /// ⛔ THE WIRE FIELD IS `app_password`. Fastmail, iCloud and Zimbra all require
    /// an application-specific credential here rather than the account password,
    /// and `password` is not a key the schema knows.
    func testConnectingCaldavSendsTheApplicationPasswordUnderItsOwnKey() async throws {
        let transport = RepositoryTransport(
            json: #"{"ok":true,"data":{"connected":true,"account_email":"contract@fastmail.test"}}"#
        )
        let connection = try await repository(transport).connectCaldav(
            workspaceId: "ws_1",
            username: "contract",
            appPassword: "secret-app-password"
        )
        XCTAssertTrue(connection.connected)
        // ⚠️ WHAT THE SERVER RESOLVED, not what was sent: the username was not an
        // address and the answer is.
        XCTAssertEqual(connection.accountEmail, "contract@fastmail.test")
        XCTAssertEqual(
            transport.bodies,
            [
                #"{"op":"calendar.caldav.connect","params":{"app_password":"secret-app-password","#
                    + #""username":"contract"},"workspaceId":"ws_1"}"#,
            ]
        )
    }

    /// ⚠️ THE ENCODER ESCAPES `/` AS `\/`, WHICH IS LEGAL JSON AND SURPRISING IN A
    /// BYTE-FOR-BYTE ASSERTION. `JSONWire` writes through `JSONSerialization`,
    /// whose default output escapes forward slashes; the server reads it as the
    /// same string. Pinned here rather than worked around, because the next test
    /// that asserts a URL in a body will hit it and read it as a bug.
    func testConnectingCaldavWithAPresetAndAServerUrlCarriesBoth() async throws {
        let transport = RepositoryTransport(
            json: #"{"ok":true,"data":{"connected":true,"account_email":"a@test"}}"#
        )
        _ = try await repository(transport).connectCaldav(
            workspaceId: "ws_1",
            username: "contract",
            appPassword: "pw",
            preset: "fastmail",
            serverUrl: "https://caldav.fastmail.test"
        )
        XCTAssertEqual(
            transport.bodies,
            [
                #"{"op":"calendar.caldav.connect","params":{"app_password":"pw","preset":"fastmail","#
                    + #""server_url":"https:\/\/caldav.fastmail.test","username":"contract"},"workspaceId":"ws_1"}"#,
            ]
        )
    }

    // MARK: - The calendars inside a connection

    /// ⚠️ `account` ON THE GET. And the container key is `calendars`, unwrapped
    /// here so callers do not have to know either.
    func testReadingAConnectionsCalendarsSendsAccountAndUnwrapsTheContainer() async throws {
        let transport = RepositoryTransport(
            json: #"""
            {"ok":true,"data":{"calendars":[{"id":"a@test","name":"Work","primary":true,
             "writable":true,"check_conflicts":true,"is_destination":true},
             {"id":"holidays@group.test","name":"Statutory holidays"}]}}
            """#
        )
        let calendars = try await repository(transport).connectionCalendars(
            workspaceId: "ws_1",
            connectionId: "c_1",
            provider: "google",
            accountEmail: "a@test"
        )
        XCTAssertEqual(calendars.count, 2)
        XCTAssertEqual(calendars[0].id, "a@test")
        // ⛔ THE SUBSCRIPTION ROW: two keys, four absent flags.
        XCTAssertNil(calendars[1].writable)
        XCTAssertEqual(
            transport.bodies,
            [
                #"{"op":"calendar.connections.calendars.get","params":{"account":"a@test","id":"c_1","#
                    + #""provider":"google"},"workspaceId":"ws_1"}"#,
            ]
        )
    }

    /// ⛔ `account_email` ON THE PUT, AND THE FLAGS THE GET DID NOT REPORT ARE
    /// DROPPED RATHER THAN SENT AS `false`. Absent and `false` are different
    /// statements to the fork, so a holiday calendar has to go back the way it came.
    func testWritingACalendarSelectionSendsAccountEmailAndOmitsUnsetFlags() async throws {
        let transport = RepositoryTransport(json: Self.noContent)
        let answer = try await repository(transport).setConnectionCalendars(
            workspaceId: "ws_1",
            connectionId: "c_1",
            provider: "google",
            calendars: [
                SchedulingCalendarSelection(
                    id: "a@test",
                    name: "Work",
                    primary: true,
                    writable: true,
                    checkConflicts: false,
                    isDestination: true
                ),
                SchedulingCalendarSelection(id: "holidays@group.test", name: "Statutory holidays"),
            ],
            accountEmail: "a@test"
        )
        XCTAssertTrue(answer.ok)
        XCTAssertEqual(
            transport.bodies,
            [
                #"{"op":"calendar.connections.calendars.put","params":{"account_email":"a@test","calendars":"#
                    + #"[{"check_conflicts":false,"id":"a@test","is_destination":true,"name":"Work","primary":true,"#
                    + #""writable":true},{"id":"holidays@group.test","name":"Statutory holidays"}],"id":"c_1","#
                    + #""provider":"google"},"workspaceId":"ws_1"}"#,
            ]
        )
    }

    /// ⚠️ THE ACCOUNT IS OPTIONAL ON ALL FOUR CONNECTION OPS, so its absence must
    /// drop the key rather than send an empty string.
    func testWritingACalendarSelectionWithoutAnAccountDropsTheKey() async throws {
        let transport = RepositoryTransport(json: Self.noContent)
        _ = try await repository(transport).setConnectionCalendars(
            workspaceId: "ws_1",
            connectionId: "c_1",
            provider: "caldav",
            calendars: []
        )
        XCTAssertEqual(
            transport.bodies,
            [
                #"{"op":"calendar.connections.calendars.put","params":{"calendars":[],"id":"c_1","#
                    + #""provider":"caldav"},"workspaceId":"ws_1"}"#,
            ]
        )
    }

    func testSettingTheDestinationSendsAccountEmail() async throws {
        let transport = RepositoryTransport(json: Self.noContent)
        let answer = try await repository(transport).setDestinationConnection(
            workspaceId: "ws_1",
            connectionId: "c_1",
            provider: "google",
            accountEmail: "a@test"
        )
        XCTAssertTrue(answer.ok)
        XCTAssertEqual(
            transport.bodies,
            [
                #"{"op":"calendar.connections.destination","params":{"account_email":"a@test","id":"c_1","#
                    + #""provider":"google"},"workspaceId":"ws_1"}"#,
            ]
        )
    }

    /// ⚠️ `account` AGAIN ON THE DELETE — the same value as the destination write's
    /// `account_email`, one op apart.
    func testDeletingAConnectionSendsAccount() async throws {
        let transport = RepositoryTransport(json: Self.noContent)
        let answer = try await repository(transport).deleteCalendarConnection(
            workspaceId: "ws_1",
            connectionId: "c_1",
            provider: "google",
            accountEmail: "a@test"
        )
        XCTAssertTrue(answer.ok)
        XCTAssertEqual(
            transport.bodies,
            [
                #"{"op":"calendar.connections.delete","params":{"account":"a@test","id":"c_1","#
                    + #""provider":"google"},"workspaceId":"ws_1"}"#,
            ]
        )
    }

    // MARK: - Zoom

    func testZoomStatusIsAReadWithNoParams() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":{"configured":true,"connected":false}}"#)
        let status = try await repository(transport).zoomStatus(workspaceId: "ws_1")
        XCTAssertTrue(status.configured)
        XCTAssertFalse(status.connected)
        XCTAssertEqual(transport.bodies, [#"{"op":"zoom.status","params":{},"workspaceId":"ws_1"}"#])
    }

    /// ⛔ THE WHOLE NAMESPACE IS ADDRESSED BY NAME AND NOTHING HERE CARRIES A PATH,
    /// so every one of these goes to the single RPC route. A regression that sent a
    /// scheduler path instead would bypass the allowlist entirely.
    func testEveryCalendarOpGoesToTheOneRpcRoute() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":{"configured":true,"connected":true}}"#)
        _ = try await repository(transport).zoomStatus(workspaceId: "ws_1")
        XCTAssertEqual(transport.requestedURLs, ["https://www.distronode.com/api/district/scheduling/admin"])
    }
}
