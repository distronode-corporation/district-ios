import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// The `recordings.*` repository methods.
///
/// ⛔ THE BODY BYTES ARE ASSERTED ALONGSIDE THE RESULT, for the reason
/// `SchedulingAdminSettingsRepositoryTests` gives: a method wired to the wrong op
/// still returns a plausible object, because `perform` decodes whatever the caller
/// names and the op crosses the wire as a string.
final class SchedulingAdminRecordingsRepositoryTests: XCTestCase {
    private func repository(_ transport: RepositoryTransport) -> SchedulingAdminRepository {
        SchedulingAdminRepository(client: .repositoryTest(transport), reportUnknownOp: { _ in })
    }

    private func envelope(_ data: String) -> String {
        #"{"ok":true,"data":\#(data)}"#
    }

    /// ⛔ THE CONTAINER IS UNWRAPPED AND THE KEY IS `recordings`, not `items`. A
    /// caller wants the rows; reading this through the developer tab's container
    /// would throw a missing-key error that presents as an outage.
    func testListUnwrapsTheBespokeContainer() async throws {
        let transport = RepositoryTransport(json: envelope(
            #"{"recordings":[{"id":"rec_1","status":"ready","has_file":true},{"id":"rec_2","status":"failed"}]}"#
        ))
        let rows = try await repository(transport).recordings(workspaceId: "ws_1")
        XCTAssertEqual(rows.map(\.id), ["rec_1", "rec_2"])
        XCTAssertEqual(rows[0].hasFile, true)
        XCTAssertNil(rows[1].hasFile)
        XCTAssertEqual(transport.bodies, [#"{"op":"recordings.list","params":{},"workspaceId":"ws_1"}"#])
    }

    /// ⚠️ A TENANCY THAT HAS NEVER RECORDED ANYTHING IS AN EMPTY LIST, not an
    /// error and not an absent key.
    func testAnEmptyListIsAnOrdinaryAnswer() async throws {
        let transport = RepositoryTransport(json: envelope(#"{"recordings":[]}"#))
        let rows = try await repository(transport).recordings(workspaceId: "ws_1")
        XCTAssertTrue(rows.isEmpty)
    }

    /// ⛔ THE PATH KEY IS STILL IN THE BODY. The catalog's `pathKeys` strip happens
    /// SERVER-side, after `op.params` has validated, so a client that removed `id`
    /// first would get a 400 naming the field it was being clever about.
    func testDeletingOneRecordingSendsItsIdInTheParams() async throws {
        let transport = RepositoryTransport(json: envelope(#"{"ok":true}"#))
        let answer = try await repository(transport).deleteRecording(
            workspaceId: "ws_1",
            recordingId: "rec_1"
        )
        XCTAssertTrue(answer.ok)
        XCTAssertEqual(
            transport.bodies,
            [#"{"op":"recordings.delete","params":{"id":"rec_1"},"workspaceId":"ws_1"}"#]
        )
    }

    /// ⛔ THE TALLY IS HANDED BACK WHOLE BECAUSE `failed` IS THE ONLY PLACE A
    /// PARTIAL FAILURE IS REPORTED — the HTTP status is a 200 either way. A method
    /// that collapsed this to `deleted` would discard the number at the layer least
    /// able to notice it was gone.
    func testDeletingEverythingReportsBothHalvesOfTheTally() async throws {
        let transport = RepositoryTransport(json: envelope(#"{"deleted":4,"failed":1}"#))
        let tally = try await repository(transport).deleteAllRecordings(workspaceId: "ws_1")
        XCTAssertEqual(tally.deleted, 4)
        XCTAssertEqual(tally.failed, 1)
        XCTAssertEqual(transport.bodies, [#"{"op":"recordings.deleteAll","params":{},"workspaceId":"ws_1"}"#])
    }

    /// ⛔ THE CONSENT ROLL IS THE EVIDENCE FOR A TWO-PARTY-CONSENT JURISDICTION,
    /// and `pending` with no timestamp is a real row rather than a broken one.
    func testConsentsUnwrapTheirOwnContainerAndKeepThePendingRow() async throws {
        let transport = RepositoryTransport(json: envelope(
            #"""
            {"consents":[{"identity":"host-u1","name":"Contract Member","decision":"granted",
                          "decided_at":"2026-09-14T13:00:05Z"},
                         {"identity":"guest-dana","decision":"pending"}]}
            """#
        ))
        let consents = try await repository(transport).recordingConsents(
            workspaceId: "ws_1",
            recordingId: "rec_1"
        )
        XCTAssertEqual(consents.map(\.identity), ["host-u1", "guest-dana"])
        XCTAssertEqual(consents[1].decision, "pending")
        XCTAssertNil(consents[1].decidedAt)
        XCTAssertEqual(
            transport.bodies,
            [#"{"op":"recordings.consent","params":{"id":"rec_1"},"workspaceId":"ws_1"}"#]
        )
    }

    /// ⛔ A **200** CARRYING `{ok:false}` IS THE SCHEDULER REFUSING, not a decode
    /// problem, and every one of these methods inherits that from `perform`. Pinned
    /// on a recordings method because the failure a user meets here is a bulk
    /// delete that did not happen.
    func testASchedulerRefusalArrivesAsAFailureRatherThanAnEmptyTally() async {
        let transport = RepositoryTransport(json: #"{"ok":false,"failure":"unavailable","status":502}"#)
        do {
            _ = try await repository(transport).deleteAllRecordings(workspaceId: "ws_1")
            XCTFail("expected a failure")
        } catch let error as SchedulingAdminError {
            XCTAssertEqual(error, .failure(.unavailable))
            XCTAssertEqual(error.uiCode, .unavailable)
        } catch {
            XCTFail("expected a SchedulingAdminError, got \(error)")
        }
    }

    /// ⚠️ A `viewer` MAY LIST RECORDINGS AND MAY NOT DOWNLOAD ONE, so a 403 on the
    /// list means something stronger: this member cannot see the surface at all.
    func testAForbiddenListIsMappedFromTheStatusRatherThanTheBody() async {
        let transport = RepositoryTransport(json: #"{"error":"forbidden"}"#, status: 403)
        do {
            _ = try await repository(transport).recordings(workspaceId: "ws_1")
            XCTFail("expected a refusal")
        } catch let error as SchedulingAdminError {
            XCTAssertEqual(error, .forbidden)
        } catch {
            XCTFail("expected a SchedulingAdminError, got \(error)")
        }
    }
}
