@testable import DistrictCall
import XCTest

/// The typed ids and the participant value type.
final class CallIdsTests: XCTestCase {
    func testAWorkspaceIdCarriesItsStringVerbatim() {
        let workspace = WorkspaceID("ws-1")
        XCTAssertEqual("ws-1", workspace.rawValue)
        XCTAssertEqual("ws-1", workspace.description)
    }

    func testACallIdCarriesItsStringVerbatim() {
        let call = CallID("CA1")
        XCTAssertEqual("CA1", call.rawValue)
        XCTAssertEqual("CA1", call.description)
    }

    func testTheTwoIdsAreDistinctTypesWithIndependentEquality() {
        // ⛔ THE WHOLE POINT: `POST /calls/{callId}/answer?workspaceId=` takes one
        // of each, adjacent, and a swap is well-formed on the wire. Here it does
        // not compile, and equality never crosses the two types.
        XCTAssertEqual(WorkspaceID("same"), WorkspaceID("same"))
        XCTAssertNotEqual(CallID("CA1"), CallID("CA2"))
        XCTAssertEqual(Set([WorkspaceID("a"), WorkspaceID("a")]).count, 1)
    }
}

final class CallParticipantTests: XCTestCase {
    func testAParticipantDefaultsToAnonymousAndHuman() {
        let person = CallParticipant(identity: "user-abc")
        XCTAssertEqual("user-abc", person.identity)
        XCTAssertNil(person.name)
        XCTAssertFalse(person.isAgent)
    }

    func testTheAgentFlagIsReportedRatherThanInferredFromTheIdentity() {
        // ⛔ The transcription companion's default identity is `agent-<jobId>`,
        // but the identity prefix is a fallback the web keeps for a retired
        // browser-side participant, not the primary test. A participant whose
        // identity begins "agent-" is still not an agent unless the SDK said so.
        let looksLikeAnAgent = CallParticipant(identity: "agent-42")
        XCTAssertFalse(looksLikeAnAgent.isAgent)

        let realAgent = CallParticipant(identity: "user-abc", name: "Companion", isAgent: true)
        XCTAssertTrue(realAgent.isAgent)
        XCTAssertEqual("Companion", realAgent.name)
    }
}

final class CallEndReasonTests: XCTestCase {
    func testAnswerRejectionsMapToTheirEndReasons() {
        XCTAssertEqual(CallEndReason.callerCancelled, IncomingAnswerRejection.callerGone.endReason)
        XCTAssertEqual(
            CallEndReason.answerRefused(message: "Forbidden"),
            IncomingAnswerRejection.refused(message: "Forbidden").endReason
        )
    }

    func testAFailureAndARemoteEndAreNotTheSameReason() {
        // ⚠️ Both arrive as an ended call, and the Kotlin client models them as
        // two different phases. Conflating them here would tell an operator their
        // network broke when the callee simply hung up.
        XCTAssertNotEqual(CallEndReason.failed(message: nil), CallEndReason.remoteEnded(reason: nil))
        XCTAssertNotEqual(CallEndReason.declined, CallEndReason.ringTimedOut)
    }
}
