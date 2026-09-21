import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// The workflow list, its run history and the toggle.
///
/// ⛔ THE ASSERTIONS ARE ABOUT OUTCOMES THAT LOOK ALIKE ON A MONITOR AND MEAN
/// DIFFERENT THINGS. An empty workflow list and a failed read are the same picture
/// and must not be the same value; the paging fields are the server's and must not be
/// re-derived; and the toggle's reply carries nothing at all, which is why it is the
/// one write here that a caller cannot adopt.
///
/// ⚠️ THE CAMPAIGN HALF OF THIS REPOSITORY IS IN `CampaignRepositoryTests`, split
/// because SwiftLint's 500-line file ceiling is an error under `--strict`.
final class WorkflowsRepositoryTests: XCTestCase {
    private func repository(_ transport: RepositoryTransport) -> WorkflowsRepository {
        WorkflowsRepository(client: .repositoryTest(transport))
    }

    // MARK: - The workflow list

    func testListingWorkflowsGetsTheRouteAndAnswersTheRows() async {
        let transport = RepositoryTransport(json: WorkflowBodies.list)

        let result = await repository(transport).workflows(workspaceId: "ws_1")

        XCTAssertEqual(result.successOnly?.map(\.id), ["wf_a", "wf_b"])
        XCTAssertEqual(result.successOnly?.map(\.active), [true, false])
        XCTAssertEqual(transport.requests.first?.method, .get)
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/workflows?workspaceId=ws_1"
        )
        XCTAssertTrue(transport.bodies.isEmpty, "a GET carries no body")
    }

    /// ⛔ AN EMPTY LIST IS A SUCCESS AND MUST STAY ONE. Most workspaces have never
    /// created a workflow, so the caller renders an explanatory empty state; mapping it
    /// to a failure would put an error on the one screen whose job is to offer the
    /// first one.
    func testAnEmptyWorkflowListIsASuccessRatherThanAFailure() async {
        let transport = RepositoryTransport(json: #"{"success":true,"workflows":[]}"#)

        let result = await repository(transport).workflows(workspaceId: "ws_1")

        XCTAssertEqual(result.successOnly?.isEmpty, true)
        XCTAssertNil(result.failureOnly)
    }

    /// ⚠️ A WORKFLOW THAT HAS NEVER FIRED KEEPS ITS NULL ROLLUP AS nil, which is a
    /// state and not a failure: it is the commonest row on this screen, one created
    /// minutes ago.
    func testAWorkflowThatHasNeverFiredHasNoRollup() async {
        let transport = RepositoryTransport(json: WorkflowBodies.list)

        let result = await repository(transport).workflows(workspaceId: "ws_1")

        XCTAssertEqual(result.successOnly?.first?.latestRun?.status, "success")
        XCTAssertNil(result.successOnly?.last?.latestRun)
    }

    /// ⛔ THE ENVELOPE CHECK MATTERS MORE HERE THAN ALMOST ANYWHERE. A required field
    /// rejects `{}`, but not a well-formed `success: false` from the route's catch
    /// branch, and on the automation monitor "we could not look" rendered as "you have
    /// no workflows" reads as "your automation was deleted".
    func testAWorkflowListThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(json: #"{"success":false,"workflows":[]}"#)

        let result = await repository(transport).workflows(workspaceId: "ws_1")

        XCTAssertEqual(result.failureOnly, .decoding("WorkflowListResponse did not affirm success=true"))
    }

    /// ⚠️ THE LIST ADMITS `viewer`, so a 403 on it means something else than it does on
    /// the toggle: not a member at all, or a workspace id that is not theirs.
    func testARefusedWorkflowListAndAnOutageKeepTheirStatuses() async {
        let forbidden = RepositoryTransport(json: WorkflowBodies.forbidden, status: 403)
        let refused = await repository(forbidden).workflows(workspaceId: "ws_1")
        XCTAssertEqual(refused.failureOnly, .http(status: 403, message: "Forbidden"))
        XCTAssertEqual(refused.failureOnly?.isUnauthorized, false, "403 is not a token problem")

        let expired = RepositoryTransport(json: WorkflowBodies.unauthorized, status: 401)
        let unauthorized = await repository(expired).workflows(workspaceId: "ws_1")
        XCTAssertEqual(unauthorized.failureOnly?.isUnauthorized, true)

        let degraded = RepositoryTransport(json: WorkflowBodies.degraded, status: 503)
        let transient = await repository(degraded).workflows(workspaceId: "ws_1")
        XCTAssertEqual(transient.failureOnly?.httpStatus, 503)
        XCTAssertNil(transient.successOnly)
    }

    // MARK: - The run history

    /// ⛔ THE WHOLE ENVELOPE COMES BACK BECAUSE THE PAGING FIELDS ARE PART OF THE
    /// ANSWER. `hasMore` is the server's, computed from a real `total`, and
    /// `limit`/`offset` are echoed as the server APPLIED them: it clamps to 1...50 and
    /// REPLACES a non-numeric value rather than clamping it. Here the request asked for
    /// 50 and the reply says 4, which is the case a caller must page from the echo
    /// rather than from what it sent.
    ///
    /// ⚠️ `limit` AND `offset` GO OUT UNCLAMPED, deliberately: a second clamp in this
    /// layer would be a copy of a rule that lives on the server, and a drifted copy
    /// pages by a size the server never used, which either skips rows or repeats them.
    func testReadingRunsPassesThePagingThroughAndAdoptsTheServersEcho() async {
        let transport = RepositoryTransport(json: WorkflowBodies.runs)

        let result = await repository(transport).runs(
            workspaceId: "ws_1",
            workflowId: "wf_a",
            limit: 50,
            offset: 0
        )

        let response = result.successOnly
        XCTAssertEqual(response?.runs.map(\.status), ["success", "failed"])
        XCTAssertEqual(response?.total, 9)
        XCTAssertEqual(response?.limit, 4, "⛔ what the server applied, not what was asked")
        XCTAssertEqual(response?.hasMore, true)
        XCTAssertEqual(transport.requests.first?.method, .get)
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/workflows/runs"
                + "?workspaceId=ws_1&workflowId=wf_a&limit=50&offset=0"
        )
    }

    /// ⛔ THE RUN THAT FAILED BEFORE ANY ACTION RAN KEEPS ALL THREE OF ITS FACTS: an
    /// empty `actionResults`, a run-level `error`, and a nil `finishedAt`. A screen
    /// rendering only the per-action rows would draw it as a failure with no
    /// explanation, and one treating the nil finish as a missing value would show it
    /// running forever.
    func testAFailedRunKeepsItsRunLevelErrorAndItsUnfinishedState() async throws {
        let transport = RepositoryTransport(json: WorkflowBodies.runs)

        let result = await repository(transport).runs(
            workspaceId: "ws_1",
            workflowId: "wf_a",
            limit: 4,
            offset: 0
        )

        let failed = try XCTUnwrap(result.successOnly?.runs.last)
        XCTAssertEqual(failed.status, "failed")
        XCTAssertTrue(failed.actionResults.isEmpty)
        XCTAssertEqual(failed.error, "notify_ops webhook returned 502")
        XCTAssertNil(failed.finishedAt)
        // ⚠️ And the healthy row's per-action reason is absent rather than empty.
        XCTAssertNil(result.successOnly?.runs.first?.error)
        XCTAssertNil(result.successOnly?.runs.first?.actionResults.first?.reason)
    }

    func testARunHistoryThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(
            json: #"{"success":false,"runs":[],"total":0,"limit":10,"offset":0,"hasMore":false}"#
        )

        let result = await repository(transport).runs(
            workspaceId: "ws_1",
            workflowId: "wf_a",
            limit: 10,
            offset: 0
        )

        XCTAssertEqual(result.failureOnly, .decoding("WorkflowRunsResponse did not affirm success=true"))
    }

    /// ⚠️ A **400** HERE IS THE MISSING `workflowId` GUARD, which the server checks
    /// before the role guard even runs. This signature cannot omit it, so the status is
    /// surfaced for a stale or crafted request rather than expected.
    func testAMissingWorkflowIdAndTheUsualFailuresPassThrough() async {
        let missing = RepositoryTransport(json: WorkflowBodies.missingWorkflowId, status: 400)
        let rejected = await repository(missing).runs(
            workspaceId: "ws_1",
            workflowId: "",
            limit: 10,
            offset: 0
        )
        XCTAssertEqual(rejected.failureOnly, .http(status: 400, message: "workflowId is required"))

        let viewer = RepositoryTransport(json: WorkflowBodies.forbidden, status: 403)
        let refused = await repository(viewer).runs(
            workspaceId: "ws_1",
            workflowId: "wf_a",
            limit: 10,
            offset: 0
        )
        XCTAssertEqual(refused.failureOnly?.httpStatus, 403)

        let expired = RepositoryTransport(json: WorkflowBodies.unauthorized, status: 401)
        let unauthorized = await repository(expired).runs(
            workspaceId: "ws_1",
            workflowId: "wf_a",
            limit: 10,
            offset: 0
        )
        XCTAssertEqual(unauthorized.failureOnly?.isUnauthorized, true)

        let degraded = RepositoryTransport(json: WorkflowBodies.degraded, status: 503)
        let transient = await repository(degraded).runs(
            workspaceId: "ws_1",
            workflowId: "wf_a",
            limit: 10,
            offset: 0
        )
        XCTAssertEqual(transient.failureOnly?.httpStatus, 503)
        XCTAssertNil(transient.successOnly)
    }

    // MARK: - The toggle

    /// ⛔ **PATCH ON THE COLLECTION PATH WITH THE ID IN THE BODY**. There is no
    /// `/workflows/{id}` route at all, and a POST here would CREATE a workflow rather
    /// than update one, so the failure of getting this wrong is a new row and not an
    /// error. ⛔ And the body carries only the three keys: the same route accepts
    /// `actions`, written WHOLESALE, so a body one field wider is one empty array from
    /// deleting every action a workflow has.
    func testTogglingAWorkflowPatchesTheCollectionWithOnlyTheThreeKeys() async throws {
        let transport = RepositoryTransport(json: #"{"success":true}"#)

        let result = await repository(transport).setActive(
            workspaceId: "ws_1",
            workflowId: "wf_a",
            active: false
        )

        XCTAssertNil(result.failureOnly, "a bare success is the whole answer this route gives")
        XCTAssertEqual(transport.requests.first?.method, .patch)
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/workflows"
        )
        let body = try XCTUnwrap(transport.bodies.first)
        XCTAssertEqual(body, #"{"active":false,"workflowId":"wf_a","workspaceId":"ws_1"}"#)
        XCTAssertFalse(body.contains("actions"), "⛔ wholesale-replace field, never sent")
    }

    /// ⛔ `active: false` SPECIFICALLY, BECAUSE THE ROUTE TELLS SENT FROM ABSENT WITH
    /// `"active" in body` RATHER THAN BY TRUTHINESS. It is the single most common PATCH
    /// this endpoint receives, and a client that dropped a false value would earn a 400
    /// "nothing to update" for the ordinary case of switching something off.
    func testTurningAWorkflowOnSendsTrueAndOffSendsFalse() async {
        let off = RepositoryTransport(json: #"{"success":true}"#)
        _ = await repository(off).setActive(workspaceId: "ws_1", workflowId: "wf_a", active: false)
        XCTAssertEqual(off.bodies.first, #"{"active":false,"workflowId":"wf_a","workspaceId":"ws_1"}"#)

        let on = RepositoryTransport(json: #"{"success":true}"#)
        _ = await repository(on).setActive(workspaceId: "ws_1", workflowId: "wf_a", active: true)
        XCTAssertEqual(on.bodies.first, #"{"active":true,"workflowId":"wf_a","workspaceId":"ws_1"}"#)
    }

    /// ⛔ THE ENVELOPE GUARD IS THE ENTIRE CONTENT CHECK, because the response has no
    /// content. So the only two outcomes are "the write landed" and "revert", which is
    /// why the switch is optimistic-with-revert rather than adopting a reply.
    func testAToggleThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(json: #"{"success":false}"#)

        let result = await repository(transport).setActive(
            workspaceId: "ws_1",
            workflowId: "wf_a",
            active: false
        )

        XCTAssertEqual(result.failureOnly, .decoding("WorkflowToggleResponse did not affirm success=true"))
    }

    /// ⛔ THE TOGGLE EXCLUDES `viewer` WHILE THE LIST BESIDE IT ADMITS ONE, so a 403
    /// here is the role gate doing its job and is expected rather than exceptional. The
    /// refusal carries no machine-readable code, so it is indistinguishable from any
    /// other role refusal and the UI gates the control instead of relying on it.
    ///
    /// ⚠️ NOTHING RETRIES ON THE 503 EITHER. Setting one boolean IS idempotent
    /// server-side, so a repeat would not corrupt anything, but the reply carries no
    /// state: a retry cannot tell "the first one landed" from "neither did", so an
    /// automatic loop would hide a persistent failure behind a settled-looking screen.
    /// The honest recovery is a re-read, and that is the caller's decision.
    func testAViewersToggleAndAnOutageBothPassThroughWithoutARetry() async {
        let viewer = RepositoryTransport(json: WorkflowBodies.forbidden, status: 403)
        let refused = await repository(viewer).setActive(
            workspaceId: "ws_1",
            workflowId: "wf_a",
            active: false
        )
        XCTAssertEqual(refused.failureOnly, .http(status: 403, message: "Forbidden"))

        let expired = RepositoryTransport(json: WorkflowBodies.unauthorized, status: 401)
        let unauthorized = await repository(expired).setActive(
            workspaceId: "ws_1",
            workflowId: "wf_a",
            active: false
        )
        XCTAssertEqual(unauthorized.failureOnly?.isUnauthorized, true)

        let degraded = RepositoryTransport(json: WorkflowBodies.degraded, status: 503)
        let transient = await repository(degraded).setActive(
            workspaceId: "ws_1",
            workflowId: "wf_a",
            active: false
        )
        XCTAssertEqual(transient.failureOnly?.httpStatus, 503)
        XCTAssertEqual(degraded.requests.count, 1, "⛔ one attempt, no retry loop")
    }
}
