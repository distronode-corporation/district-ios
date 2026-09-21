import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// District HQ's two operations, and the guarantee that keeps them apart.
///
/// ⛔ THE ASSERTIONS HERE ARE MOSTLY ABOUT WHAT THIS LAYER REFUSES TO DO. The
/// two-step is the product: the model may only PROPOSE a write and nothing is
/// applied until a confirm carries that proposal back. So the interesting outcomes
/// are the ones where the server's answer is not usable as-is: a
/// `needsConfirmation` with nothing to confirm, and a confirm that came back naming
/// a DIFFERENT tool than the one approved, and both are reported as drift rather
/// than rendered.
///
/// ⛔ AND ONE GUARANTEE IS EXPRESSED IN THE SIGNATURE RATHER THAN IN A TEST.
/// ``HQRepository/confirm(workspaceId:pendingWrite:)`` takes an ``HqPendingWrite``,
/// which can only be obtained from a prompt response, so a caller cannot assemble
/// an action the operator never read. There is no test for that because there is no
/// way to write the call that would fail it.
final class HQRepositoryTests: XCTestCase {
    // MARK: - Asking

    func testAskingPostsThePromptAndHistoryAndAnswersThePlainReply() async {
        let transport = RepositoryTransport(json: HQBodies.plainAnswer)

        let result = await HQRepository(client: .repositoryTest(transport)).ask(
            workspaceId: "ws_1",
            prompt: "How did we do this week?",
            history: [
                .object(["role": .string("user"), "text": .string("Hello")]),
                .object(["role": .string("model"), "text": .string("Ask me about your calls.")]),
            ]
        )

        XCTAssertEqual(result.successOnly?.answer, "You had 19 calls this week.")
        XCTAssertNil(result.successOnly?.pendingWrite)
        XCTAssertEqual(transport.requests.first?.method, .post)
        XCTAssertEqual(transport.requestedURLs.first, "https://www.distronode.com/api/district/hq")
        // ⛔ THE ROLE VOCABULARY IS `user` AND `model`, NOT `assistant`. The server
        // feeds these straight into the model's content list and DROPS any turn whose
        // role is neither, silently, so a client using the more usual word would lose
        // half the conversation and be told nothing. Pinned on the bytes.
        XCTAssertEqual(
            transport.bodies.first,
            #"{"history":[{"role":"user","text":"Hello"},"#
                + #"{"role":"model","text":"Ask me about your calls."}],"#
                + #""prompt":"How did we do this week?","workspaceId":"ws_1"}"#
        )
    }

    /// ⚠️ AN EMPTY HISTORY IS SENT AS `[]` RATHER THAN OMITTED, and it is safe either
    /// way here because the route gates the replay on the value being an array, so
    /// absent and empty take the same branch. Worth pinning because the equivalent
    /// default on a message send once let the SERVER's own different default apply.
    func testAFirstTurnSendsAnEmptyHistoryArray() async {
        let transport = RepositoryTransport(json: HQBodies.plainAnswer)

        _ = await HQRepository(client: .repositoryTest(transport)).ask(
            workspaceId: "ws_1",
            prompt: "Hello"
        )

        XCTAssertEqual(
            transport.bodies.first,
            #"{"history":[],"prompt":"Hello","workspaceId":"ws_1"}"#
        )
    }

    /// ⛔ A PROPOSAL IS CARRIED THROUGH WHOLE, BECAUSE THE WHOLE THING IS WHAT THE
    /// CONFIRM TAKES. The summary the operator reads and the arguments that get
    /// applied travel together and cannot come apart.
    func testAProposalIsCarriedThroughAsTheHandleTheConfirmNeeds() async throws {
        let transport = RepositoryTransport(json: HQBodies.proposal)

        let result = await HQRepository(client: .repositoryTest(transport)).ask(
            workspaceId: "ws_1",
            prompt: "Change the greeting"
        )

        let answer = try XCTUnwrap(result.successOnly)
        let pending = try XCTUnwrap(answer.pendingWrite)
        XCTAssertEqual(pending.tool, "update_persona")
        XCTAssertEqual(pending.summary, "Update the AI receptionist persona.")
        XCTAssertEqual(pending.args["greeting"]?.stringValue, "Good afternoon.")
    }

    /// ⛔ `needsConfirmation` WITH NO `pendingWrite` IS A MALFORMED RESPONSE, NOT AN
    /// ANSWER. The server said "the operator must confirm this" and then sent nothing
    /// to confirm. The tempting fallback (show the answer, drop the flag) is the
    /// worst option available: the model has just told the operator in prose that it
    /// proposed a change, and the screen would offer no way to apply it and no
    /// indication anything was missing. They read that as "done".
    func testAConfirmationFlagWithNothingToConfirmIsADecodeFailure() async {
        let transport = RepositoryTransport(json: HQBodies.flagWithoutProposal)

        let result = await HQRepository(client: .repositoryTest(transport)).ask(
            workspaceId: "ws_1",
            prompt: "Change the greeting"
        )

        XCTAssertEqual(
            result.failureOnly,
            .decoding("HqPromptResponse set needsConfirmation with no pendingWrite to confirm")
        )
    }

    /// ⚠️ THE MIRROR CASE IS DELIBERATELY NOT AN ERROR. A `pendingWrite` present
    /// WITHOUT the flag is treated as a proposal anyway: the payload is the
    /// substantive half and the flag is a summary of it, so trusting the payload fails
    /// toward ASKING rather than toward acting.
    func testAProposalWithoutTheFlagIsStillTreatedAsAProposal() async {
        let transport = RepositoryTransport(json: HQBodies.proposalWithoutFlag)

        let result = await HQRepository(client: .repositoryTest(transport)).ask(
            workspaceId: "ws_1",
            prompt: "Change the greeting"
        )

        XCTAssertNil(result.failureOnly)
        XCTAssertEqual(result.successOnly?.pendingWrite?.tool, "update_persona")
    }

    func testAnAnswerThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(json: #"{"success":false,"answer":"nope"}"#)

        let result = await HQRepository(client: .repositoryTest(transport)).ask(
            workspaceId: "ws_1",
            prompt: "Hello"
        )

        XCTAssertEqual(result.failureOnly, .decoding("HqPromptResponse did not affirm success=true"))
    }

    /// ⚠️ THE 429 IS PER ACCOUNT AND IS SHARED BY BOTH OPERATIONS, so it is surfaced
    /// rather than absorbed: an operator who has just been rate limited on a question
    /// needs to know why their confirm will not go through either.
    func testTheRateLimitAndTheUsualFailuresPassThroughOnAsk() async {
        let capped = RepositoryTransport(json: HQBodies.rateLimited, status: 429)
        let limited = await HQRepository(client: .repositoryTest(capped)).ask(
            workspaceId: "ws_1",
            prompt: "Hello"
        )
        XCTAssertEqual(limited.failureOnly?.httpStatus, 429)
        XCTAssertEqual(limited.failureOnly?.message, HQBodies.rateLimitSentence)

        let viewer = RepositoryTransport(json: HQBodies.forbidden, status: 403)
        let refused = await HQRepository(client: .repositoryTest(viewer)).ask(
            workspaceId: "ws_1",
            prompt: "Hello"
        )
        XCTAssertEqual(refused.failureOnly?.httpStatus, 403)
        XCTAssertEqual(refused.failureOnly?.isUnauthorized, false, "403 is not a token problem")

        let expired = RepositoryTransport(json: HQBodies.unauthorized, status: 401)
        let unauthorized = await HQRepository(client: .repositoryTest(expired)).ask(
            workspaceId: "ws_1",
            prompt: "Hello"
        )
        XCTAssertEqual(unauthorized.failureOnly?.isUnauthorized, true)

        let degraded = RepositoryTransport(json: HQBodies.degraded, status: 503)
        let transient = await HQRepository(client: .repositoryTest(degraded)).ask(
            workspaceId: "ws_1",
            prompt: "Hello"
        )
        XCTAssertEqual(transient.failureOnly?.httpStatus, 503)
        XCTAssertNil(transient.successOnly)
    }

    // MARK: - Confirming

    /// ⛔ THE PROPOSAL'S ARGUMENTS GO OUT VERBATIM, AND THIS IS THE ASSERTION THE
    /// WHOLE TWO-STEP RESTS ON. The confirmed action has to be byte-identical to the
    /// one whose summary the operator read; re-deriving, re-ordering or "cleaning up"
    /// the arguments would apply a different change from the one described. Every JSON
    /// kind is in the body for one reason: this is the only place in the package where
    /// a value crosses from the response-side carrier (``WireJSON``, which drops
    /// nothing) to the request-side builder (``JSONValue``, whose object factory drops
    /// nils), so each case of that mapping is exercised here. ⛔ An integer must not
    /// become a float and a null must not become an omission.
    ///
    /// ⚠️ ONE REQUEST, ASSERTED. This executes a real write and nothing may retry it.
    func testConfirmingSendsTheApprovedToolAndItsArgumentsVerbatim() async throws {
        let transport = RepositoryTransport(json: HQBodies.executed)
        let pending = try Self.pendingWrite(from: HQBodies.richProposal)

        let result = await HQRepository(client: .repositoryTest(transport)).confirm(
            workspaceId: "ws_1",
            pendingWrite: pending
        )

        XCTAssertEqual(result.successOnly?.tool, "update_persona")
        XCTAssertEqual(result.successOnly?.executed, true)
        XCTAssertEqual(transport.requests.count, 1, "⛔ a real write: never retried")
        XCTAssertEqual(transport.requests.first?.method, .post)
        XCTAssertEqual(
            transport.bodies.first,
            #"{"confirm":{"args":{"greeting":"Good afternoon.","nested":{"depth":2},"#
                + #""temperature":0.5,"tone":null,"voices":["Puck",1,true]},"#
                + #""tool":"update_persona"},"workspaceId":"ws_1"}"#
        )
    }

    /// ⛔ THE SERVER'S ECHO IS CHECKED RATHER THAN TRUSTED, AND A MISMATCH IS DRIFT
    /// RATHER THAN SUCCESS. "We applied something, but not what you approved" has no
    /// honest rendering, and treating it as done is how a deletion gets attributed to
    /// a persona edit. ⚠️ Compared exactly, with no trimming and no case folding: both
    /// sides are machine-generated identifiers from a fixed catalog, so a difference in
    /// case is drift and not a formatting variation to smooth over.
    func testAConfirmThatEchoesADifferentToolIsReportedAsDrift() async throws {
        let transport = RepositoryTransport(json: HQBodies.executedOtherTool)
        let pending = try Self.pendingWrite(from: HQBodies.richProposal)

        let result = await HQRepository(client: .repositoryTest(transport)).confirm(
            workspaceId: "ws_1",
            pendingWrite: pending
        )

        XCTAssertEqual(
            result.failureOnly,
            .decoding("HqConfirmResponse echoed a different tool than the one approved")
        )
        XCTAssertNil(result.successOnly, "⛔ never reported as done")
    }

    /// ⚠️ `executed: false` IS NOT A FAILURE OF THIS CALL. The request was handled and
    /// the write was declined (a view-only role, or a tool that refused internally),
    /// so it comes back as a success carrying the flag, and the caller says "not
    /// applied" rather than "failed".
    func testADeclinedWriteIsASuccessCarryingExecutedFalse() async throws {
        let transport = RepositoryTransport(json: HQBodies.declined)
        let pending = try Self.pendingWrite(from: HQBodies.richProposal)

        let result = await HQRepository(client: .repositoryTest(transport)).confirm(
            workspaceId: "ws_1",
            pendingWrite: pending
        )

        XCTAssertNil(result.failureOnly, "the request was handled")
        XCTAssertEqual(result.successOnly?.executed, false, "⛔ and nothing was written")
    }

    func testAConfirmThatDoesNotAffirmSuccessIsADecodeFailure() async throws {
        let transport = RepositoryTransport(
            json: #"{"success":false,"executed":false,"tool":"update_persona","args":{}}"#
        )
        let pending = try Self.pendingWrite(from: HQBodies.richProposal)

        let result = await HQRepository(client: .repositoryTest(transport)).confirm(
            workspaceId: "ws_1",
            pendingWrite: pending
        )

        XCTAssertEqual(result.failureOnly, .decoding("HqConfirmResponse did not affirm success=true"))
    }

    /// ⚠️ A **400** HERE IS THE SERVER REFUSING A TOOL THAT IS NOT A GENUINE WRITE
    /// TOOL, which this signature cannot produce and which is precisely why the
    /// signature is shaped the way it is. It is still surfaced, because a crafted or
    /// stale proposal is a real possibility across an app update.
    func testARefusedToolAndTheUsualFailuresPassThroughOnConfirm() async throws {
        let pending = try Self.pendingWrite(from: HQBodies.richProposal)

        let refusedTool = RepositoryTransport(json: HQBodies.notConfirmable, status: 400)
        let rejected = await HQRepository(client: .repositoryTest(refusedTool)).confirm(
            workspaceId: "ws_1",
            pendingWrite: pending
        )
        XCTAssertEqual(rejected.failureOnly, .http(status: 400, message: "That action can't be confirmed."))

        let viewer = RepositoryTransport(json: HQBodies.forbidden, status: 403)
        let refused = await HQRepository(client: .repositoryTest(viewer)).confirm(
            workspaceId: "ws_1",
            pendingWrite: pending
        )
        XCTAssertEqual(refused.failureOnly?.httpStatus, 403)

        let expired = RepositoryTransport(json: HQBodies.unauthorized, status: 401)
        let unauthorized = await HQRepository(client: .repositoryTest(expired)).confirm(
            workspaceId: "ws_1",
            pendingWrite: pending
        )
        XCTAssertEqual(unauthorized.failureOnly?.isUnauthorized, true)

        let degraded = RepositoryTransport(json: HQBodies.degraded, status: 503)
        let transient = await HQRepository(client: .repositoryTest(degraded)).confirm(
            workspaceId: "ws_1",
            pendingWrite: pending
        )
        XCTAssertEqual(transient.failureOnly?.httpStatus, 503)
        XCTAssertNil(transient.successOnly)
    }

    // MARK: - Helpers

    /// ⛔ A PENDING WRITE IS OBTAINED BY DECODING A SERVER RESPONSE, NOT BY
    /// CONSTRUCTING ONE, WHICH IS THE SAME CONSTRAINT A REAL CALLER HAS. The type has
    /// only the synthesised `Codable` initialiser, so these tests reach it the way the
    /// app does: through a prompt reply.
    private static func pendingWrite(from json: String) throws -> HqPendingWrite {
        let response = try JSONDecoder().decode(HqPromptResponse.self, from: Data(json.utf8))
        return try XCTUnwrap(response.pendingWrite)
    }
}

/// Minimal, VALID District HQ bodies.
///
/// ⚠️ NOT THE CONTRACT FIXTURES. `district-hq-*.json` pins the wire shape through the
/// strict gate; what lives here is the smallest body that satisfies the Swift type,
/// so these tests can be about the two-step's guarantees rather than about JSON.
private enum HQBodies {
    static let plainAnswer = #"{"success":true,"answer":"You had 19 calls this week."}"#

    static let proposal = #"""
    {"success":true,"answer":"I've proposed a new greeting.","needsConfirmation":true,
     "pendingWrite":{"tool":"update_persona","args":{"greeting":"Good afternoon."},
                     "summary":"Update the AI receptionist persona."}}
    """#

    /// ⛔ THE MALFORMED SHAPE: the flag with nothing to confirm.
    static let flagWithoutProposal = #"""
    {"success":true,"answer":"I've proposed a new greeting.","needsConfirmation":true}
    """#

    /// ⚠️ The mirror: a proposal with no flag, which is trusted anyway.
    static let proposalWithoutFlag = #"""
    {"success":true,"answer":"I've proposed a new greeting.",
     "pendingWrite":{"tool":"update_persona","args":{"greeting":"Good afternoon."},
                     "summary":"Update the AI receptionist persona."}}
    """#

    /// ⛔ ARGUMENTS WITH A NESTED OBJECT, A MIXED ARRAY, A FRACTIONAL NUMBER AND AN
    /// EXPLICIT NULL. The confirm crosses between two JSON types whose treatment of nil
    /// differs, so this is what proves the crossing is lossless: a dropped null is a
    /// different instruction from the one the operator approved. ⚠️ `0.5` is exactly
    /// representable, so it round-trips to the same bytes on Linux and Darwin; a value
    /// like `0.1` would not be a safe thing to assert on.
    static let richProposal = #"""
    {"success":true,"answer":"Proposed.","needsConfirmation":true,
     "pendingWrite":{"tool":"update_persona",
                     "args":{"greeting":"Good afternoon.","tone":null,"temperature":0.5,
                             "voices":["Puck",1,true],"nested":{"depth":2}},
                     "summary":"Update the AI receptionist persona."}}
    """#

    static let executed = #"""
    {"success":true,"executed":true,"tool":"update_persona","args":{},
     "result":{"ok":true,"updated":["greeting"]}}
    """#

    /// ⛔ THE SUBSTITUTION: a well-formed reply naming a tool nobody approved.
    static let executedOtherTool = #"""
    {"success":true,"executed":true,"tool":"delete_contact","args":{},"result":{"ok":true}}
    """#

    static let declined = #"""
    {"success":true,"executed":false,"tool":"update_persona","args":{}}
    """#

    static let notConfirmable = #"{"success":false,"error":"That action can't be confirmed."}"#

    /// ⛔ BUILT BY CONCATENATION RATHER THAN WRAPPED INSIDE THE JSON. A raw multi-line
    /// string may break between JSON tokens, but a newline INSIDE a string value is
    /// invalid JSON, and the failure it produces reads as a bug in the repository under
    /// test rather than in the fixture.
    static let rateLimited = #"{"error":"\#(rateLimitSentence)"}"#

    static let rateLimitSentence = "Too many District HQ requests. "
        + "Please wait a moment before asking again."

    static let forbidden = #"{"success":false,"error":"Forbidden"}"#
    static let unauthorized = #"{"error":"Unauthorized"}"#
    static let degraded = #"{"success":false,"error":"Try again"}"#
}
