@testable import DistrictAI
import DistrictData
import DistrictModel
import Foundation
import XCTest

/// CalDAV, the per-connection calendar picker, and unlinking an account.
@MainActor
final class SchedulingWritesCCalendarTests: XCTestCase {
    /// ⚠️ A VALUE NO OTHER STRING IN THE PROCESS COULD CONTAIN, so a substring
    /// search for it is evidence rather than a coincidence.
    private static let password = "caldav-app-pw-8f2c41d6"

    // MARK: - CalDAV

    /// ⛔ EXACTLY ONE OF `preset` AND `server_url` IS SENT. The fork prefers
    /// `server_url` when it is non-empty and only then falls back to the preset
    /// table, so sending both silently ignores whichever the host actually chose.
    func test_IOS_SCHW_C40_aPresetConnectSendsThePresetAndNoServerUrl() async {
        let transport = SchedulingWritesCTransport([
            .ok(#"{"connected":true,"account_email":"host@icloud.com"}"#),
        ])
        var changed = 0
        let model = SchedulingCaldavConnectModel(
            repository: .writesCTest(transport),
            workspaceId: "ws_1",
            onChanged: { changed += 1 }
        )
        model.preset = .fastmail
        model.username = "  host  "
        model.appPassword = Self.password
        await model.connect()

        let call = transport.calls.first
        XCTAssertEqual(transport.ops, ["calendar.caldav.connect"])
        XCTAssertEqual(call?.string("preset"), "fastmail")
        XCTAssertNil(call?.string("server_url"))
        XCTAssertEqual(call?.string("username"), "host")
        // ⛔ THE WIRE FIELD IS `app_password`, NOT `password`.
        XCTAssertEqual(call?.string("app_password"), Self.password)
        XCTAssertEqual(model.connectedAccountEmail, "host@icloud.com")
        XCTAssertEqual(changed, 1)
    }

    func test_IOS_SCHW_C41_aServerUrlConnectSendsTheUrlAndNoPreset() async {
        let transport = SchedulingWritesCTransport([
            .ok(#"{"connected":true,"account_email":"host@example.com"}"#),
        ])
        let model = SchedulingCaldavConnectModel(
            repository: .writesCTest(transport),
            workspaceId: "ws_1",
            onChanged: {}
        )
        model.preset = .nextcloud
        model.serverURL = " https://cloud.example.com/remote.php/dav "
        model.username = "host"
        model.appPassword = Self.password
        await model.connect()

        let call = transport.calls.first
        XCTAssertEqual(call?.string("server_url"), "https://cloud.example.com/remote.php/dav")
        XCTAssertNil(call?.string("preset"))
    }

    /// ⛔ THE PASSWORD IS NOT TRIMMED. It is bytes a provider generated; a leading
    /// or trailing space may be one of them, and trimming turns a correct
    /// credential into "could not connect".
    func test_IOS_SCHW_C42_theAppPasswordIsSentExactlyAsTyped() async {
        let padded = " \(Self.password) "
        let transport = SchedulingWritesCTransport([
            .ok(#"{"connected":true,"account_email":"host@icloud.com"}"#),
        ])
        let model = SchedulingCaldavConnectModel(
            repository: .writesCTest(transport),
            workspaceId: "ws_1",
            onChanged: {}
        )
        model.username = "host"
        model.appPassword = padded
        await model.connect()

        XCTAssertEqual(transport.calls.first?.string("app_password"), padded)
    }

    /// ⛔ THE CREDENTIAL LEAVES ONCE AND IS THEN GONE FROM EVERYTHING THIS PROCESS
    /// CAN BE ASKED FOR. Three places are checked because three are reachable: the
    /// requests this app made, the model that held it, and the one durable store an
    /// iOS app writes to without ceremony.
    func test_IOS_SCHW_C43_theAppPasswordIsSentOnceAndIsNotKeptAnywhere() async {
        let transport = SchedulingWritesCTransport([
            .ok(#"{"connected":true,"account_email":"host@icloud.com"}"#),
        ])
        let model = SchedulingCaldavConnectModel(
            repository: .writesCTest(transport),
            workspaceId: "ws_1",
            onChanged: {}
        )
        model.username = "host"
        model.appPassword = Self.password
        await model.connect()

        let carrying = transport.bodies.filter { $0.contains(Self.password) }
        XCTAssertEqual(carrying.count, 1, "the credential belongs in the connect call and nowhere else")
        XCTAssertEqual(model.appPassword, "", "a live model must not keep a credential it already spent")
        XCTAssertFalse(
            UserDefaults.standard.dictionaryRepresentation().values
                .contains { String(describing: $0).contains(Self.password) },
            "nothing on this path may write the credential to a durable store"
        )
    }

    /// ⛔ A REFUSED CREDENTIAL EARNS A SENTENCE THAT QUOTES NOTHING. The fork's own
    /// 4xx text is not available (the RPC answers a code and a status on purpose,
    /// because that text is remote and can quote whatever was sent to it), so the
    /// three things worth checking are named instead.
    func test_IOS_SCHW_C44_aRefusedConnectNamesWhatToCheckAndLeaksNothing() async {
        let transport = SchedulingWritesCTransport([.refusal("rejected")])
        let model = SchedulingCaldavConnectModel(
            repository: .writesCTest(transport),
            workspaceId: "ws_1",
            onChanged: { XCTFail("a refused connect changed nothing") }
        )
        model.username = "host"
        model.appPassword = Self.password
        await model.connect()

        XCTAssertEqual(model.failure?.message, SchedulingWriteCopyC.caldavRefused)
        XCTAssertFalse(model.failure?.message.contains(Self.password) == true)
    }

    /// ⚠️ A ROLE REFUSAL IS NOT A CREDENTIAL PROBLEM, so it keeps the shared
    /// sentence rather than telling somebody to re-check a password that was fine.
    func test_IOS_SCHW_C45_aForbiddenConnectDoesNotBlameTheCredentials() async {
        let transport = SchedulingWritesCTransport([.refused(status: 403)])
        let model = SchedulingCaldavConnectModel(
            repository: .writesCTest(transport),
            workspaceId: "ws_1",
            onChanged: {}
        )
        model.username = "host"
        model.appPassword = Self.password
        await model.connect()

        XCTAssertEqual(model.failure?.message, SchedulingWriteCopyC.forbidden)
    }

    func test_IOS_SCHW_C46_everyRefusedCaldavFormSpendsNoRequest() async {
        let transport = SchedulingWritesCTransport([])
        let model = SchedulingCaldavConnectModel(
            repository: .writesCTest(transport),
            workspaceId: "ws_1",
            onChanged: { XCTFail("nothing was connected") }
        )
        model.preset = .custom
        await model.connect()
        XCTAssertEqual(model.erroredField, .serverURL)
        XCTAssertEqual(model.fieldMessage, SchedulingWriteCopyC.caldavServerUrlMissing)

        model.serverURL = "http://cloud.example.com"
        await model.connect()
        XCTAssertEqual(model.fieldMessage, SchedulingWriteCopyC.caldavServerUrlNotHttps)

        model.serverURL = "https://2130706433/dav"
        await model.connect()
        XCTAssertEqual(model.fieldMessage, SchedulingWriteCopyC.caldavServerUrlIsIp)

        model.serverURL = "https://cloud.example.com/dav"
        await model.connect()
        XCTAssertEqual(model.erroredField, .username)

        model.username = "host"
        await model.connect()
        XCTAssertEqual(model.erroredField, .appPassword)

        XCTAssertTrue(transport.ops.isEmpty)
    }

    // MARK: - The calendars inside one account

    /// ⛔ THE PUT IS A REPLACE, SO EVERY ROW GOES BACK — INCLUDING THE READ-ONLY
    /// HOLIDAY CALENDAR NOBODY TOUCHED, WITH ITS FLAGS STILL ABSENT. Absent and
    /// `false` are not the same statement to the fork.
    func test_IOS_SCHW_C50_savingSendsEveryRowBackAndInventsNoFlags() async throws {
        let transport = SchedulingWritesCTransport([
            .ok(SchedulingWritesCRows.calendars),
            .noContent,
            .noContent,
        ])
        var changed = 0
        let connection: SchedulingCalendarConnection = try SchedulingWritesCRows
            .decode(SchedulingWritesCRows.calendarConnection)
        let model = SchedulingCalendarPickerModel(
            repository: .writesCTest(transport),
            workspaceId: "ws_1",
            connection: connection,
            onChanged: { changed += 1 }
        )
        await model.load()
        model.setCheckConflicts("work", on: true)
        await model.save()

        XCTAssertEqual(
            transport.ops,
            ["calendar.connections.calendars.get", "calendar.connections.calendars.put"]
        )
        let sent = transport.calls.last?.objects("calendars") ?? []
        XCTAssertEqual(sent.count, 2, "a calendar left out is a calendar turned off")
        let holidays = sent.first { $0["id"] as? String == "holidays" }
        XCTAssertNotNil(holidays)
        XCTAssertNil(holidays?["writable"], "an absent flag must not go back as false")
        XCTAssertNil(holidays?["check_conflicts"])
        XCTAssertEqual(sent.first { $0["id"] as? String == "work" }?["check_conflicts"] as? Bool, true)
        XCTAssertEqual(changed, 1)
        XCTAssertTrue(model.saved)
    }

    /// ⚠️ THE SECOND WRITE FIRES ONLY WHEN A DESTINATION WAS CHOSEN, and the PUT is
    /// the one that carries the calendars. `calendar.connections.destination` moves
    /// the ACCOUNT-level destination, which is belt and braces on the one choice
    /// whose silent failure is "I chose it and bookings still go somewhere else".
    func test_IOS_SCHW_C51_choosingADestinationAlsoMovesTheAccountLevelOne() async throws {
        let transport = SchedulingWritesCTransport([
            .ok(SchedulingWritesCRows.calendars),
            .noContent,
            .noContent,
        ])
        let connection: SchedulingCalendarConnection = try SchedulingWritesCRows
            .decode(SchedulingWritesCRows.calendarConnection)
        let model = SchedulingCalendarPickerModel(
            repository: .writesCTest(transport),
            workspaceId: "ws_1",
            connection: connection,
            onChanged: {}
        )
        await model.load()
        model.chooseDestination("work")
        await model.save()

        XCTAssertEqual(
            transport.ops,
            [
                "calendar.connections.calendars.get",
                "calendar.connections.calendars.put",
                "calendar.connections.destination",
            ]
        )
        let destination = transport.calls.last
        XCTAssertEqual(destination?.string("provider"), "google")
        // ⚠️ THE PUT AND THE DESTINATION WRITE TAKE `account_email`; the GET and the
        // DELETE take `account`. That is the server's schema, not a typo to tidy.
        XCTAssertEqual(destination?.string("account_email"), "host@example.com")
        XCTAssertEqual(model.destinationId, "work")
    }

    /// ⛔ ONLY WRITABLE CALENDARS MAY RECEIVE BOOKINGS, AND `writable == nil` COUNTS
    /// AS WRITABLE. Reading absence as "read only" would hide the primary calendar
    /// of an account whose GET happened to omit the flag.
    func test_IOS_SCHW_C52_theDestinationChoicesKeepARowWithNoWritableFlag() async throws {
        let transport = SchedulingWritesCTransport([.ok(SchedulingWritesCRows.calendars)])
        let connection: SchedulingCalendarConnection = try SchedulingWritesCRows
            .decode(SchedulingWritesCRows.calendarConnection)
        let model = SchedulingCalendarPickerModel(
            repository: .writesCTest(transport),
            workspaceId: "ws_1",
            connection: connection,
            onChanged: {}
        )
        await model.load()

        XCTAssertEqual(model.destinationChoices.map(\.id), ["holidays", "work"])
    }

    // MARK: - Unlinking

    /// ⛔ `provider` IS REQUIRED AND THE `{id}` IS DECORATIVE. The fork recreates a
    /// connection id on every token refresh, so identity is `provider` + `account`.
    func test_IOS_SCHW_C60_disconnectingSendsTheProviderAndTheAccountNotJustTheId() async throws {
        let transport = SchedulingWritesCTransport([.noContent])
        var changed = 0
        let connection: SchedulingCalendarConnection = try SchedulingWritesCRows
            .decode(SchedulingWritesCRows.calendarConnection)
        let model = SchedulingCalendarDisconnectModel(
            repository: .writesCTest(transport),
            workspaceId: "ws_1",
            onChanged: { changed += 1 }
        )
        model.ask(connection)
        await model.confirm()

        let call = transport.calls.first
        XCTAssertEqual(transport.ops, ["calendar.connections.delete"])
        XCTAssertEqual(call?.string("id"), "cal_1")
        XCTAssertEqual(call?.string("provider"), "google")
        XCTAssertEqual(call?.string("account"), "host@example.com")
        XCTAssertEqual(changed, 1)
    }

    /// ⛔ UNLINKING THE DESTINATION LEAVES THE TENANCY WRITING BOOKINGS NOWHERE, and
    /// the catalog does not refuse it — so the screen has to say so rather than let
    /// it be discovered at the next booking.
    func test_IOS_SCHW_C61_unlinkingTheDestinationRaisesAWarningToShow() async throws {
        let transport = SchedulingWritesCTransport([.noContent])
        let connection: SchedulingCalendarConnection = try SchedulingWritesCRows
            .decode(SchedulingWritesCRows.calendarConnection)
        let model = SchedulingCalendarDisconnectModel(
            repository: .writesCTest(transport),
            workspaceId: "ws_1",
            onChanged: {}
        )
        model.ask(connection)
        await model.confirm()

        XCTAssertTrue(model.removedDestination)
        model.dismissDestinationWarning()
        XCTAssertFalse(model.removedDestination)
    }

    func test_IOS_SCHW_C62_aFailedDisconnectReportsAndClaimsNothingMoved() async throws {
        let transport = SchedulingWritesCTransport([.refusal("unavailable")])
        let connection: SchedulingCalendarConnection = try SchedulingWritesCRows
            .decode(SchedulingWritesCRows.calendarConnection)
        let model = SchedulingCalendarDisconnectModel(
            repository: .writesCTest(transport),
            workspaceId: "ws_1",
            onChanged: { XCTFail("a failed disconnect must not claim the list moved") }
        )
        model.ask(connection)
        await model.confirm()

        XCTAssertEqual(model.failure?.message, SchedulingWriteCopyC.unavailable)
        XCTAssertFalse(model.removedDestination)
    }
}
