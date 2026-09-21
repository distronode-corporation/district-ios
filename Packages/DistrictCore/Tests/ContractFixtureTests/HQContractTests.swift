import ContractGateSupport
import DistrictModel
import Foundation
import XCTest

/// Per-fixture assertions for District HQ: an answer, a proposal, and an applied
/// write.
///
/// ⛔ THE STRICT GATE CANNOT SEE THE FACT THESE THREE FIXTURES EXIST FOR. One route
/// answers all three, branching on the presence of a `confirm` key in the REQUEST,
/// and the gate compares each body against a DTO rather than against its siblings.
/// So nothing in it would notice a DTO that required `pendingWrite` and threw on
/// every plain answer, or one that made it non-Optional and therefore never offered
/// a confirm prompt. Both directions are asserted here, on the raw bytes where the
/// claim is about an ABSENT key.
final class HQContractTests: XCTestCase {
    // MARK: - A plain answer

    /// ⛔ TWO KEYS AND NOTHING ELSE. The confirmation pair is ABSENT rather than
    /// null on this branch, which is what makes both Optional on the DTO and what a
    /// strict decoder has to survive. ⚠️ Asserted on the raw bytes because absent and
    /// null both decode to nil, so no assertion on the decoded value could tell the
    /// two apart.
    func testAPlainAnswerCarriesNoConfirmationKeysAtAll() throws {
        let response = try StrictDecodeVerifier.verify(
            fixture: "district-hq-answer.json",
            as: HqPromptResponse.self
        )

        XCTAssertTrue(response.success)
        XCTAssertEqual(response.answer, "You had **19 calls** this week, and 3 of them were missed.")
        XCTAssertNil(response.needsConfirmation)
        XCTAssertNil(response.pendingWrite)

        let raw = try Self.envelope(of: "district-hq-answer.json")
        XCTAssertEqual(Set(raw.keys), ["success", "answer"])
        XCTAssertFalse(raw.keys.contains("needsConfirmation"), "⛔ absent, not false")
        XCTAssertFalse(raw.keys.contains("pendingWrite"), "⛔ absent, not null")
    }

    // MARK: - A proposal

    /// ⛔ `needsConfirmation` TRUE MEANS NOTHING HAS BEEN WRITTEN. The model may only
    /// propose; the server gates every write behind an explicit second call. The
    /// answer text says so in prose here, which is exactly why the AFFORDANCE has to
    /// come from the field: a screen that looked for the phrasing would miss the
    /// confirm button the first time the model worded it differently, and the
    /// operator would read the prose as a report that it was done.
    ///
    /// ⛔ AND THE SUMMARY IS THE ONLY DESCRIPTION THE OPERATOR EVER READS. It is
    /// composed server-side from the real arguments, so it is asserted rather than
    /// left to the byte comparison: a regression that returned the tool name would
    /// ask somebody to approve "update_persona".
    func testAProposalCarriesTheFlagTheToolAndTheOperatorFacingSummary() throws {
        let response = try StrictDecodeVerifier.verify(
            fixture: "district-hq-pending-write.json",
            as: HqPromptResponse.self
        )

        XCTAssertTrue(response.success)
        XCTAssertEqual(response.needsConfirmation, true)
        let pending = try XCTUnwrap(response.pendingWrite)
        XCTAssertEqual(pending.tool, "update_persona")
        XCTAssertTrue(
            pending.summary.contains("Update the AI receptionist persona"),
            "the summary describes the change, not the tool"
        )
        XCTAssertTrue(pending.summary.contains("Good afternoon"))
    }

    /// ⛔ THE ARGUMENTS ARE CARRIED AS AN OPAQUE BLOB AND ARE ECHOED BACK VERBATIM.
    /// They are whatever the MODEL chose, so their shape depends on which of the write
    /// tools it picked; typing them would mean a struct per tool and a decode failure
    /// on an installed build the day a tool gains a field. ⚠️ This asserts the ONE key
    /// the fixture happens to carry through the opaque accessor, which is the only way
    /// a client should ever look inside: defensively, at the point of display, never
    /// to rebuild the object.
    func testTheProposedArgumentsRoundTripAsAnOpaqueBlob() throws {
        let response = try StrictDecodeVerifier.verify(
            fixture: "district-hq-pending-write.json",
            as: HqPromptResponse.self
        )
        let pending = try XCTUnwrap(response.pendingWrite)

        XCTAssertEqual(
            pending.args["greeting"]?.stringValue,
            "Good afternoon, thanks for calling Analytical Engines."
        )
        XCTAssertEqual(pending.args.objectValue?.count, 1, "one argument, carried whole")
    }

    // MARK: - A confirmed write

    /// ⛔ `success` AND `executed` ARE DIFFERENT QUESTIONS, AND THIS FIXTURE IS THE
    /// ONE WHERE BOTH ARE TRUE. The route derives `executed` from the tool's own `ok`,
    /// so a viewer's confirm or a tool that refused internally answers
    /// `success: true, executed: false`, a shape no fixture carries, which is why the
    /// pair is asserted here and the negative branch is decoded from literal bytes
    /// below.
    ///
    /// ⛔ `tool` AND `args` ARE ECHOED SO THE APPLIED ACTION CAN BE PROVED TO BE THE
    /// APPROVED ONE. `HQRepository` compares the tool rather than trusting it, and
    /// this is the fixture that shows the server really does send it back.
    func testAConfirmedWriteEchoesTheToolAndReportsItExecuted() throws {
        let response = try StrictDecodeVerifier.verify(
            fixture: "district-hq-confirm.json",
            as: HqConfirmResponse.self
        )

        XCTAssertTrue(response.success)
        XCTAssertTrue(response.executed, "the write took effect")
        XCTAssertEqual(response.tool, "update_persona")
        XCTAssertEqual(
            response.args["greeting"]?.stringValue,
            "Good afternoon, thanks for calling Analytical Engines."
        )
    }

    /// ⚠️ `result` IS THE TOOL'S OWN RETURN VALUE AND IS CARRIED FOR DIAGNOSTICS
    /// ONLY. Nothing in the route constrains its shape, so it is opaque here.
    /// ⛔ A client must decide "applied" from `executed` and never by inspecting this:
    /// the server has already done the inspecting, and the shape varies per tool.
    func testTheToolsOwnResultIsCarriedOpaquelyAndNotInterpreted() throws {
        let response = try StrictDecodeVerifier.verify(
            fixture: "district-hq-confirm.json",
            as: HqConfirmResponse.self
        )
        let result = try XCTUnwrap(response.result)

        XCTAssertEqual(result["ok"], .bool(true))
        XCTAssertEqual(result["updated"]?.arrayValue, [.string("greeting")])
    }

    /// ⛔ THE DECLINED WRITE, DECODED FROM LITERAL BYTES BECAUSE NO FIXTURE CARRIES
    /// IT. `success: true, executed: false` is what a viewer's confirm answers, or a
    /// tool that refused internally: the request was handled and nothing changed.
    /// Reporting it as applied is the lie the pair exists to prevent, and reporting it
    /// as an error is the other wrong answer, because nothing went wrong.
    ///
    /// ⚠️ `result` ABSENT IS LEGITIMATE on that branch, and a required field there
    /// would turn a handled refusal into a decode failure.
    func testADeclinedWriteIsASuccessfulResponseReportingNotExecuted() throws {
        let response = try Self.decode(
            HqConfirmResponse.self,
            from: #"{"success":true,"executed":false,"tool":"delete_contact","args":{"id":"c_1"}}"#
        )

        XCTAssertTrue(response.success, "the request was handled")
        XCTAssertFalse(response.executed, "⛔ and nothing was written")
        XCTAssertNil(response.result)
    }

    // MARK: - Helpers

    private static func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private static func envelope(of fixture: String) throws -> [String: Any] {
        let raw = try ContractFixtures.read(fixture)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any], fixture)
    }
}
