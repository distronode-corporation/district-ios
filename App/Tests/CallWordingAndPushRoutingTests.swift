import CallKit
@testable import DistrictAI
import DistrictCall
import DistrictL10n
import DistrictModel
import XCTest

/// Where a tapped push lands, the incoming call's caller line, and the dialer's refusals and what
/// it tells the OS when an outbound call ends.
@MainActor
final class CallWordingAndPushRoutingTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        L10nRuntime.locale = .en
    }

    // MARK: - A tapped push

    /// Waiting for the workspace and dropping another workspace's message are both no move.
    func testNoDecisionIsNoMove() {
        XCTAssertNil(PushRouting.action(for: .wait, selectedWorkspaceId: "ws_1"))
        XCTAssertNil(PushRouting.action(for: .drop, selectedWorkspaceId: "ws_1"))
    }

    /// A message opens the inbox of the workspace already selected: no switch, no route yet.
    func testAMessageOpensTheInbox() {
        let action = PushRouting.action(
            for: .openMessage(workspaceId: "ws_1", messageId: "msg_1"),
            selectedWorkspaceId: "ws_1"
        )
        XCTAssertEqual(action, PushRouteAction(tab: .inbox, selectWorkspaceId: nil))
    }

    /// ⛔ A RING SHOWS THE CALL LOG, NEVER ANSWERS, and switches only when it is another workspace's.
    func testARingOpensTheCallLogAndSwitchesOnlyWhenItMust() {
        XCTAssertEqual(
            PushRouting.action(for: .ring(workspaceId: "ws_1", callId: "call_1"), selectedWorkspaceId: "ws_1"),
            PushRouteAction(tab: .calls, selectWorkspaceId: nil)
        )
        XCTAssertEqual(
            PushRouting.action(for: .ring(workspaceId: "ws_2", callId: "call_1"), selectedWorkspaceId: "ws_1"),
            PushRouteAction(tab: .calls, selectWorkspaceId: "ws_2")
        )
        XCTAssertEqual(
            PushRouting.action(for: .ring(workspaceId: "ws_2", callId: "call_1"), selectedWorkspaceId: nil),
            PushRouteAction(tab: .calls, selectWorkspaceId: "ws_2"),
            "a ring before any workspace is known still names its own"
        )
    }

    /// The core's decision and this routing together: a message for another workspace goes nowhere.
    func testAMessageForAnotherWorkspaceIsDroppedEndToEnd() {
        var links = PushDeepLinks()
        links.offer(.message(workspaceId: "ws_2", messageId: "msg_1"))
        XCTAssertNil(PushRouting.action(for: links.decision(selectedWorkspaceId: "ws_1"), selectedWorkspaceId: "ws_1"))
        XCTAssertNil(PushRouting.action(for: links.decision(selectedWorkspaceId: nil), selectedWorkspaceId: nil))
    }

    // MARK: - The incoming caller line

    func testTheCallerLine() {
        XCTAssertEqual(IncomingCallCopy.callerLine(caller: nil, workspaceName: nil), IncomingCallCopy.incomingCall)
        XCTAssertEqual(IncomingCallCopy.callerLine(caller: "   ", workspaceName: "  "), IncomingCallCopy.incomingCall)
        XCTAssertEqual(IncomingCallCopy.callerLine(caller: " Ada ", workspaceName: nil), "Ada")
        XCTAssertEqual(
            IncomingCallCopy.callerLine(caller: "Ada", workspaceName: "Bravo Client"),
            IncomingCallCopy.callerLineWithWorkspace("Ada", "Bravo Client")
        )
        XCTAssertEqual(
            IncomingCallCopy.callerLine(caller: "", workspaceName: "Bravo Client"),
            IncomingCallCopy.callerLineWithWorkspace(IncomingCallCopy.incomingCall, "Bravo Client"),
            "an unknown caller is still said to be calling that workspace"
        )
    }

    // MARK: - The dialer

    /// The server's refusal when it said something, trimmed; the app's sentence when it said nothing.
    func testARefusalPrefersTheServersSentence() {
        XCTAssertEqual(DialerModel.refusalText(" Not allowed. \n", fallback: "fallback").message, "Not allowed.")
        XCTAssertEqual(DialerModel.refusalText("  \n\t", fallback: "fallback").message, "fallback")
        XCTAssertEqual(DialerModel.refusalText(nil, fallback: "fallback").message, "fallback")
        XCTAssertEqual(DialerModel.refusalText("x", fallback: "fallback").action, .none)
    }

    /// The four refusals before a dial offer nothing to press, and each says something different.
    func testTheDialersOwnRefusals() {
        let refusals = [DialerModel.busy, DialerModel.notStarted, DialerModel.microphoneOff, DialerModel.inRoom]
        XCTAssertEqual(refusals.map(\.action), [.none, .none, .none, .none])
        XCTAssertEqual(Set(refusals.map(\.message)).count, 4)
    }

    func testTheEntryHintNamesTheCountry() {
        XCTAssertEqual(DialerModel.entryHint(country: nil), DialerModel.entryHintNone)
        XCTAssertEqual(DialerModel.entryHint(country: "CA"), DialerModel.entryHintLocal(DialPlan.name("CA")))
    }

    /// What the OS is told when an outbound call ends: the far end, or a failure.
    func testWhatTheSystemIsToldWhenAnOutboundCallEnds() {
        XCTAssertEqual(DialerModel.endedReason(for: .ended(.remoteHungUp)), .remoteEnded)
        XCTAssertEqual(DialerModel.endedReason(for: .ended(.remoteEnded(reason: "Room deleted"))), .remoteEnded)
        XCTAssertEqual(DialerModel.endedReason(for: .ended(.failed(message: nil))), .failed)
        XCTAssertEqual(DialerModel.endedReason(for: .ended(.hungUpLocally)), .remoteEnded)
        XCTAssertEqual(DialerModel.endedReason(for: .ended(.declined)), .remoteEnded)
        XCTAssertEqual(DialerModel.endedReason(for: .connected), .failed, "a call not ended is never reported as one")
        XCTAssertEqual(DialerModel.endedReason(for: .idle), .failed)
    }
}
