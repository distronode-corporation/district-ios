import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// The always-on SDR campaign: reading its state, and pausing or resuming it.
///
/// ⛔ THE SAME REPOSITORY AS `WorkflowsRepositoryTests`, SPLIT ONLY BY FILE LENGTH,
/// and the pairing is worth keeping in mind while reading either half: the workflow
/// toggle and the campaign pause are two writes on one screen that need OPPOSITE UI
/// designs, and the reason is entirely what their replies carry. The toggle answers a
/// bare `{success:true}`, so a switch is optimistic-with-revert; the pause answers the
/// READ's whole shape from the object it merged, so the caller adopts it.
///
/// ⛔ AND THE UNCONFIGURED CAMPAIGN IS A STATE, NEVER AN ERROR AND NEVER AN ABSENCE.
/// The route normalises absent and off into one rendering, so `{false, null, null}` is
/// what every workspace that has never opened the campaigns tab answers. What must
/// NOT happen is that rendering being produced from a body that said nothing, which is
/// why the repository unwraps rather than handing out the Optional.
final class CampaignRepositoryTests: XCTestCase {
    private func repository(_ transport: RepositoryTransport) -> WorkflowsRepository {
        WorkflowsRepository(client: .repositoryTest(transport))
    }

    // MARK: - Reading the campaign

    func testReadingTheCampaignGetsTheStatusRouteAndUnwrapsTheObject() async {
        let transport = RepositoryTransport(json: WorkflowBodies.campaignRunning)

        let result = await repository(transport).campaignStatus(workspaceId: "ws_1")

        XCTAssertEqual(result.successOnly?.infiniteSdrEnabled, true)
        XCTAssertEqual(result.successOnly?.sdrBatchSize, 25)
        XCTAssertEqual(result.successOnly?.sdrCampaignGoal, "Book demos with lapsed trials")
        XCTAssertEqual(transport.requests.first?.method, .get)
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/workspace/campaign-status?workspaceId=ws_1"
        )
        XCTAssertTrue(transport.bodies.isEmpty, "a GET carries no body")
    }

    /// ⛔ THE UNCONFIGURED CAMPAIGN IS A SUCCESS CARRYING TWO NILS, AND NEITHER MAY BE
    /// READ AS A ZERO OR AN EMPTY STRING. `sdrBatchSize` is null rather than 0 because
    /// the settings PATCH floors it to at least 1, so 0 cannot be stored and a client
    /// rendering nil as 0 would state how many people a live outbound campaign calls
    /// from a field that said nothing.
    func testAnUnconfiguredCampaignIsAStateRatherThanAFailure() async {
        let transport = RepositoryTransport(json: WorkflowBodies.campaignEmpty)

        let result = await repository(transport).campaignStatus(workspaceId: "ws_1")

        XCTAssertNil(result.failureOnly, "⛔ never an error: this is most workspaces")
        XCTAssertEqual(result.successOnly?.infiniteSdrEnabled, false)
        XCTAssertNil(result.successOnly?.sdrBatchSize)
        XCTAssertNil(result.successOnly?.sdrCampaignGoal)
    }

    /// ⛔ A 200 WITH NO `campaign` IS DRIFT, NOT AN UNCONFIGURED CAMPAIGN, AND THIS IS
    /// THE ASSERTION THE UNWRAPPING EXISTS FOR. Both verbs always send the object,
    /// because the route normalises every field itself; handing a caller the Optional
    /// would make every screen re-decide what nil means, and the tempting answer is the
    /// wrong one: "paused, no batch size, no goal" is a confident claim about
    /// somebody's live outbound campaign made from a body that said nothing at all.
    func testAnAffirmedBodyWithNoCampaignIsADecodeFailure() async {
        let transport = RepositoryTransport(json: #"{"success":true}"#)

        let result = await repository(transport).campaignStatus(workspaceId: "ws_1")

        XCTAssertEqual(result.failureOnly, .decoding("CampaignStatusResponse carried no campaign"))
        XCTAssertNil(result.successOnly)
    }

    func testACampaignReadThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(json: WorkflowBodies.campaignNotAffirmed)

        let result = await repository(transport).campaignStatus(workspaceId: "ws_1")

        XCTAssertEqual(
            result.failureOnly,
            .decoding("CampaignStatusResponse did not affirm success=true")
        )
    }

    /// ⚠️ A **404** MEANS THE WORKSPACE ID DID NOT RESOLVE, which is distinct again
    /// from "no campaign": that is a 200 with all three fields at their empty values.
    /// ⚠️ The read admits `viewer`, so a 403 here means not a member at all.
    func testAnUnresolvedWorkspaceAndTheUsualFailuresPassThrough() async {
        let missing = RepositoryTransport(json: WorkflowBodies.workspaceNotFound, status: 404)
        let unresolved = await repository(missing).campaignStatus(workspaceId: "ws_gone")
        XCTAssertEqual(unresolved.failureOnly, .http(status: 404, message: "Workspace not found"))
        XCTAssertNil(unresolved.successOnly, "⛔ not the same as an unconfigured campaign")

        let forbidden = RepositoryTransport(json: WorkflowBodies.forbidden, status: 403)
        let refused = await repository(forbidden).campaignStatus(workspaceId: "ws_1")
        XCTAssertEqual(refused.failureOnly?.httpStatus, 403)
        XCTAssertEqual(refused.failureOnly?.isUnauthorized, false)

        let expired = RepositoryTransport(json: WorkflowBodies.unauthorized, status: 401)
        let unauthorized = await repository(expired).campaignStatus(workspaceId: "ws_1")
        XCTAssertEqual(unauthorized.failureOnly?.isUnauthorized, true)

        let degraded = RepositoryTransport(json: WorkflowBodies.degraded, status: 503)
        let transient = await repository(degraded).campaignStatus(workspaceId: "ws_1")
        XCTAssertEqual(transient.failureOnly?.httpStatus, 503)
    }

    // MARK: - Pausing and resuming

    /// ⛔ IT PATCHES `campaign-status`, NOT `campaign-settings`, AND THE PATH IS THE
    /// WHOLE FEATURE. The same `{infiniteSdrEnabled:false}` sent to the settings route
    /// would WIPE the goal text and reset the batch size to 1, with a 200; this route
    /// spreads the stored Json and assigns one key. The URL is asserted for that
    /// reason rather than as boilerplate.
    ///
    /// ⛔ AND THE REPLY IS ADOPTED. It is the READ's shape, derived from the object the
    /// server just merged rather than re-read, so the two fields the request never
    /// mentioned come back intact and there is no window in which the client and the
    /// server disagree.
    func testPausingPatchesTheStatusPathAndAdoptsThePostWriteState() async {
        let transport = RepositoryTransport(json: WorkflowBodies.campaignPaused)

        let result = await repository(transport).setCampaignEnabled(
            workspaceId: "ws_1",
            enabled: false
        )

        XCTAssertEqual(result.successOnly?.infiniteSdrEnabled, false)
        XCTAssertEqual(result.successOnly?.sdrBatchSize, 25, "⛔ not reset to 1")
        XCTAssertEqual(
            result.successOnly?.sdrCampaignGoal,
            "Book demos with lapsed trials",
            "⛔ not wiped: this is why the pause goes through campaign-status"
        )
        XCTAssertEqual(transport.requests.first?.method, .patch)
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/workspace/campaign-status"
        )
        XCTAssertEqual(
            transport.bodies.first,
            #"{"infiniteSdrEnabled":false,"workspaceId":"ws_1"}"#
        )
    }

    /// ⚠️ THE PAUSE IS IDEMPOTENT AND A CALLER MAY REPEAT IT, which is the one write on
    /// this surface where that is both true and useful: the route assigns one boolean
    /// into a spread of the stored object, so sending the same value twice leaves the
    /// same state, AND the reply re-answers the question rather than leaving the client
    /// guessing. ⛔ That is permission for an operator to press the control again, not
    /// permission to poll: each call is still a write to a live campaign
    /// configuration, so nothing here loops on its own.
    func testRepeatingThePauseIsSafeAndEachCallIsOneRequest() async {
        let transport = RepositoryTransport(queue: [
            WorkflowBodies.campaignPaused,
            WorkflowBodies.campaignPaused,
        ])
        let repository = repository(transport)

        let first = await repository.setCampaignEnabled(workspaceId: "ws_1", enabled: false)
        let second = await repository.setCampaignEnabled(workspaceId: "ws_1", enabled: false)

        XCTAssertEqual(first.successOnly?.infiniteSdrEnabled, false)
        XCTAssertEqual(second.successOnly?.infiniteSdrEnabled, false, "the same state, re-answered")
        XCTAssertEqual(transport.requests.count, 2, "two presses, two requests, no retries of either")
        XCTAssertEqual(transport.bodies.count, 2)
    }

    /// ⚠️ RESUMING IS THE SAME CALL WITH `true`, and the boolean reaches the wire rather
    /// than being dropped: a non-boolean is a **400** server-side rather than a
    /// coercion, deliberately, because `Boolean("false")` is `true` and would resume a
    /// campaign somebody just paused.
    func testResumingSendsTrueAndIsTheSameCall() async {
        let transport = RepositoryTransport(json: WorkflowBodies.campaignRunning)

        let result = await repository(transport).setCampaignEnabled(workspaceId: "ws_1", enabled: true)

        XCTAssertEqual(result.successOnly?.infiniteSdrEnabled, true)
        XCTAssertEqual(
            transport.bodies.first,
            #"{"infiniteSdrEnabled":true,"workspaceId":"ws_1"}"#
        )
    }

    func testAPauseThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(json: WorkflowBodies.campaignNotAffirmed)

        let result = await repository(transport).setCampaignEnabled(
            workspaceId: "ws_1",
            enabled: false
        )

        XCTAssertEqual(
            result.failureOnly,
            .decoding("CampaignStatusResponse did not affirm success=true")
        )
    }

    /// ⛔ AN AFFIRMED PAUSE WITH NO `campaign` IS DRIFT, AND IT IS WORSE ON THIS PATH
    /// THAN ON THE READ. The empty rendering here would read as the state the operator
    /// just created, so the shared unwrapping refuses it on both.
    func testAnAffirmedPauseWithNoCampaignIsADecodeFailure() async {
        let transport = RepositoryTransport(json: #"{"success":true}"#)

        let result = await repository(transport).setCampaignEnabled(
            workspaceId: "ws_1",
            enabled: false
        )

        XCTAssertEqual(result.failureOnly, .decoding("CampaignStatusResponse carried no campaign"))
    }

    /// ⛔ THE PATCH EXCLUDES `viewer` WHILE THE GET ON THE SAME PATH ADMITS ONE. It is
    /// the only verb split in this API: watching a campaign and pausing one are
    /// different powers.
    ///
    /// ⚠️ AND A NON-BOOLEAN IS A 400 rather than a coercion, which this signature
    /// cannot produce and which is why the parameter is non-optional.
    func testAViewersPauseAndAnOutageBothPassThrough() async {
        let viewer = RepositoryTransport(json: WorkflowBodies.forbidden, status: 403)
        let refused = await repository(viewer).setCampaignEnabled(workspaceId: "ws_1", enabled: false)
        XCTAssertEqual(refused.failureOnly, .http(status: 403, message: "Forbidden"))
        XCTAssertEqual(refused.failureOnly?.isUnauthorized, false, "403 is not a token problem")

        let malformed = RepositoryTransport(json: WorkflowBodies.notABoolean, status: 400)
        let rejected = await repository(malformed).setCampaignEnabled(
            workspaceId: "ws_1",
            enabled: false
        )
        XCTAssertEqual(
            rejected.failureOnly,
            .http(status: 400, message: "infiniteSdrEnabled must be a boolean")
        )

        let expired = RepositoryTransport(json: WorkflowBodies.unauthorized, status: 401)
        let unauthorized = await repository(expired).setCampaignEnabled(
            workspaceId: "ws_1",
            enabled: false
        )
        XCTAssertEqual(unauthorized.failureOnly?.isUnauthorized, true)

        let degraded = RepositoryTransport(json: WorkflowBodies.degraded, status: 503)
        let transient = await repository(degraded).setCampaignEnabled(
            workspaceId: "ws_1",
            enabled: false
        )
        XCTAssertEqual(transient.failureOnly?.httpStatus, 503)
        XCTAssertNil(transient.successOnly)
    }
}
