import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// The workspace-settings READ, which is the load every mutation form on that
/// surface has to be built from.
///
/// ⛔ THE ASSERTIONS HERE ARE ABOUT WHAT A CALLER IS ALLOWED TO BELIEVE, NOT ABOUT
/// JSON. Three of this surface's saves REPLACE their stored value wholesale, so the
/// only thing standing between a bad read and a deleted tool allowlist is that this
/// method refuses to answer `.success` with anything a form could mistake for a
/// baseline. That makes the two drift cases below — a 200 whose `config` is null,
/// and a 200 that does not affirm `success` — the most load-bearing tests in the
/// file, even though neither is a shape the healthy route emits.
///
/// ⚠️ THE FIXTURE CORPUS PINS THE WIRE SHAPE AND THIS DOES NOT.
/// `district-workspace-config.json` and `-sparse` go through the strict gate in
/// `ContractFixtureTests`; what is exercised here is envelope handling, the
/// drift refusals and the request that goes out.
final class WorkspaceConfigRepositoryTests: XCTestCase {
    private func repository(_ transport: RepositoryTransport) -> WorkspaceRepository {
        WorkspaceRepository(client: .repositoryTest(transport))
    }

    /// ⛔ THE OPAQUE BLOBS ARRIVE WHOLE, INCLUDING KEYS THIS CLIENT HAS NEVER
    /// MODELLED. `routingRules` and `callDirectory` are `Json` columns written
    /// through `.passthrough()` schemas, so a row carries whatever anyone ever
    /// wrote; a value read through a lossy type and written back would be a silent
    /// deletion answered with a 200. ``WireJSON`` is what makes that impossible,
    /// and this asserts the unmodelled key survives the decode.
    func testAConfiguredWorkspaceDecodesItsPersonaToolsAndOpaqueBlobs() async {
        let transport = RepositoryTransport(json: Self.configured)

        let result = await repository(transport).config(workspaceId: "ws_1")

        guard case let .success(config) = result else {
            return XCTFail("expected the configuration, got \(result)")
        }
        XCTAssertEqual(config.aiPersona?.greeting, "Thanks for calling.")
        XCTAssertEqual(config.toolConfig?.allowedTools, ["book_appointment", "transfer_to_creator"])
        XCTAssertEqual(config.callDirectory?.arrayValue?.count, 1)
        XCTAssertEqual(
            config.routingRules?.arrayValue?.first?["target"]?.stringValue,
            "sales",
            "an unmodelled rule key must survive the read, or a wholesale save would drop it"
        )
        XCTAssertEqual(transport.requests.first?.method, .get)
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/workspace/config?workspaceId=ws_1"
        )
    }

    /// ⛔ A BRAND-NEW WORKSPACE IS A SUCCESS, NOT A FAILURE, AND `toolConfig: null`
    /// IS NOT AN EMPTY ALLOWLIST. The route nulls a missing optional rather than
    /// dropping the key, so every field can be null at once on a perfectly healthy
    /// read. A caller reads nil `toolConfig` as EVERY TOOL ON; reading it as none
    /// and saving would switch the agent off for someone who opened the screen to
    /// look at it.
    func testAFreshWorkspaceWhoseEveryFieldIsNullIsStillASuccessfulRead() async {
        let transport = RepositoryTransport(json: Self.sparse)

        let result = await repository(transport).config(workspaceId: "ws_1")

        guard case let .success(config) = result else {
            return XCTFail("expected an empty configuration, got \(result)")
        }
        XCTAssertNil(config.toolConfig, "nil means never configured, which is not an empty allowlist")
        XCTAssertNil(config.aiPersona)
        XCTAssertNil(config.callDirectory)
    }

    /// ⛔ NO `config` KEY IS CONTRACT DRIFT AND MUST NOT BECOME AN EMPTY FORM. The
    /// route always emits it on the success path, so nil is a shape change rather
    /// than a state — and answering `.success` with nothing in hand would hand a
    /// mutation form exactly the blank baseline this read exists to prevent.
    func testASuccessCarryingNoConfigIsReportedAsDriftRatherThanAnEmptyForm() async {
        let transport = RepositoryTransport(json: #"{"success":true,"config":null}"#)

        let result = await repository(transport).config(workspaceId: "ws_1")

        XCTAssertEqual(
            result.failureOnly,
            .decoding("WorkspaceConfigResponse affirmed success with no config")
        )
    }

    /// ⛔ A WELL-FORMED `success:false` ON A **200** IS THE ROUTE'S OWN CATCH BRANCH
    /// once the headers are written, and a required field does not reject it. The
    /// envelope check is the only thing that does, and without it "we could not
    /// look" would render as a configuration.
    func testAReadThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(json: #"{"success":false,"config":{}}"#)

        let result = await repository(transport).config(workspaceId: "ws_1")

        XCTAssertEqual(result.failureOnly, .decoding("WorkspaceConfigResponse did not affirm success=true"))
    }

    /// ⛔ THE 403 IS THE VIEWER EXCLUSION AND IT IS UNUSUAL ON THIS SURFACE. Every
    /// other read here (`workspace/usage`, `workspace/list`) admits a viewer; this
    /// one does not, because the payload carries staff transfer numbers and the
    /// operator's own prompt. It reaches a caller with its status intact so the
    /// entry point can be HIDDEN rather than captioned. ⚠️ The 401 and the 503 are
    /// the two outcomes a screen has to tell that one apart from: one ends the
    /// session, the other is worth retrying.
    func testTheViewerRefusalAndTheTwoOutagesArriveWithTheirStatus() async {
        let viewer = RepositoryTransport(json: #"{"error":"Forbidden"}"#, status: 403)
        let refused = await repository(viewer).config(workspaceId: "ws_1")
        XCTAssertEqual(refused.failureOnly, .http(status: 403, message: "Forbidden"))
        XCTAssertEqual(refused.failureOnly?.isUnauthorized, false, "403 is not a token problem")

        let expired = RepositoryTransport(json: #"{"error":"Unauthorized"}"#, status: 401)
        let unauthorized = await repository(expired).config(workspaceId: "ws_1")
        XCTAssertEqual(unauthorized.failureOnly?.isUnauthorized, true)

        let degraded = RepositoryTransport(json: #"{"error":"Internal Server Error"}"#, status: 503)
        let transient = await repository(degraded).config(workspaceId: "ws_1")
        XCTAssertEqual(transient.failureOnly?.httpStatus, 503)
    }

    /// ⚠️ THE PERSONA'S READ-ONLY HALF IS DECODED EVEN THOUGH NOTHING SENDS IT
    /// BACK. It is displayed, and modelling it is what makes "the phone leaves the
    /// engine choice alone" checkable rather than a claim about code nobody reads.
    private static let configured = #"""
    {"success":true,"config":{
      "aiPersona":{"name":"Ada","greeting":"Thanks for calling.","personality":"Warm",
                   "dgiEnabled":false,"voice":"Puck","modelId":"deepgram-pipeline"},
      "toolConfig":{"allowedTools":["book_appointment","transfer_to_creator"],
                    "supportPhoneNumber":"+14165550100"},
      "routingRules":[{"id":"rule_1","match":"industry","action":"answer","target":"sales"}],
      "callDirectory":[{"name":"Front desk","phoneNumber":"+14165550101"}],
      "plan":"studio","subscriptionTier":"Studio","updatedAt":"2026-08-19T09:41:00.000Z"}}
    """#

    /// ⚠️ EVERY OPTIONAL NULL AT ONCE, which is the shape a workspace nobody has
    /// configured genuinely has — the route nulls a missing optional rather than
    /// dropping its key.
    private static let sparse = #"""
    {"success":true,"config":{
      "aiPersona":null,"toolConfig":null,"routingRules":null,"callDirectory":null,
      "messagingConfig":null,"campaignSettings":null,"creatorCellNumber":null,
      "plan":null,"subscriptionTier":null,"updatedAt":null}}
    """#
}
