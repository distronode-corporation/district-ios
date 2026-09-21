@testable import DistrictAI
import DistrictData
import DistrictModel
import Foundation
import XCTest

/// Deleting one recording, and deleting all of them.
///
/// ⛔ THE BULK DELETE IS THE MOST DESTRUCTIVE OPERATION ON THIS SURFACE AND ITS
/// PARTIAL FAILURE IS A **200**. Both facts are pinned here, because neither is
/// visible from the op's signature and a screen that got either wrong would tell a
/// customer their recordings are gone while they are still in the bucket.
@MainActor
final class SchedulingWritesBRecordingTests: XCTestCase {
    private typealias Fixtures = SchedulingWritesBFixtures

    func testDeletingOneRecordingSendsItsIdAndSignalsAReRead() async {
        let transport = SettingsTransport([Fixtures.noContent])
        var reread = false
        let model = SchedulingRecordingDeleteModel(
            admin: Fixtures.repository(transport),
            workspaceId: Fixtures.workspaceId,
            onDeleted: { reread = true }
        )
        await model.delete(recordingId: "rec-1")

        XCTAssertEqual(Fixtures.op(transport), "recordings.delete")
        XCTAssertEqual(Fixtures.params(transport)["id"] as? String, "rec-1")
        XCTAssertEqual(Fixtures.done(model.state), SchedulingRecordingWriteCopy.deleteDone)
        XCTAssertTrue(reread, "the op echoes nothing, so the list is stale on return")
    }

    /// ⛔ THE WORD IS LOWER-CASE, TRIMMED, EXACT AND CASE-SENSITIVE. iOS offers
    /// "Delete" through autocapitalisation, which is why the field turns it off — and
    /// why accepting "Delete" here would quietly weaken a confirmation the web makes
    /// people get right.
    func testDeleteAllStaysLockedUntilTheExactLowerCaseWordIsTyped() async {
        for typed in ["", "Delete", "DELETE", "delete all", "delet"] {
            let transport = SettingsTransport([])
            let model = Self.model(transport)
            model.editConfirmation(typed)

            XCTAssertFalse(model.canDeleteAll, "\(typed) must not unlock the delete")
            await model.deleteAll()
            XCTAssertTrue(transport.requests.isEmpty, "\(typed) must spend no request")
        }
    }

    /// ⚠️ TRIMMED, so the space a keyboard adds after a word does not lock somebody
    /// out of a gate they satisfied.
    func testTheTypedWordIsTrimmedBeforeItIsCompared() {
        let model = Self.model(SettingsTransport([]))
        model.editConfirmation("  delete  ")

        XCTAssertTrue(model.canDeleteAll)
    }

    func testDeleteAllReportsTheTallyItWasGiven() async {
        let transport = SettingsTransport([Fixtures.ok("{\"deleted\":3,\"failed\":0}")])
        var reread = false
        let model = SchedulingRecordingDeleteModel(
            admin: Fixtures.repository(transport),
            workspaceId: Fixtures.workspaceId,
            onDeleted: { reread = true }
        )
        model.editConfirmation(SchedulingRecordingWriteCopy.deleteAllConfirmation)
        await model.deleteAll()

        XCTAssertEqual(Fixtures.op(transport), "recordings.deleteAll")
        XCTAssertTrue(Fixtures.params(transport).isEmpty)
        XCTAssertEqual(Fixtures.done(model.state), "3 recordings deleted")
        XCTAssertTrue(reread)
        // ⚠️ THE TYPED WORD IS CLEARED ON SUCCESS, so a second bulk delete has to be
        // confirmed again rather than sitting armed behind a green sentence.
        XCTAssertEqual(model.confirmation, "")
    }

    func testASingleDeletedRecordingIsNotPluralised() async {
        let transport = SettingsTransport([Fixtures.ok("{\"deleted\":1,\"failed\":0}")])
        let model = Self.model(transport)
        model.editConfirmation(SchedulingRecordingWriteCopy.deleteAllConfirmation)
        await model.deleteAll()

        XCTAssertEqual(Fixtures.done(model.state), "1 recording deleted")
    }

    /// ⛔ A NON-ZERO `failed` IS A FAILURE THOUGH THE STATUS IS 200. On a surface
    /// whose whole purpose is data removal, "all deleted" over a non-zero tally is
    /// the worst available wrong answer.
    func testAPartialBulkDeleteIsReportedAsAFailureWithBothNumbers() async {
        let transport = SettingsTransport([Fixtures.ok("{\"deleted\":3,\"failed\":2}")])
        var reread = false
        let model = SchedulingRecordingDeleteModel(
            admin: Fixtures.repository(transport),
            workspaceId: Fixtures.workspaceId,
            onDeleted: { reread = true }
        )
        model.editConfirmation(SchedulingRecordingWriteCopy.deleteAllConfirmation)
        await model.deleteAll()

        XCTAssertEqual(
            Fixtures.failure(model.state),
            SchedulingRecordingWriteCopy.deleteAllPartial(deleted: 3, failed: 2)
        )
        // ⛔ AND THE RE-READ STILL FIRES. Rows DID go; a screen that only refreshed on
        // a clean success would keep showing recordings that no longer exist.
        XCTAssertTrue(reread)
    }

    /// ⚠️ THE SCHEDULER'S OWN REFUSAL, AT HTTP 200. Nothing was deleted, so nothing
    /// asks the screen to re-read.
    func testARefusedBulkDeleteReportsTheSharedSentence() async {
        let transport = SettingsTransport([Fixtures.refusal("unavailable")])
        var reread = false
        let model = SchedulingRecordingDeleteModel(
            admin: Fixtures.repository(transport),
            workspaceId: Fixtures.workspaceId,
            onDeleted: { reread = true }
        )
        model.editConfirmation(SchedulingRecordingWriteCopy.deleteAllConfirmation)
        await model.deleteAll()

        XCTAssertEqual(Fixtures.failure(model.state), SchedulingWritesBFailure.unavailableMessage)
        XCTAssertFalse(reread)
    }

    private static func model(_ transport: SettingsTransport) -> SchedulingRecordingDeleteModel {
        SchedulingRecordingDeleteModel(
            admin: SchedulingWritesBFixtures.repository(transport),
            workspaceId: SchedulingWritesBFixtures.workspaceId,
            onDeleted: {}
        )
    }
}
