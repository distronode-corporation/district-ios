import CallKit
@testable import DistrictAI
@testable import DistrictCall
import UIKit
import XCTest

/// The `call_ring_cancelled` background push (3.0.1): what it parses to, which ring it
/// may stop, what CallKit is told, and which alert it removes.
///
/// ⛔ THE ONE RULE WORTH A TEST ABOVE ALL: the cancel reaches the device that ANSWERED
/// too, so a call answered or being answered here must come out ``RingCancelOutcome/answeredHere``,
/// never ``RingCancelOutcome/endRing(_:)``. Getting that wrong hangs up the person who
/// picked up.
final class RingCancelTests: XCTestCase {
    private static func payload(
        type: String = "call_ring_cancelled",
        callId: String = "call_1",
        reason: String? = "answered"
    ) -> [String: String] {
        var data = ["type": type, "workspaceId": "ws_1", "callId": callId]
        data["reason"] = reason
        return data
    }

    private static let cancel = RingCancel(workspaceId: "ws_1", callId: "call_1", reason: .answered)

    // MARK: - Parse

    /// The server's shape: the keys at the top level beside `aps` (`buildBackgroundRequest`).
    func testTheServersBackgroundPushParses() {
        let userInfo: [AnyHashable: Any] = [
            "type": "call_ring_cancelled",
            "workspaceId": "ws_1",
            "callId": "call_1",
            "reason": "timeout",
            "aps": ["content-available": 1],
        ]
        XCTAssertEqual(
            RingCancel.parse(userInfo: userInfo),
            RingCancel(workspaceId: "ws_1", callId: "call_1", reason: .timeout)
        )
    }

    func testEveryReasonTheServerSendsIsRead() {
        let expected: [String: RingCancelReason] = [
            "answered": .answered,
            "timeout": .timeout,
            "call_ended": .callEnded,
            "withdrawn": .withdrawn,
        ]
        for (wire, reason) in expected {
            XCTAssertEqual(RingCancel.parse(Self.payload(reason: wire))?.reason, reason, wire)
        }
    }

    /// ⛔ AN UNKNOWN OR MISSING REASON STILL STOPS THE RING, read as `withdrawn`.
    func testAnUnknownOrMissingReasonIsWithdrawnNotDropped() {
        for wire in ["picked_up", "ANSWERED", "", "   ", nil] as [String?] {
            XCTAssertEqual(
                RingCancel.parse(Self.payload(reason: wire))?.reason, .withdrawn,
                "reason \(String(describing: wire)) must still cancel"
            )
        }
    }

    func testValuesAreTrimmed() {
        let data = [
            "type": " call_ring_cancelled\n",
            "workspaceId": " ws_1 ",
            "callId": "\tcall_1 ",
            "reason": " call_ended ",
        ]
        XCTAssertEqual(
            RingCancel.parse(data),
            RingCancel(workspaceId: "ws_1", callId: "call_1", reason: .callEnded)
        )
    }

    /// ⛔ ANOTHER TYPE IS NOT A CANCEL. `incoming_call` above all: reading a ring as its own
    /// cancel would stop every ring the moment it started.
    func testAnyOtherTypeIsNotACancel() {
        for type in ["incoming_call", "message", "call_ring_cancelled_v2", "CALL_RING_CANCELLED", ""] {
            XCTAssertNil(RingCancel.parse(Self.payload(type: type)), type)
        }
        var untyped = Self.payload()
        untyped["type"] = nil
        XCTAssertNil(RingCancel.parse(untyped))
    }

    func testAMissingOrBlankIdIsADrop() {
        XCTAssertNil(RingCancel.parse(Self.payload(callId: "")))
        XCTAssertNil(RingCancel.parse(Self.payload(callId: "  ")))
        var noCall = Self.payload()
        noCall["callId"] = nil
        XCTAssertNil(RingCancel.parse(noCall))
        var noWorkspace = Self.payload()
        noWorkspace["workspaceId"] = nil
        XCTAssertNil(RingCancel.parse(noWorkspace))
    }

    /// ⚠️ A NON-STRING VALUE IS DROPPED, NOT COERCED: `1` is not `"1"`.
    func testANonStringIdIsDropped() {
        let userInfo: [AnyHashable: Any] = [
            "type": "call_ring_cancelled",
            "workspaceId": "ws_1",
            "callId": 1,
            "reason": "answered",
        ]
        XCTAssertNil(RingCancel.parse(userInfo: userInfo))
    }

    // MARK: - What CallKit is told

    func testTheReasonMapsToCallKit() {
        XCTAssertEqual(RingCancelReason.answered.endedReason, .answeredElsewhere)
        XCTAssertEqual(RingCancelReason.callEnded.endedReason, .remoteEnded)
        XCTAssertEqual(RingCancelReason.timeout.endedReason, .unanswered)
        XCTAssertEqual(RingCancelReason.withdrawn.endedReason, .unanswered)
    }

    // MARK: - Which ring it stops

    func testARingForThatCallEndsWithTheMappedReason() {
        for reason: RingCancelReason in [.answered, .timeout, .callEnded, .withdrawn] {
            let cancel = RingCancel(workspaceId: "ws_1", callId: "call_1", reason: reason)
            XCTAssertEqual(
                cancel.outcome(phase: .ringing, ringingCallId: "call_1"),
                .endRing(reason.endedReason)
            )
        }
    }

    /// ⛔ THE DEVICE THAT ANSWERED GETS THE CANCEL TOO, AND IT MUST CHANGE NOTHING.
    func testACallAnsweredOrBeingAnsweredHereIsNotTouched() {
        XCTAssertEqual(Self.cancel.outcome(phase: .answering, ringingCallId: "call_1"), .answeredHere)
        XCTAssertEqual(Self.cancel.outcome(phase: .inCall, ringingCallId: "call_1"), .answeredHere)
    }

    /// ⛔ MATCHED ON `callId` ONLY: another call's ring is never stopped, whatever its phase.
    func testARingForAnotherCallIsNotStopped() {
        for phase: IncomingCallPhase in [.ringing, .answering, .inCall, .ended(.declined)] {
            XCTAssertEqual(Self.cancel.outcome(phase: phase, ringingCallId: "call_2"), .notRingingHere)
        }
    }

    func testNothingRingingHereIsNotRingingHere() {
        XCTAssertEqual(Self.cancel.outcome(phase: .idle, ringingCallId: nil), .notRingingHere)
        for reason: CallEndReason in [.declined, .ringTimedOut, .hungUpLocally, .remoteHungUp] {
            XCTAssertEqual(Self.cancel.outcome(phase: .ended(reason), ringingCallId: "call_1"), .notRingingHere)
        }
    }

    // MARK: - Which alert it removes

    func testOnlyThatCallsIncomingCallAlertIsRemoved() {
        let delivered: [(identifier: String, payload: [String: String])] = [
            ("ring-1", ["type": "incoming_call", "workspaceId": "ws_1", "callId": "call_1"]),
            ("ring-1-again", ["type": "incoming_call", "workspaceId": "ws_1", "callId": " call_1 "]),
            ("ring-2", ["type": "incoming_call", "workspaceId": "ws_1", "callId": "call_2"]),
            ("message", ["type": "message", "workspaceId": "ws_1", "messageId": "m_1", "callId": "call_1"]),
            ("untyped", ["callId": "call_1"]),
        ]
        XCTAssertEqual(Self.cancel.alertIdentifiers(in: delivered), ["ring-1", "ring-1-again"])
        XCTAssertEqual(Self.cancel.alertIdentifiers(in: []), [])
    }
}

/// The two ends that hold state: the model and the delegate.
@MainActor
final class RingCancelDeliveryTests: XCTestCase {
    /// A model with no call holds nothing to stop, and stays as it was.
    func testAnIdleModelIsNotRingingAndIsLeftAlone() async {
        let model = IncomingCallModel(container: AppContainer())
        let cancel = RingCancel(workspaceId: "ws_1", callId: "call_1", reason: .answered)
        let outcome = await model.ringCancelled(cancel)
        XCTAssertEqual(outcome, .notRingingHere)
        XCTAssertEqual(model.state.phase, .idle)
    }

    /// ⛔ THE COMPLETION HANDLER IS CALLED EXACTLY ONCE, with no registrar and no model:
    /// a cancel cannot wait for a sign-in.
    func testACancelCompletesOnceWithNoRegistrar() async {
        let delegate = AppDelegate()
        let done = expectation(description: "completion")
        done.assertForOverFulfill = true
        var results: [UIBackgroundFetchResult] = []
        delegate.application(
            UIApplication.shared,
            didReceiveRemoteNotification: [
                "type": "call_ring_cancelled",
                "workspaceId": "ws_1",
                "callId": "call_none_delivered",
                "reason": "answered",
                "aps": ["content-available": 1],
            ],
            fetchCompletionHandler: { result in
                results.append(result)
                done.fulfill()
            }
        )
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(results, [.noData])
    }

    /// ⚠️ 3.0.0'S PATH FOR EVERY OTHER PUSH IS UNCHANGED: signed out, it is `.noData` at once.
    func testAnyOtherPushKeepsTheBadgePath() {
        let delegate = AppDelegate()
        var results: [UIBackgroundFetchResult] = []
        delegate.application(
            UIApplication.shared,
            didReceiveRemoteNotification: ["type": "message", "workspaceId": "ws_1", "messageId": "m_1"],
            fetchCompletionHandler: { results.append($0) }
        )
        XCTAssertEqual(results, [.noData])
    }
}
