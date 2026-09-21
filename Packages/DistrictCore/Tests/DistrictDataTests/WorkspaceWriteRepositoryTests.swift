import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// The three workspace-settings writes.
///
/// ⛔ THE ASSERTIONS HERE ARE MOSTLY ABOUT THE REQUEST RATHER THAN THE RESPONSE,
/// WHICH IS UNUSUAL AND IS FORCED BY THE SURFACE. Every one of these routes
/// answers the same bare `{"success": true}`, so there is nothing in a reply to
/// get wrong; what can be got wrong is the bytes that went out. `persona` MERGES
/// per field, so a key that should have been dropped and was not overwrites a
/// setting nobody touched; `tools` and `routing-rules` REPLACE wholesale, so a key
/// that should have been sent and was not deletes the stored value and answers
/// 200.
///
/// ⚠️ THE BODIES ARE ASSERTED BYTE FOR BYTE because ``JSONValue/object(_:)`` drops
/// a nil pair SILENTLY by design. "Did this request carry a greeting" is therefore
/// a question about the encoded document rather than about the arguments, and
/// `JSONWire.encode` sorts keys so the comparison is deterministic.
final class WorkspaceWriteRepositoryTests: XCTestCase {
    private func repository(_ transport: RepositoryTransport) -> WorkspaceRepository {
        WorkspaceRepository(client: .repositoryTest(transport))
    }

    // MARK: - Persona

    /// ⛔ A NIL FIELD IS ABSENT FROM THE WIRE, AND THAT ABSENCE IS THE MECHANISM
    /// THAT PRESERVES IT. The route writes `x !== undefined ? x : existing`, so the
    /// only way to leave the personality alone is to not mention it. A client that
    /// sent nil as null would CLEAR it, with a 200 and no error anywhere.
    func testSavingAPersonaPatchesOnlyTheFieldsItWasGiven() async {
        let transport = RepositoryTransport(json: #"{"success":true}"#)

        let result = await repository(transport).savePersona(
            workspaceId: "ws_1",
            name: "Ada",
            greeting: "Thanks for calling.",
            personality: nil,
            dgiEnabled: nil
        )

        XCTAssertNil(result.failureOnly, "a bare success is the whole answer this route gives")
        XCTAssertEqual(transport.requests.first?.method, .patch)
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/workspace/persona"
        )
        XCTAssertEqual(
            transport.bodies.first,
            #"{"greeting":"Thanks for calling.","name":"Ada","workspaceId":"ws_1"}"#
        )
    }

    /// ⛔ AN EMPTY STRING IS A DELIBERATE CLEAR AND SURVIVES TO THE WIRE. nil means
    /// "leave it alone" and `""` means "make it blank", and they are one Optional
    /// apart: anything that helpfully mapped blank to nil would make a cleared
    /// greeting silently un-clearable, which is the shape the web form supports.
    func testAnEmptyGreetingIsSentAsAClearRatherThanDropped() async {
        let transport = RepositoryTransport(json: #"{"success":true}"#)

        _ = await repository(transport).savePersona(
            workspaceId: "ws_1",
            name: nil,
            greeting: "",
            personality: nil,
            dgiEnabled: nil
        )

        XCTAssertEqual(transport.bodies.first, #"{"greeting":"","workspaceId":"ws_1"}"#)
    }

    /// ⚠️ `false` IS A VALUE AND MUST REACH THE WIRE. Only an explicit boolean
    /// changes the consent flag server-side (a non-boolean is IGNORED and still
    /// answers 200), so dropping `false` the way a nil is dropped would make the
    /// opt-out unexpressible while looking like it had worked.
    func testTurningTheEnrichmentConsentOffSendsTheBooleanRatherThanOmittingIt() async {
        let transport = RepositoryTransport(json: #"{"success":true}"#)

        _ = await repository(transport).savePersona(
            workspaceId: "ws_1",
            name: nil,
            greeting: nil,
            personality: nil,
            dgiEnabled: false
        )

        XCTAssertEqual(transport.bodies.first, #"{"dgiEnabled":false,"workspaceId":"ws_1"}"#)
    }

    func testAPersonaSaveThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(json: #"{"success":false}"#)

        let result = await repository(transport).savePersona(
            workspaceId: "ws_1",
            name: "Ada",
            greeting: nil,
            personality: nil,
            dgiEnabled: nil
        )

        XCTAssertEqual(result.failureOnly, .decoding("PersonaPatchResponse did not affirm success=true"))
    }

    /// ⛔ THE 403 IS USUALLY AN ENTITLEMENT AND NOT THE CALLER'S ROLE, AND ITS
    /// SENTENCE IS THE PRODUCT. Turning `dgiEnabled` on for a workspace that is not
    /// on Voice Studio answers `dgi_requires_studio` with copy that names the
    /// upgrade; replacing it with "you do not have permission" would send the
    /// operator hunting through their own account for a switch that lives on the
    /// plan. ⚠️ The 401 and the 503 are here too because they are the two outcomes a
    /// screen has to tell apart from that one: one ends the session, the other is
    /// worth retrying.
    func testPersonaRefusalsAndOutagesArriveWithTheirStatusAndSentence() async {
        let studio = RepositoryTransport(
            json: #"{"success":false,"code":"dgi_requires_studio","error":"\#(Self.studioSentence)"}"#,
            status: 403
        )
        let forbidden = await repository(studio).savePersona(
            workspaceId: "ws_1",
            name: nil,
            greeting: nil,
            personality: nil,
            dgiEnabled: true
        )
        XCTAssertEqual(forbidden.failureOnly, .http(status: 403, message: Self.studioSentence))

        let expired = RepositoryTransport(json: #"{"error":"Unauthorized"}"#, status: 401)
        let unauthorized = await repository(expired).savePersona(
            workspaceId: "ws_1",
            name: "Ada",
            greeting: nil,
            personality: nil,
            dgiEnabled: nil
        )
        XCTAssertEqual(unauthorized.failureOnly?.isUnauthorized, true)

        let degraded = RepositoryTransport(json: #"{"success":false,"error":"Try again"}"#, status: 503)
        let transient = await repository(degraded).savePersona(
            workspaceId: "ws_1",
            name: "Ada",
            greeting: nil,
            personality: nil,
            dgiEnabled: nil
        )
        XCTAssertEqual(transient.failureOnly?.httpStatus, 503)
    }

    // MARK: - Tools

    /// ⛔ THE LIST GOES OUT EXACTLY AS GIVEN, INCLUDING AN ID THIS CLIENT DOES NOT
    /// RECOGNISE. `transfer_to_creator` was retired in 2026 and workspaces still
    /// store it, so a list rebuilt from a hardcoded catalog would drop it on the
    /// next save. Order and content are the contract.
    func testSavingToolsCarriesTheLoadedListWholeIncludingRetiredIds() async {
        let transport = RepositoryTransport(json: #"{"success":true}"#)

        let result = await repository(transport).saveTools(
            workspaceId: "ws_1",
            allowedTools: ["book_appointment", "transfer_to_creator", "check_support_request"]
        )

        XCTAssertNil(result.failureOnly, "a bare success is the whole answer this route gives")
        XCTAssertEqual(transport.requests.first?.method, .patch)
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/workspace/tools"
        )
        XCTAssertEqual(
            transport.bodies.first,
            #"{"allowedTools":["book_appointment","transfer_to_creator","check_support_request"],"#
                + #""workspaceId":"ws_1"}"#
        )
    }

    /// ⛔ AN EMPTY LIST IS A LEGITIMATE SAVE AND IS NOT REFUSED HERE. An operator
    /// who wants no tools must be able to say so; the guard is a confirmation in the
    /// UI, not a repository second-guessing a request it was given. ⚠️ The key is
    /// still SENT, because omitting it is a 400 rather than a no-op.
    func testAnEmptyToolListIsStillSentRatherThanOmitted() async {
        let transport = RepositoryTransport(json: #"{"success":true}"#)

        _ = await repository(transport).saveTools(workspaceId: "ws_1", allowedTools: [])

        XCTAssertEqual(transport.bodies.first, #"{"allowedTools":[],"workspaceId":"ws_1"}"#)
    }

    func testAToolsSaveThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(json: #"{"success":false}"#)

        let result = await repository(transport).saveTools(workspaceId: "ws_1", allowedTools: ["book_appointment"])

        XCTAssertEqual(result.failureOnly, .decoding("ToolsPatchResponse did not affirm success=true"))
    }

    /// ⚠️ A 403 HERE REALLY IS THE ROLE GATE, unlike the persona case above: a
    /// `viewer` may not change tool configuration. Both it and the 503 pass through
    /// untouched.
    func testAViewersToolsSaveAndAnOutageBothPassThrough() async {
        let viewer = RepositoryTransport(json: #"{"success":false,"error":"Forbidden"}"#, status: 403)
        let refused = await repository(viewer).saveTools(workspaceId: "ws_1", allowedTools: [])
        XCTAssertEqual(refused.failureOnly, .http(status: 403, message: "Forbidden"))
        XCTAssertEqual(refused.failureOnly?.isUnauthorized, false, "403 is not a token problem")

        let degraded = RepositoryTransport(json: #"{"success":false,"error":"Try again"}"#, status: 503)
        let transient = await repository(degraded).saveTools(workspaceId: "ws_1", allowedTools: [])
        XCTAssertEqual(transient.failureOnly?.httpStatus, 503)

        let expired = RepositoryTransport(json: #"{"error":"Unauthorized"}"#, status: 401)
        let unauthorized = await repository(expired).saveTools(workspaceId: "ws_1", allowedTools: [])
        XCTAssertEqual(unauthorized.failureOnly?.isUnauthorized, true)
    }

    // MARK: - Routing rules

    /// ⛔ **POST, NOT PATCH**, and the rows go out WHOLE. The route's per-rule schema
    /// is `.passthrough()` and the column is `Json`, so a rule carries keys this
    /// client has never modelled (`match`, `action`, `target` in the committed
    /// fixture) and a request rebuilt from a typed model would strip them and answer
    /// 200. Passing ``JSONValue`` rows straight from a loaded config is what keeps
    /// that from being expressible.
    func testSavingRoutingRulesPostsTheRowsWholeIncludingUnmodelledKeys() async {
        let transport = RepositoryTransport(json: #"{"success":true}"#)
        let stored: [JSONValue] = [
            .object([
                "id": .string("rule_1"),
                "match": .string("industry"),
                "action": .string("answer"),
                "voice": .string("Puck"),
            ]),
        ]

        let result = await repository(transport).saveRoutingRules(workspaceId: "ws_1", routingRules: stored)

        XCTAssertNil(result.failureOnly, "a bare success is the whole answer this route gives")
        XCTAssertEqual(transport.requests.first?.method, .post)
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/workspace/routing-rules"
        )
        XCTAssertEqual(
            transport.bodies.first,
            #"{"routingRules":[{"action":"answer","id":"rule_1","match":"industry","voice":"Puck"}],"#
                + #""workspaceId":"ws_1"}"#
        )
    }

    /// ⛔ AN EMPTY ARRAY IS ACCEPTED SERVER-SIDE AND DELETES EVERY RULE, and it is
    /// still sent rather than refused here for the reason the empty tool list is.
    /// ⚠️ An OMITTED array is a 400 instead, which the non-optional parameter makes
    /// unreachable from this client.
    func testAnEmptyRoutingRuleArrayIsSentAndIsAWipe() async {
        let transport = RepositoryTransport(json: #"{"success":true}"#)

        _ = await repository(transport).saveRoutingRules(workspaceId: "ws_1", routingRules: [])

        XCTAssertEqual(transport.bodies.first, #"{"routingRules":[],"workspaceId":"ws_1"}"#)
    }

    func testARoutingRulesSaveThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(json: #"{"success":false}"#)

        let result = await repository(transport).saveRoutingRules(workspaceId: "ws_1", routingRules: [])

        XCTAssertEqual(result.failureOnly, .decoding("RoutingRulesResponse did not affirm success=true"))
    }

    /// ⛔ THE 400 IS A REAL, SPECIFIC REFUSAL AND ITS SENTENCE NAMES THE OFFENDING
    /// VALUE. A workspace that restricts voices rejects a rule naming one outside
    /// its allow-list, and this client cannot see that list and deliberately does
    /// not pre-validate against a guess, so the server's words are the only useful
    /// thing to show.
    ///
    /// ⚠️ THIS ROUTE'S FAILURE BODIES CARRY NO `success` KEY, unlike the two writes
    /// above: a bare `{error}`. It costs nothing, because the status is what maps
    /// the failure and the envelope check only ever runs on a 2xx, and this is where
    /// that asymmetry is recorded.
    func testAnUnallowedVoiceArrivesAsA400WithTheServersOwnSentence() async {
        let refused = RepositoryTransport(json: #"{"error":"Invalid voice identifier: Fenrir"}"#, status: 400)
        let result = await repository(refused).saveRoutingRules(workspaceId: "ws_1", routingRules: [])
        XCTAssertEqual(result.failureOnly, .http(status: 400, message: "Invalid voice identifier: Fenrir"))

        let expired = RepositoryTransport(json: #"{"error":"Unauthorized"}"#, status: 401)
        let unauthorized = await repository(expired).saveRoutingRules(workspaceId: "ws_1", routingRules: [])
        XCTAssertEqual(unauthorized.failureOnly?.isUnauthorized, true)

        let degraded = RepositoryTransport(json: #"{"error":"Internal Server Error"}"#, status: 503)
        let transient = await repository(degraded).saveRoutingRules(workspaceId: "ws_1", routingRules: [])
        XCTAssertEqual(transient.failureOnly?.httpStatus, 503)
    }

    /// ⛔ BUILT BY CONCATENATION RATHER THAN WRAPPED INSIDE THE JSON. A raw
    /// multi-line string may break between JSON tokens, but a newline INSIDE a
    /// string value is invalid JSON, and the failure it produces reads as a bug in
    /// the repository under test rather than in the fixture.
    private static let studioSentence = "DGI Lead Enrichment is included with Voice Studio. "
        + "Upgrade to enable it."
}
