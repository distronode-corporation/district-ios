@testable import DistrictAI
import DistrictData
import DistrictModel
import Foundation
import XCTest

/// Turn on, archive, test email, delete — the four writes that address an event
/// type without opening it.
@MainActor
final class SchedulingWritesActionsTests: XCTestCase {
    /// ⛔ TURNING OFF IS A PATCH OF ONE FLAG, not a delete and not an archive.
    func testTurningOffPatchesTheActiveFlagAlone() async {
        let transport = SettingsTransport([SchedulingWritesFixtures.eventType(extras: #","is_active":false"#)])
        let model = Self.actions(transport)
        await model.toggleActive()

        let call = SchedulingWritesFixtures.lastCall(transport)
        XCTAssertEqual(call?.op, "eventTypes.patch")
        XCTAssertEqual(call?.params["is_active"] as? Bool, false)
        XCTAssertNil(call?.params["archived"])
        XCTAssertEqual(model.notice, "Event type turned off")
    }

    /// ⚠️ THE LABEL COMES FROM THE ROW THE SERVER ANSWERED WITH, not from what this
    /// client assumed it did. The patch echoes the whole updated event type.
    func testTheMenuRereadsItselfFromTheAnsweredRow() async {
        let transport = SettingsTransport([SchedulingWritesFixtures.eventType(extras: #","is_active":false"#)])
        let model = Self.actions(transport)
        XCTAssertEqual(model.toggleTitle, "Turn off")
        await model.toggleActive()
        XCTAssertEqual(model.toggleTitle, "Turn on")
    }

    /// ⛔ ARCHIVE IS A PATCH AND DELETE IS AN OP. The difference is the bookings:
    /// archiving hides the event type while its history stays addressable.
    func testArchivingPatchesRatherThanDeleting() async {
        let transport = SettingsTransport([SchedulingWritesFixtures.eventType(extras: #","archived":true"#)])
        let model = Self.actions(transport)
        await model.toggleArchived()

        let call = SchedulingWritesFixtures.lastCall(transport)
        XCTAssertEqual(call?.op, "eventTypes.patch")
        XCTAssertEqual(call?.params["archived"] as? Bool, true)
        XCTAssertEqual(model.notice, "Event type archived")
        XCTAssertEqual(model.archiveTitle, "Restore")
    }

    /// ⛔ THE ONLY OP HERE THAT REMOVES ANYTHING, AND THE ONLY ONE BEHIND A
    /// CONFIRMATION.
    func testDeletingSendsTheDeleteOpAndReportsTheSlugItRemoved() async {
        let transport = SettingsTransport([SchedulingWritesFixtures.noContent])
        var deleted: String?
        let model = Self.actions(transport) { change in
            if case let .deleted(slug) = change {
                deleted = slug
            }
        }
        model.confirmingDelete = true
        await model.delete()

        let call = SchedulingWritesFixtures.lastCall(transport)
        XCTAssertEqual(call?.op, "eventTypes.delete")
        XCTAssertEqual(call?.params["slug"] as? String, "phone-consultation")
        XCTAssertEqual(deleted, "phone-consultation")
        XCTAssertFalse(model.confirmingDelete)
    }

    /// ⛔ THERE IS NO RECIPIENT ARGUMENT. The fork addresses the calling member's
    /// own scheduler address, and the answer is where that address comes from.
    func testTheTestEmailNamesTheAddressTheForkChose() async {
        let body = SchedulingWritesFixtures.ok(#"{"sent":true,"to":"host@example.com"}"#)
        let transport = SettingsTransport([body])
        let model = Self.actions(transport)
        await model.sendTestEmail(type: "reminder")

        let call = SchedulingWritesFixtures.lastCall(transport)
        XCTAssertEqual(call?.op, "eventTypes.testEmail")
        XCTAssertEqual(call?.params["type"] as? String, "reminder")
        XCTAssertNil(call?.params["to"], "a recipient parameter would make this op a mail relay")
        XCTAssertEqual(model.notice, "Test email sent to host@example.com")
    }

    /// ⛔ `sent: false` IS A SUCCESSFUL RESPONSE REPORTING THAT NOTHING WAS SENT.
    /// Rendering it as a failure would offer a retry for the half that worked.
    func testASuccessfulRequestThatSentNothingIsNotAFailure() async {
        let body = SchedulingWritesFixtures.ok(#"{"sent":false,"to":"host@example.com"}"#)
        let transport = SettingsTransport([body])
        let model = Self.actions(transport)
        await model.sendTestEmail(type: "confirmation")

        XCTAssertNil(model.state.failure)
        XCTAssertEqual(model.notice, "The booking system did not send the test email.")
    }

    /// ⚠️ THE FOUR TEMPLATES ARE THE CATALOG'S, and the wire values are not derived
    /// from the labels.
    func testTheFourTemplatesAreTheCatalogsOwn() {
        XCTAssertEqual(
            SchedulingWriteCopy.emailTemplates.map(\.type),
            ["confirmation", "cancellation", "reschedule", "reminder"]
        )
    }

    /// ⛔ A WORKSPACE WITH NO TENANCY IS NOT A FAULT AND IS NOT RETRYABLE.
    func testAWorkspaceWithNoSchedulingTenancyIsToldSoWithNoRetry() async {
        let transport = SettingsTransport([#"{"error":"scheduling_not_ready"}"#], status: 409)
        let model = Self.actions(transport)
        await model.toggleActive()

        XCTAssertEqual(model.state.failure?.message, "Scheduling is not set up for this workspace yet.")
        XCTAssertEqual(model.state.failure?.action, FailureText.Action.none)
    }

    // MARK: - Fixtures

    private static func actions(
        _ transport: SettingsTransport,
        onSaved: @escaping (SchedulingEventTypeChange) -> Void = { _ in }
    ) -> SchedulingEventTypeActionsModel {
        SchedulingEventTypeActionsModel(
            admin: SchedulingWritesFixtures.repository(transport),
            workspaceId: "ws_1",
            eventType: row(),
            onSaved: onSaved
        )
    }

    private static func row() -> SchedulingEventType {
        let json = #"{"id":"et_1","slug":"phone-consultation","name":"Phone","duration_minutes":30}"#
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(SchedulingEventType.self, from: Data(json.utf8))
    }
}
