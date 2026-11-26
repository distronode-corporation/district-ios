@testable import DistrictAIWatch
import Foundation
import XCTest

/// ``WatchStore``'s branches the first file leaves: a tap while its write is on its way, a
/// cold start, a version change mid-route, a newer tap or a closed window replacing a route,
/// and the switch's silent success.
@MainActor
final class WatchStoreBranchTests: XCTestCase {
    override func tearDown() {
        WatchL10n.phoneLanguage = nil
        super.tearDown()
    }

    private var snapshot: WatchSnapshot {
        WatchStoreTests.snapshot()
    }

    private var firstConversation: WatchSnapshot.Conversation {
        get throws { try XCTUnwrap(snapshot.conversations?.first) }
    }

    // MARK: - Writes

    /// ⛔ ONE REQUEST PER TAP: a second tap while the first is sending is dropped, so one reply
    /// is one message to the customer.
    func testASecondTapWhileTheFirstIsSendingIsDropped() async throws {
        let rig = BranchRig()
        let conversation = try firstConversation
        rig.store.apply(.snapshot(snapshot))
        let seen = BranchProbe<WatchWriteState?>()
        rig.link.onSend = { [store = rig.store] _ in
            seen.values.append(store.writes[WriteKey.reply(conversation.id)])
            await store.reply("Second tap", to: conversation)
        }

        await rig.store.reply("First tap", to: conversation)

        XCTAssertEqual(seen.values, [.sending])
        XCTAssertEqual(rig.link.sent, [.reply(workspaceId: "ws_1", threadKey: "contact:c_1", text: "First tap")])
        XCTAssertEqual(rig.store.writes[WriteKey.reply(conversation.id)], .succeeded(WatchCopy.replySent))
    }

    /// ⚠️ THE SWITCH SAYS NOTHING ON SUCCESS: its own position is the answer, so no state is kept.
    func testASuccessfulAvailabilitySwitchLeavesNoLine() async {
        let rig = BranchRig()
        rig.store.apply(.snapshot(snapshot))

        await rig.store.setAvailable(false)

        XCTAssertEqual(rig.link.sent, [.setAvailability(workspaceId: "ws_1", available: false)])
        XCTAssertNil(rig.store.writes[WriteKey.availability])
    }

    func testMarkReadSaysMarked() async throws {
        let rig = BranchRig()
        rig.store.apply(.snapshot(snapshot))

        try await rig.store.markRead(firstConversation)

        XCTAssertEqual(rig.link.sent, [.markRead(workspaceId: "ws_1", threadKey: "contact:c_1")])
        XCTAssertEqual(rig.store.writes[WriteKey.markRead("contact:c_1")], .succeeded(WatchCopy.markedRead))
    }

    /// ⛔ A REFUSAL WITH NO SENTENCE STILL READS AS A FAILURE, never as sent.
    func testARefusalWithoutASentenceIsDidNotAnswer() async throws {
        let silent = WatchReply(protocolVersion: WatchSnapshot.currentProtocolVersion, ok: false, error: nil)
        let rig = BranchRig(answers: [.reply(silent)])
        rig.store.apply(.snapshot(snapshot))

        try await rig.store.reply("On my way.", to: firstConversation)

        XCTAssertEqual(
            rig.store.writes[WriteKey.reply("contact:c_1")],
            .failed(title: WatchCopy.replyNotSent, reason: WatchCopy.iphoneDidNotAnswer)
        )
    }

    /// ⛔ NO CHANNEL TO ANSWER ON, NO REPLY: nothing is sent and no state appears.
    func testAConversationThatCannotBeAnsweredSendsNothing() async throws {
        let rig = BranchRig()
        rig.store.apply(.snapshot(snapshot))
        var closed = try firstConversation
        closed.canReply = false

        await rig.store.reply("Hello", to: closed)

        XCTAssertTrue(rig.link.sent.isEmpty)
        XCTAssertTrue(rig.store.writes.isEmpty)
    }

    /// ⚠️ NOTHING TO SWITCH: availability the phone could not read, or nobody signed in.
    func testAvailabilityUnknownOrSignedOutSendsNothing() async {
        let rig = BranchRig()
        await rig.store.setAvailable(true)
        var unknown = snapshot
        unknown.availability = nil
        rig.store.apply(.snapshot(unknown))
        await rig.store.setAvailable(true)

        XCTAssertTrue(rig.link.sent.isEmpty)
        XCTAssertTrue(rig.store.writes.isEmpty)
    }

    func testDismissingAWriteForgetsOnlyThatOne() async throws {
        let rig = BranchRig(reachable: false)
        rig.store.apply(.snapshot(snapshot))
        try await rig.store.reply("Hello", to: firstConversation)
        await rig.store.setAvailable(false)

        rig.store.dismissWrite(WriteKey.reply("contact:c_1"))

        XCTAssertEqual(rig.store.writes, [WriteKey.availability: .unreachable])
    }

    // MARK: - Start and refresh

    /// A cold start shows what was kept WITHOUT writing it back, listens, asks once, and keeps
    /// what the phone then sends.
    func testAColdStartShowsTheKeptSnapshotThenListensAndAsks() async throws {
        let rig = BranchRig()
        rig.persistence.saved = try [snapshot.encoded()]

        rig.store.start()

        XCTAssertEqual(rig.store.snapshot, snapshot)
        XCTAssertEqual(rig.persistence.saved.count, 1, "the kept snapshot is not saved again")
        XCTAssertEqual(rig.link.activations, 1)
        await branchWait { rig.link.sent == [.refresh] }

        var fresh = snapshot
        fresh.unreadCount = 5
        rig.link.onReading?(.snapshot(fresh))

        XCTAssertEqual(rig.store.snapshot?.unreadCount, 5)
        XCTAssertEqual(rig.persistence.saved.count, 2)
        XCTAssertEqual(rig.complication.published.last?.unreadCount, 5)
    }

    /// ⚠️ BYTES THAT ARE NOT A SNAPSHOT ARE NOT AN ACCOUNT: still waiting, and an unreachable
    /// phone is not asked.
    func testAColdStartFromUnreadableBytesKeepsWaiting() {
        let rig = BranchRig(reachable: false)
        rig.persistence.saved = [Data("not a snapshot".utf8)]

        rig.store.start()

        XCTAssertEqual(rig.store.phase, .waiting)
        XCTAssertTrue(rig.complication.published.isEmpty)
        XCTAssertTrue(rig.link.sent.isEmpty)
    }

    func testRefreshAsksOnlyAPhoneInReach() async {
        let away = BranchRig(reachable: false)
        away.store.refresh()
        let near = BranchRig()
        near.store.refresh()

        await branchWait { near.link.sent == [.refresh] }
        XCTAssertTrue(away.link.sent.isEmpty)
    }

    // MARK: - Times

    /// The call's own time against the watch's clock when the phone sent one, otherwise the
    /// phone's relative sentence as written.
    func testACallsTimeIsReReadAgainstTheWatchsClock() {
        let rig = BranchRig()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let occurred = now.addingTimeInterval(-2 * 3600)
        var call = WatchSnapshot.Call(
            id: "call_1", caller: "Marie Tremblay", direction: "Inbound", time: "Oct 24, 9:00",
            relativeTime: "5 min ago", occurredAt: nil, outcome: "Completed", duration: "2:10"
        )

        XCTAssertEqual(rig.store.relativeTime(of: call, at: now), "5 min ago")
        call.occurredAt = occurred
        XCTAssertEqual(rig.store.relativeTime(of: call, at: now), WatchL10n.relative(occurred, to: now))
        XCTAssertNotEqual(rig.store.relativeTime(of: call, at: now), "5 min ago")
    }

    func testNoSnapshotHasNoStaleBanner() {
        let rig = BranchRig()
        XCTAssertNil(rig.store.staleBanner(at: Date.distantFuture))
        rig.store.apply(.snapshot(.signedOut(at: Date(timeIntervalSince1970: 0), language: "en")))
        XCTAssertNil(rig.store.staleBanner(at: Date.distantFuture))
    }

    // MARK: - A version change

    /// ⛔ ANOTHER VERSION FORGETS THE PATH, THE PENDING ROUTE AND THE PHONE'S LANGUAGE, so the
    /// next snapshot of this version opens nothing the old one was asked for.
    func testAVersionMismatchForgetsThePathTheRouteAndTheLanguage() async {
        let rig = BranchRig(reachable: false, answers: [.reply(.thread("contact:c_1"))])
        var french = snapshot
        french.language = "fr-CA"
        rig.store.apply(.snapshot(french))
        XCTAssertEqual(WatchL10n.phoneLanguage, "fr-CA")
        await rig.store.open(WatchStoreTests.tap())
        XCTAssertEqual(rig.store.path, [.inbox])

        rig.store.apply(.versionMismatch(2))

        XCTAssertEqual(rig.store.path, [])
        XCTAssertNil(WatchL10n.phoneLanguage)
        XCTAssertNil(rig.store.snapshot)
        rig.link.isReachable = true
        rig.store.apply(.snapshot(snapshot))
        await rig.store.settleRoute()
        XCTAssertTrue(rig.link.sent.isEmpty)
        XCTAssertEqual(rig.store.path, [])
    }

    // MARK: - Routes

    /// ⛔ A TAPPED CALL REPLACES A MESSAGE STILL ON ITS WAY: the phone coming back does not pull
    /// the person from the card into a thread.
    func testACallTapReplacesAPendingMessageRoute() async {
        let rig = BranchRig(reachable: false, answers: [.reply(.thread("contact:c_1"))])
        rig.store.apply(.snapshot(snapshot))
        await rig.store.open(WatchStoreTests.tap())

        await rig.store.open(["type": "incoming_call", "workspaceId": "ws_1", "callId": "call_7"])
        rig.link.isReachable = true
        rig.store.apply(.snapshot(snapshot))
        await rig.store.settleRoute()

        XCTAssertEqual(rig.store.path, [.calls, .callCard(workspaceId: "ws_1", callId: "call_7")])
        XCTAssertTrue(rig.link.sent.isEmpty)
    }

    /// ⚠️ NOTHING SIGNED IN, NOTHING MOVES, for a call as for a message.
    func testACallTapBeforeAnySnapshotMovesNothing() async {
        let rig = BranchRig()
        rig.store.path = [.calls]

        await rig.store.open(["type": "incoming_call", "workspaceId": "ws_1", "callId": "call_7"])

        XCTAssertEqual(rig.store.path, [.calls])
    }

    /// ⛔ A SIGNED-IN PHONE WITH NO WORKSPACE holds no inbox the message could be in: Home.
    func testAMessageTapWithNoWorkspaceOpensHome() async {
        let rig = BranchRig()
        var unscoped = snapshot
        unscoped.workspace = nil
        rig.store.apply(.snapshot(unscoped))
        rig.store.path = [.calls]

        await rig.store.open(WatchStoreTests.tap())

        XCTAssertEqual(rig.store.path, [])
        XCTAssertTrue(rig.link.sent.isEmpty)
    }

    /// ⚠️ AN ANSWER THAT NAMES NO THREAD IS NO THREAD: the inbox stays and nothing is asked again.
    func testAnEmptyThreadKeyEndsTheRoute() async {
        let rig = BranchRig(answers: [.reply(.thread(""))])
        rig.store.apply(.snapshot(snapshot))

        await rig.store.open(WatchStoreTests.tap())
        rig.store.apply(.snapshot(snapshot))
        await rig.store.settleRoute()

        XCTAssertEqual(rig.store.path, [.inbox])
        XCTAssertEqual(rig.link.sent.count, 1)
    }

    /// ⚠️ OUT OF REACH ON SEND IS NOT AN ANSWER: the route is kept and asked again on the next
    /// snapshot, which then opens the thread.
    func testAnUnreachableAnswerKeepsTheRouteForTheNextSnapshot() async throws {
        let rig = BranchRig(answers: [.unreachable, .reply(.thread("contact:c_1"))])
        rig.store.apply(.snapshot(snapshot))

        await rig.store.open(WatchStoreTests.tap())
        XCTAssertEqual(rig.store.path, [.inbox])
        rig.store.apply(.snapshot(snapshot))
        await rig.store.settleRoute()

        let conversation = try firstConversation
        XCTAssertEqual(rig.store.path, [.inbox, .thread(conversation)])
        XCTAssertEqual(rig.link.sent.count, 2)
    }

    /// ⚠️ A NEWER TAP WHILE THE PHONE IS ANSWERING THE OLDER ONE: the older answer is dropped,
    /// so it can never open its thread for the newer message, and the newer one is asked again.
    func testANewerTapWhileThePhoneAnswersDropsTheOlderAnswer() async {
        let rig = BranchRig(answers: [.reply(.thread("contact:c_1")), .unreachable, .reply(.thread("contact:c_2"))])
        var two = snapshot
        two.conversations?.append(BranchFixtures.secondConversation)
        rig.store.apply(.snapshot(two))
        rig.link.onSend = { [store = rig.store, link = rig.link] _ in
            link.onSend = nil
            await store.open(BranchFixtures.messageTap("msg_2"))
        }

        await rig.store.open(BranchFixtures.messageTap("msg_1"))

        XCTAssertEqual(rig.store.path, [.inbox], "the older answer opened nothing")
        XCTAssertEqual(rig.link.sent, [
            .resolveMessage(workspaceId: "ws_1", messageId: "msg_1"),
            .resolveMessage(workspaceId: "ws_1", messageId: "msg_2"),
        ])
        rig.store.apply(.snapshot(two))
        await rig.store.settleRoute()
        XCTAssertEqual(rig.store.path, [.inbox, .thread(BranchFixtures.secondConversation)])
        XCTAssertEqual(rig.link.sent.last, .resolveMessage(workspaceId: "ws_1", messageId: "msg_2"))
    }

    /// ⚠️ THE WINDOW CLOSES FOR A ROUTE NEVER ASKED, too: a phone back in reach after it asks
    /// nothing.
    func testAPhoneBackAfterTheWindowIsNotAsked() async {
        let rig = BranchRig(reachable: false, answers: [.reply(.thread("contact:c_1"))])
        rig.store.start()
        rig.store.apply(.snapshot(snapshot))
        await rig.store.open(WatchStoreTests.tap())

        rig.clock.now += WatchStore.routeWindow + 1
        rig.link.isReachable = true
        rig.link.onReachable?()
        rig.store.apply(.snapshot(snapshot))
        await rig.store.settleRoute()

        XCTAssertTrue(rig.link.sent.isEmpty)
        XCTAssertEqual(rig.store.path, [.inbox])
    }

    func testAPayloadThatIsNoRouteMovesNothing() async {
        let rig = BranchRig()
        rig.store.apply(.snapshot(snapshot))
        rig.store.path = [.calls]

        await rig.store.open([:])
        await rig.store.open(["type": "message", "workspaceId": " ", "messageId": "msg_1"])

        XCTAssertEqual(rig.store.path, [.calls])
        XCTAssertTrue(rig.link.sent.isEmpty)
    }

    // MARK: - A watched call that ends

    /// ⚠️ THE TRANSCRIPT BECOMES ITS CARD WHERE IT STOOD, deeper in the stack too; a stack
    /// without it is left alone.
    func testAnEndedCallReplacesOnlyItsOwnScreen() {
        let rig = BranchRig()
        let call = BranchFixtures.call
        rig.store.path = [.calls, .live(call)]
        rig.store.live.open(call)

        rig.store.live.apply(BranchFixtures.update(cursor: "c1", reset: true, phase: .ended))

        XCTAssertEqual(rig.store.path, [.calls, .callCard(workspaceId: "ws_1", callId: "call_1")])

        let other = BranchRig()
        other.store.path = [.inbox]
        other.store.live.open(call)
        other.store.live.apply(BranchFixtures.update(cursor: "c1", reset: true, phase: .ended))
        XCTAssertEqual(other.store.path, [.inbox])
        rig.store.live.close()
        other.store.live.close()
    }

    // MARK: - The complication

    /// ⛔ UNKNOWN STAYS UNKNOWN: no workspace and unread availability are nil, never false.
    func testTheComplicationOfAnUnscopedSnapshotIsUnknownNotOff() {
        var unscoped = snapshot
        unscoped.workspace = nil
        unscoped.availability = nil
        unscoped.unreadCount = 0

        let state = ComplicationState(unscoped)

        XCTAssertTrue(state.signedIn)
        XCTAssertNil(state.workspaceName)
        XCTAssertNil(state.available)
        XCTAssertEqual(state.unreadCount, 0)
        XCTAssertEqual(state.language, "en")
        XCTAssertNil(state.availabilityChangedAt)
    }
}
