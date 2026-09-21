@testable import DistrictAI
import DistrictData
import DistrictModel
import DistrictNetwork
import XCTest

/// Each section's view model, driven over a fake transport.
///
/// ⛔ A FAKE TRANSPORT RATHER THAN A FAKE REPOSITORY, AND IT IS THE STRONGER CHOICE HERE.
/// ``SchedulingAdminRepository`` is a struct over ``ApiClient``, so there is no protocol to
/// stub — and stubbing one would skip the envelope walk, which is where a scheduling read
/// actually goes wrong: a `{ok:false}` body arrives at **HTTP 200**, and a repository
/// double returning a Swift error would never exercise that. Starting at the bytes means
/// these tests prove the refusal mapping as well as the model.
///
/// ⛔ AND THE STUB ROUTES BY `op` RATHER THAN BY POSITION. Every model here issues its
/// independent reads inside a `withTaskGroup`, so a positional queue hands each answer to
/// whichever request the scheduler happened to run first — which is how the first version
/// of this file passed and failed on timing. See the ⛔ on ``SchedulingTestTransport``.
final class SchedulingModelTests: SchedulingModelTestCase {
    // MARK: - Overview

    /// ⛔ THE STATUS READ COMES FIRST AND THE OTHER FIVE FOLLOW, because two of them need
    /// what it answers: the booking links need `publicHost` and the bookings read needs
    /// `canManage` for its scope.
    @MainActor
    func test_IOS_SCHMODEL_01_theOverviewReadsStatusBeforeTheRest() async {
        let transport = SchedulingTestTransport([
            "status": .readyStatus(),
            "me.get": .me(timezone: "America/Toronto"),
            "eventTypes.list": .data(#"{"items":[]}"#),
            "calendar.status": .data(#"{"connected":true,"configured":true,"connections":[]}"#),
            "availability.rules.list": .data(#"{"items":[]}"#),
            "bookings.list": .data(#"{"items":[]}"#),
        ])
        let model = overview(transport)
        await model.load()

        XCTAssertEqual(model.publicHost, "acme.example.com")
        XCTAssertTrue(model.canManage)
        XCTAssertEqual(model.timezone, "America/Toronto")
        XCTAssertEqual(transport.paths.first, "/api/district/scheduling/status")
        // ⚠️ The bookings read is LAST, after the group, because it reads the timezone for
        // its `from` date; running it inside would ask for "today" in whichever zone had
        // landed first, which near midnight is a different day.
        XCTAssertEqual(transport.ops.last, "bookings.list")
    }

    /// ⛔ THE BOOKING LINK IS BUILT FROM THE SERVER'S HOST AND THE ROW'S SLUG, and there is
    /// none at all without a host. A client that assembled its own would publish a link for
    /// a page that is not there.
    @MainActor
    func test_IOS_SCHMODEL_02_theBookingLinksNeedAHost() async {
        let transport = SchedulingTestTransport([
            "status": .provisioningStatus(),
            "me.get": .me(),
            "eventTypes.list": .data(
                #"{"items":[{"id":"et1","slug":"intro","name":"Intro","duration_minutes":30}]}"#
            ),
            "calendar.status": .data(#"{"connected":false,"configured":true,"connections":[]}"#),
            "availability.rules.list": .data(#"{"items":[]}"#),
            "bookings.list": .data(#"{"items":[]}"#),
        ])
        let model = overview(transport)
        await model.load()

        XCTAssertTrue(model.bookingLinks.isEmpty)
        // ⚠️ The event types still LOADED; only the address is missing.
        XCTAssertEqual(model.eventTypes.value?.count, 1)
    }

    /// ⛔ ONE FAILED ROW DOES NOT TAKE THE OTHERS DOWN. This is the whole shape of the
    /// register and the reason it holds five states rather than one.
    @MainActor
    func test_IOS_SCHMODEL_03_oneFailedRowLeavesTheOthersStanding() async {
        let transport = SchedulingTestTransport([
            "status": .readyStatus(),
            "me.get": .me(),
            "eventTypes.list": .data(
                #"{"items":[{"id":"et1","slug":"intro","name":"Intro","duration_minutes":30}]}"#
            ),
            // ⚠️ A `{ok:false}` AT HTTP 200 — our route was satisfied and the SCHEDULER
            // refused. A repository double could not produce this shape.
            "calendar.status": .refused("unavailable"),
            "availability.rules.list": .data(#"{"items":[]}"#),
            "bookings.list": .data(#"{"items":[]}"#),
        ])
        let model = overview(transport)
        await model.load()

        guard case let .failed(failure) = model.calendar else {
            return XCTFail("the calendar row must report its own failure")
        }
        XCTAssertEqual(failure.message, SchedulingFailureCopy.unavailable)
        XCTAssertEqual(failure.action, .retry)
        // ⛔ The other three rows survived.
        XCTAssertNotNil(model.eventTypes.value)
        XCTAssertNotNil(model.rules.value)
        XCTAssertNotNil(model.bookings.value)
    }

    /// ⚠️ A FAILED PROFILE READ FALLS BACK TO UTC AND DOES NOT FAIL THE SCREEN. It supplies
    /// a display zone and nothing else; reporting it as a row would invent a sixth row for
    /// a fact nobody can act on.
    @MainActor
    func test_IOS_SCHMODEL_04_aFailedProfileReadFallsBackToUTC() async {
        let transport = SchedulingTestTransport([
            "status": .readyStatus(),
            "me.get": .refused("unavailable"),
            "eventTypes.list": .data(#"{"items":[]}"#),
            "calendar.status": .data(#"{"connected":false,"configured":true,"connections":[]}"#),
            "availability.rules.list": .data(#"{"items":[]}"#),
            "bookings.list": .data(#"{"items":[]}"#),
        ])
        let model = overview(transport)
        await model.load()

        XCTAssertEqual(model.timezone, "UTC")
        XCTAssertTrue(model.timezoneResolved)
        XCTAssertNotNil(model.eventTypes.value)
    }

    /// ⚠️ THE NEXT-BOOKING LINE IS THE REGISTER'S RELATIVE FORM, not the table's absolute
    /// one, and it resolves the event type's display name through the list beside it.
    @MainActor
    func test_IOS_SCHMODEL_05_theNextBookingLineNamesWhenWhoAndWhat() async {
        let transport = SchedulingTestTransport([
            "status": .readyStatus(),
            "me.get": .me(),
            "eventTypes.list": .data(
                #"{"items":[{"id":"et1","slug":"intro","name":"Intro call","duration_minutes":30}]}"#
            ),
            "calendar.status": .data(#"{"connected":false,"configured":true,"connections":[]}"#),
            "availability.rules.list": .data(#"{"items":[]}"#),
            "bookings.list": .data("""
            {"items":[{"id":"b1","event_type_slug":"intro","start_at":"2026-09-12T14:30:00Z",
            "end_at":"2026-09-12T15:00:00Z","status":"confirmed",
            "attendees":[{"name":"Ada","email":"a@b.com"}]}]}
            """),
        ])
        let model = overview(transport)
        await model.load()

        let line = model.nextBookingLine
        XCTAssertEqual(line?.contains("Ada"), true)
        XCTAssertEqual(line?.contains("Intro call"), true)
        XCTAssertEqual(model.comingUp.first?.status.label, "Confirmed")
    }

    // MARK: - Event types

    @MainActor
    func test_IOS_SCHMODEL_06_eventTypeRowsFormatTheirColumns() async {
        let transport = SchedulingTestTransport([
            "status": .readyStatus(),
            "eventTypes.list": .data("""
            {"items":[{"id":"et1","slug":"intro","name":"Intro","duration_minutes":30,
            "slot_interval_minutes":15,"location_type":"livekit","is_active":true,"is_public":true}]}
            """),
        ])
        let model = eventTypes(transport)
        await model.load()

        let row = model.rows.first
        XCTAssertEqual(row?.duration, "30 min")
        XCTAssertEqual(row?.interval, "15 min")
        XCTAssertEqual(row?.location, "Built-in video")
        XCTAssertEqual(row?.state.label, "Active")
        XCTAssertEqual(row?.bookingPage, "https://acme.example.com/book/intro")
    }

    /// ⛔ ARCHIVED WINS OVER INACTIVE, because the archive is what explains the state and
    /// what somebody has to undo.
    @MainActor
    func test_IOS_SCHMODEL_07_archivedWinsOverInactive() async {
        let transport = SchedulingTestTransport([
            "status": .readyStatus(),
            "eventTypes.list": .data("""
            {"items":[{"id":"et1","slug":"old","name":"Old","duration_minutes":30,
            "is_active":false,"archived":true}]}
            """),
        ])
        let model = eventTypes(transport)
        await model.load()
        XCTAssertEqual(model.rows.first?.state.label, "Archived")
    }

    /// ⛔ A ROW THAT IS NOT LIVE PUBLISHES NO ADDRESS. Publishing a link to a page that does
    /// not answer is the one mistake this column can make that a customer discovers.
    @MainActor
    func test_IOS_SCHMODEL_08_aPrivateRowIsNotPublic() async {
        let transport = SchedulingTestTransport([
            "status": .readyStatus(),
            "eventTypes.list": .data("""
            {"items":[{"id":"et1","slug":"hidden","name":"Hidden","duration_minutes":30,
            "is_public":false}]}
            """),
        ])
        let model = eventTypes(transport)
        await model.load()
        XCTAssertEqual(model.rows.first?.bookingPage, SchedulingCopy.notPublic)
    }

    /// ⛔ AND A TENANCY WITH NO HOST PUBLISHES NOTHING EITHER, even for a live row.
    @MainActor
    func test_IOS_SCHMODEL_09_noHostMeansNotPublic() async {
        let transport = SchedulingTestTransport([
            "status": .provisioningStatus(),
            "eventTypes.list": .data("""
            {"items":[{"id":"et1","slug":"intro","name":"Intro","duration_minutes":30,
            "is_active":true,"is_public":true}]}
            """),
        ])
        let model = eventTypes(transport)
        await model.load()
        XCTAssertEqual(model.rows.first?.bookingPage, SchedulingCopy.notPublic)
    }

    // MARK: - Hours

    @MainActor
    func test_IOS_SCHMODEL_10_theHoursGridIsSevenDaysAndSummarised() async {
        let rules = (1 ... 5).map {
            #"{"id":"r\#($0)","event_type_id":null,"day_of_week":\#($0),"start_time":"09:00","end_time":"17:00"}"#
        }.joined(separator: ",")
        let transport = SchedulingTestTransport([
            "me.get": .me(),
            "availability.rules.list": .data("{\"items\":[\(rules)]}"),
            "availability.overrides.list": .data(#"{"items":[]}"#),
        ])
        let model = SchedulingHoursModel(repository: admin(transport), workspaceId: "ws_1")
        await model.load()

        XCTAssertEqual(model.summary, "Mon to Fri, 9:00 to 17:00")
        XCTAssertEqual(model.week.value?.count, 7)
        // ⚠️ Saturday and Sunday are empty and are still DRAWN; see the ⛔ on the model.
        XCTAssertEqual(model.week.value?[5].isEmpty, true)
        XCTAssertEqual(model.week.value?[6].isEmpty, true)
        XCTAssertEqual(model.week.value?[0].count, 1)
    }
}
