@testable import DistrictAI
import DistrictData
import DistrictModel
import Foundation
import XCTest

/// The four booking writes, asserted on the bytes they send.
///
/// ⛔ THE `op` IS CHECKED ON EVERY ONE. It crosses the wire as a STRING and the
/// server owns the catalog, so a model wired to the wrong op is a runtime
/// `unknown_op` in production and nothing a compiler can object to.
@MainActor
final class SchedulingWritesBBookingTests: XCTestCase {
    private typealias Fixtures = SchedulingWritesBFixtures

    // MARK: - Cancel

    func testCancelSendsTheTrimmedReasonAndHandsBackTheServersRow() async {
        let transport = SettingsTransport([Fixtures.ok(Fixtures.booking(status: "cancelled"))])
        var saved: SchedulingBooking?
        let model = SchedulingBookingCancelModel(
            admin: Fixtures.repository(transport),
            workspaceId: Fixtures.workspaceId,
            bookingId: "bk-1",
            onSaved: { saved = $0 }
        )
        model.editReason("  Client asked to move  ")
        await model.submit()

        XCTAssertEqual(Fixtures.op(transport), "bookings.cancel")
        XCTAssertEqual(Fixtures.params(transport)["id"] as? String, "bk-1")
        XCTAssertEqual(Fixtures.params(transport)["reason"] as? String, "Client asked to move")
        XCTAssertEqual(Fixtures.done(model.state), SchedulingBookingWriteCopy.cancelDone)
        XCTAssertEqual(saved?.status, "cancelled")
    }

    /// ⛔ AN ABSENT KEY, NOT AN EMPTY STRING. The catalog marks `reason` optional and
    /// the fork puts whatever arrives into the attendee's email, so `""` would be a
    /// blank line in a customer's inbox rather than "no reason given".
    func testCancelOmitsTheReasonKeyEntirelyWhenItIsBlank() async {
        let transport = SettingsTransport([Fixtures.ok(Fixtures.booking(status: "cancelled"))])
        let model = SchedulingBookingCancelModel(
            admin: Fixtures.repository(transport),
            workspaceId: Fixtures.workspaceId,
            bookingId: "bk-1",
            onSaved: { _ in }
        )
        model.editReason("   ")
        await model.submit()

        XCTAssertNil(Fixtures.params(transport)["reason"])
        XCTAssertEqual(Fixtures.params(transport).count, 1)
    }

    /// ⚠️ NO REQUEST IS SPENT. The refusal is a validation sentence rather than a
    /// ``SchedulingWriteState/failed(_:)``, because nothing failed.
    func testCancelRefusesAReasonOverTheCatalogsCeilingWithoutSendingAnything() async {
        let transport = SettingsTransport([])
        let model = SchedulingBookingCancelModel(
            admin: Fixtures.repository(transport),
            workspaceId: Fixtures.workspaceId,
            bookingId: "bk-1",
            onSaved: { _ in }
        )
        model.editReason(String(repeating: "x", count: SchedulingBookingCancelModel.reasonLimit + 1))
        await model.submit()

        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(model.reasonRejected, SchedulingBookingWriteCopy.cancelReasonTooLong)
        XCTAssertNil(Fixtures.failure(model.state))
    }

    /// ⛔ A **200** CARRYING `{ok:false}` IS A FAILURE. A client reading the status
    /// alone would report the scheduler's refusal as a cancelled booking.
    func testCancelReportsASchedulerRefusalThatArrivesAtHttpTwoHundred() async {
        let transport = SettingsTransport([Fixtures.refusal("unavailable")])
        var saved = false
        let model = SchedulingBookingCancelModel(
            admin: Fixtures.repository(transport),
            workspaceId: Fixtures.workspaceId,
            bookingId: "bk-1",
            onSaved: { _ in saved = true }
        )
        await model.submit()

        XCTAssertEqual(Fixtures.failure(model.state), SchedulingFailureCopy.unavailable)
        XCTAssertFalse(saved)
    }

    // MARK: - Reschedule

    func testRescheduleAsksForOneDayInTheProfilesZone() async {
        let transport = SettingsTransport([Fixtures.ok("{\"slots\":[]}")])
        let model = Self.rescheduleModel(transport)
        await model.loadSlots()

        XCTAssertEqual(Fixtures.op(transport), "eventTypes.slots")
        let params = Fixtures.params(transport)
        XCTAssertEqual(params["slug"] as? String, "intro")
        XCTAssertEqual(params["tz"] as? String, "Europe/Tallinn")
        // ⛔ `from` AND `to` ARE THE SAME DATE. A window would answer every slot in
        // it and turn one picker into two.
        XCTAssertEqual(params["from"] as? String, params["to"] as? String)
        XCTAssertEqual(params["from"] as? String, model.dayKey)
    }

    /// ⛔ THE SLOT'S OWN `start` GOES BACK VERBATIM AND NO END TIME IS SENT. The far
    /// end recomputes the end from the event type's duration.
    func testRescheduleSendsTheSlotsOwnStartAndNoEndTime() async {
        let transport = SettingsTransport([
            Fixtures.ok("{\"slots\":[{\"start\":\"2026-09-21T09:00:00Z\",\"end\":\"2026-09-21T09:30:00Z\"}]}"),
            Fixtures.ok(Fixtures.booking()),
        ])
        let model = Self.rescheduleModel(transport)
        await model.loadSlots()
        guard case let .ready(rows) = model.slots, let slot = rows.first else {
            return XCTFail("the fixture carries one slot")
        }
        model.select(slot)
        await model.submit()

        XCTAssertEqual(Fixtures.op(transport, 1), "bookings.reschedule")
        let params = Fixtures.params(transport, 1)
        XCTAssertEqual(params["id"] as? String, "bk-1")
        XCTAssertEqual(params["start_at"] as? String, "2026-09-21T09:00:00Z")
        XCTAssertNil(params["end_at"])
    }

    /// ⛔ `slot_taken` IS THE ONE REFUSAL THAT RE-READS. The slot is gone, so the
    /// identical request stays refused and the list on screen is known to be wrong.
    func testARaceForTheSlotRefreshesTheSlotListInsteadOfOfferingARetry() async {
        let transport = SettingsTransport([
            Fixtures.ok("{\"slots\":[{\"start\":\"2026-09-21T09:00:00Z\",\"end\":\"2026-09-21T09:30:00Z\"}]}"),
            Fixtures.refusal("slot_taken"),
            Fixtures.ok("{\"slots\":[]}"),
        ])
        let model = Self.rescheduleModel(transport)
        await model.loadSlots()
        if case let .ready(rows) = model.slots, let slot = rows.first {
            model.select(slot)
        }
        await model.submit()

        XCTAssertEqual(Fixtures.failure(model.state), SchedulingFailureCopy.slotTaken)
        XCTAssertEqual(Fixtures.op(transport, 2), "eventTypes.slots")
        guard case let .ready(rows) = model.slots else {
            return XCTFail("the re-read answers an empty day")
        }
        XCTAssertTrue(rows.isEmpty)
    }

    func testRescheduleWithNothingChosenSpendsNoRequest() async {
        let transport = SettingsTransport([])
        let model = Self.rescheduleModel(transport)
        await model.submit()

        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(model.selectionRejected, SchedulingBookingWriteCopy.reschedulePickTime)
    }

    // MARK: - Reassign

    /// ⛔ ARCHIVED USERS AND THE CURRENT HOST ARE BOTH OUT. An archived user is
    /// skipped in routing and cannot sign in, so offering one offers a booking
    /// nobody will take.
    func testTheHostListDropsArchivedUsersAndTheBookingsOwnHost() async {
        let rows = [
            Fixtures.user(id: "u-1"),
            Fixtures.user(id: "u-2", name: "Grace"),
            Fixtures.user(id: "u-3", name: "Ghost", archived: true),
        ].joined(separator: ",")
        let transport = SettingsTransport([Fixtures.ok("[\(rows)]")])
        let model = SchedulingBookingReassignModel(
            admin: Fixtures.repository(transport),
            workspaceId: Fixtures.workspaceId,
            bookingId: "bk-1",
            currentHostId: "u-1",
            onSaved: { _ in }
        )
        await model.loadHosts()

        XCTAssertEqual(Fixtures.op(transport), "users.list")
        XCTAssertEqual(model.candidates.map(\.id), ["u-2"])
    }

    func testReassignSendsTheSchedulerUserIdAsHostId() async {
        let transport = SettingsTransport([
            Fixtures.ok("[\(Fixtures.user(id: "u-2"))]"),
            Fixtures.ok(Fixtures.booking()),
        ])
        let model = SchedulingBookingReassignModel(
            admin: Fixtures.repository(transport),
            workspaceId: Fixtures.workspaceId,
            bookingId: "bk-1",
            currentHostId: "u-1",
            onSaved: { _ in }
        )
        await model.loadHosts()
        model.select("u-2")
        await model.submit()

        XCTAssertEqual(Fixtures.op(transport, 1), "bookings.reassign")
        XCTAssertEqual(Fixtures.params(transport, 1)["host_id"] as? String, "u-2")
        XCTAssertEqual(Fixtures.done(model.state), SchedulingBookingWriteCopy.reassignDone)
    }

    /// ⚠️ THE OP IS ADMIN-ONLY AT THE FAR END, so the refusal a non-admin scheduler
    /// user gets has to read as a permission answer rather than as an outage.
    func testAReassignRefusedByTheForksRoleGateSaysSo() async {
        // ⚠️ THE STATUS APPLIES TO EVERY QUEUED BODY, so this fixture carries ONE.
        // A list read at 403 beside a submit at 403 would make it ambiguous which
        // request the verdict came from.
        let transport = SettingsTransport(["{\"error\":\"forbidden\"}"], status: 403)
        let model = SchedulingBookingReassignModel(
            admin: Fixtures.repository(transport),
            workspaceId: Fixtures.workspaceId,
            bookingId: "bk-1",
            currentHostId: "u-1",
            onSaved: { _ in }
        )
        model.select("u-2")
        await model.submit()

        XCTAssertEqual(Fixtures.failure(model.state), SchedulingFailureCopy.forbidden)
    }

    // MARK: - Notes

    /// ⛔ THE SENTENCE SAYS "QUEUED", NOT "WRITTEN". The op returns while `status` is
    /// still `pending` and `content` still holds the PREVIOUS text.
    func testRegeneratingNotesReportsThatTheWorkWasQueued() async {
        let transport = SettingsTransport([
            Fixtures.ok("{\"exists\":true,\"status\":\"pending\",\"content\":\"the old notes\"}"),
        ])
        var queued: SchedulingBookingNotesRegenerated?
        let model = SchedulingBookingNotesModel(
            admin: Fixtures.repository(transport),
            workspaceId: Fixtures.workspaceId,
            bookingId: "bk-1",
            onQueued: { queued = $0 }
        )
        await model.regenerate()

        XCTAssertEqual(Fixtures.op(transport), "bookings.notes.regenerate")
        XCTAssertEqual(Fixtures.params(transport)["id"] as? String, "bk-1")
        XCTAssertEqual(Fixtures.done(model.state), SchedulingBookingWriteCopy.regenerateDone)
        XCTAssertEqual(queued?.status, "pending")
    }

    private static func rescheduleModel(_ transport: SettingsTransport) -> SchedulingBookingRescheduleModel {
        SchedulingBookingRescheduleModel(
            admin: SchedulingWritesBFixtures.repository(transport),
            workspaceId: SchedulingWritesBFixtures.workspaceId,
            bookingId: "bk-1",
            eventTypeSlug: "intro",
            timezone: "Europe/Tallinn",
            onSaved: { _ in }
        )
    }
}
