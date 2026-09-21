@testable import DistrictModel
import XCTest

/// A pending push, and the answers to "can it be acted on yet".
///
/// ⛔ THE HOLDER EXISTS BECAUSE THE PUSH ARRIVES **BEFORE** ANYTHING CAN
/// NAVIGATE. It is delivered on launch or from the background, at which point
/// the selected workspace is not known: it comes from
/// `GET /api/district/workspace/list` plus `GET /api/district/overview`, which
/// are in flight. So the decision is deferred rather than guessed, and this is
/// where the deferral is checked. Ported from the Android client's
/// `PushDeepLinksTest.kt`.
final class PushDeepLinkTests: XCTestCase {
    // MARK: - The holder

    func testAPendingEventIsHeldUntilItIsCleared() {
        var links = PushDeepLinks()

        XCTAssertNil(links.pending, "nothing outstanding is the normal state")
        links.offer(.message(workspaceId: "ws-1", messageId: "msg-1"))
        XCTAssertEqual(links.pending, .message(workspaceId: "ws-1", messageId: "msg-1"))

        links.clear()
        XCTAssertNil(links.pending)
    }

    func testTheLastEventOfferedWins() {
        // ⚠️ TWO NOTIFICATIONS TAPPED IN QUICK SUCCESSION ARE ONE DELIVERY EACH,
        // and the second is the one the user is looking at. There is no queue
        // because there is no sensible way to honour the first afterwards; it
        // would navigate away from the screen they just asked for.
        var links = PushDeepLinks()

        links.offer(.message(workspaceId: "ws-1", messageId: "msg-1"))
        links.offer(.incomingCall(workspaceId: "ws-2", callId: "CA1"))

        XCTAssertEqual(links.pending, .incomingCall(workspaceId: "ws-2", callId: "CA1"))
    }

    func testTheHolderCanBeSeededWithAnEventForAColdStart() {
        let links = PushDeepLinks(pending: .message(workspaceId: "ws-1", messageId: "msg-1"))

        XCTAssertEqual(
            links.decision(selectedWorkspaceId: "ws-1"),
            .openMessage(workspaceId: "ws-1", messageId: "msg-1")
        )
    }

    func testTheHolderIsEquatableSoAnObservableShellCanDiffIt() {
        XCTAssertEqual(PushDeepLinks(), PushDeepLinks())
        XCTAssertNotEqual(
            PushDeepLinks(),
            PushDeepLinks(pending: .message(workspaceId: "ws-1", messageId: "m"))
        )
    }

    // MARK: - The decision

    func testNothingPendingMeansNothingToDecide() {
        XCTAssertEqual(
            pushDeepLinkDecision(pending: nil, selectedWorkspaceId: "ws-1"),
            .wait
        )
        XCTAssertEqual(PushDeepLinks().decision(selectedWorkspaceId: "ws-1"), .wait)
    }

    func testAnUnresolvedWorkspaceMeansWaitNotDrop() {
        // ⛔ ON A COLD START FROM A NOTIFICATION THIS IS THE STATE FOR THE WHOLE
        // OF THE FIRST TWO READS. Dropping here would make the deep link work
        // only when the app was already open, which is never in the case it
        // exists for.
        XCTAssertEqual(
            pushDeepLinkDecision(
                pending: .message(workspaceId: "ws-1", messageId: "msg-1"),
                selectedWorkspaceId: nil
            ),
            .wait
        )
    }

    /// ⛔ THE MESSAGE ID TRAVELS WITH THE DECISION AND THE DECISION STAYS PURE. There
    /// is no client-side way to reach a thread without a request, which is why the id
    /// rather than a resolved thread is what comes out of here. The
    /// request is `ShellView`'s.
    func testAMessageForTheSelectedWorkspaceCarriesItsIdToTheResolver() {
        XCTAssertEqual(
            pushDeepLinkDecision(
                pending: .message(workspaceId: "ws-1", messageId: "msg-1"),
                selectedWorkspaceId: "ws-1"
            ),
            .openMessage(workspaceId: "ws-1", messageId: "msg-1")
        )
    }

    func testAMessageForADifferentWorkspaceIsDroppedRatherThanSwitchingTenants() {
        // ⛔ A DELIBERATE LIMITATION RATHER THAN A BUG. The selected workspace is
        // explicit client state the user chose; a notification silently
        // re-pointing the whole app at another tenant, mid-task, from a lock
        // screen, is a worse outcome than landing on the overview. The
        // notification did its job: it said something arrived.
        XCTAssertEqual(
            pushDeepLinkDecision(
                pending: .message(workspaceId: "ws-2", messageId: "msg-1"),
                selectedWorkspaceId: "ws-1"
            ),
            .drop
        )
    }

    func testACallRingsEvenWhileTheWorkspaceIsStillUnresolved() {
        // ⛔ THE SERVER IS HOLDING THE CALLER ON A ~25 SECOND RENDEZVOUS.
        // Waiting for two reads to resolve a workspace spends that window and
        // hands the caller to nobody, so the ring is not gated on it. Android
        // reaches the ring from `PushMessageHandler` with no workspace
        // comparison at all, for exactly this reason.
        XCTAssertEqual(
            pushDeepLinkDecision(
                pending: .incomingCall(workspaceId: "ws-1", callId: "CA1"),
                selectedWorkspaceId: nil
            ),
            .ring(workspaceId: "ws-1", callId: "CA1")
        )
    }

    func testACallForADifferentWorkspaceStillRings() {
        // ⚠️ THE ONE PLACE THE CALL FAMILY DIVERGES FROM THE MESSAGE FAMILY.
        // Dropping because the user happens to be looking at another tenant
        // would silence a live inbound call on a multi-tenant account, which is
        // most calls. The ring names its own workspace and the shell switches to
        // it as part of showing the call.
        XCTAssertEqual(
            pushDeepLinkDecision(
                pending: .incomingCall(workspaceId: "ws-2", callId: "CA1"),
                selectedWorkspaceId: "ws-1"
            ),
            .ring(workspaceId: "ws-2", callId: "CA1")
        )
    }

    func testACallForTheSelectedWorkspaceRings() {
        XCTAssertEqual(
            pushDeepLinkDecision(
                pending: .incomingCall(workspaceId: "ws-1", callId: "CA1"),
                selectedWorkspaceId: "ws-1"
            ),
            .ring(workspaceId: "ws-1", callId: "CA1")
        )
    }

    // MARK: - Consuming the pending event

    func testEveryDecisionButWaitConsumesThePendingEvent() {
        // ⛔ INCLUDING THE ONE THAT NAVIGATES NOWHERE. A dropped link that
        // survived would re-fire the moment the user switched to that workspace
        // for their own reasons, minutes later, and yank them into the inbox.
        XCTAssertFalse(PushDeepLinkDecision.wait.consumesPending)
        XCTAssertTrue(PushDeepLinkDecision.drop.consumesPending)
        XCTAssertTrue(PushDeepLinkDecision.openMessage(workspaceId: "ws-1", messageId: "m").consumesPending)
        XCTAssertTrue(PushDeepLinkDecision.ring(workspaceId: "ws-1", callId: "CA1").consumesPending)
    }

    func testADecisionIsEquatableDownToItsIds() {
        XCTAssertNotEqual(
            PushDeepLinkDecision.openMessage(workspaceId: "ws-1", messageId: "m"),
            .openMessage(workspaceId: "ws-2", messageId: "m")
        )
        // ⚠️ AND DOWN TO THE MESSAGE ID, which is the half that arrived with the
        // resolver: two pushes for the same workspace name different conversations, and
        // an equality that ignored the id would let the shell treat the second tap as a
        // repeat of the first and resolve the wrong thread.
        XCTAssertNotEqual(
            PushDeepLinkDecision.openMessage(workspaceId: "ws-1", messageId: "m1"),
            .openMessage(workspaceId: "ws-1", messageId: "m2")
        )
        XCTAssertNotEqual(
            PushDeepLinkDecision.ring(workspaceId: "ws-1", callId: "CA1"),
            .ring(workspaceId: "ws-1", callId: "CA2")
        )
    }
}
