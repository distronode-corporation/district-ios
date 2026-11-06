@testable import DistrictAI
import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// Meta's reply window on a Messenger or Instagram reply (DistrictCore 8.3.0), the website's
/// rules: closed disables Send and says why, human agent shows its badge and offers no AI
/// draft, and open or unknown blocks nothing. The reads keep the WhatsApp window's guards.
@MainActor
final class MetaWindowTests: XCTestCase {
    private static let messenger = ReplyTarget(to: "fb:5550101", channel: MessageChannel.messenger)
    private static let instagram = ReplyTarget(to: "ig:5550102", channel: MessageChannel.instagram)

    private static let open = #"{"success":true,"window":{"state":"open","until":"2026-08-16T14:25:00.000Z"}}"#
    private static let humanAgent =
        #"{"success":true,"window":{"state":"human_agent","until":"2026-08-22T14:25:00.000Z"}}"#
    private static let closed = #"{"success":true,"window":{"state":"closed","until":null}}"#
    private static let refused =
        #"{"success":false,"error":"The reply window is closed.","code":"messenger_window_closed"}"#

    private static let windowClosed = ApiError.http(status: 409, message: nil, code: ApiErrorCode.messengerWindowClosed)

    private func thread(_ transport: ParityTransport, _ targets: [ReplyTarget] = [messenger]) -> ThreadModel {
        ParityFixtures.thread(transport, threadKey: "addr:fb:5550101", targets: targets)
    }

    // MARK: - The three states, and the unknown one

    func testTheReadSendsTheChannelAndTheAddress() async {
        let transport = ParityTransport()
        transport.on(.get, "/messages/send", 200, Self.open)
        let model = thread(transport, [Self.instagram])

        await model.refreshMetaWindow()

        let read = transport.requests(to: "/messages/send")
        XCTAssertEqual(read.map(\.method), [.get])
        XCTAssertEqual(read.first?.query("channel"), "instagram")
        XCTAssertEqual(read.first?.query("to"), "ig:5550102")
        XCTAssertEqual(read.first?.query("workspaceId"), "ws_1")
        XCTAssertEqual(model.meta.window, .open(to: "ig:5550102"))
    }

    /// ⛔ CLOSED: Send is disabled and the box keeps its text, as on the website.
    func testAClosedWindowDisablesSend() async {
        let transport = ParityTransport()
        transport.on(.get, "/messages/send", 200, Self.closed)
        transport.on(.get, "/timeline", 200, ParityFixtures.timeline)
        let model = thread(transport)
        await model.load()
        await model.refreshMetaWindow()
        model.composerTextChanged("We open at nine.")

        XCTAssertTrue(model.metaWindowClosed)
        XCTAssertFalse(model.metaHumanAgent)
        XCTAssertFalse(model.canSendNow)
        await model.send()
        XCTAssertTrue(transport.requests(to: "/messages/send").allSatisfy { $0.method == .get }, "nothing was sent")
        XCTAssertEqual(model.composerText, "We open at nine.")
    }

    /// ⛔ HUMAN AGENT: the badge, Send allowed, and no AI draft (Meta allows that tag for a
    /// person's reply only).
    func testTheHumanAgentWindowOffersNoAIDraft() async {
        let transport = ParityTransport()
        transport.on(.get, "/messages/send", 200, Self.humanAgent)
        transport.on(.get, "/timeline", 200, ParityFixtures.timeline)
        let model = thread(transport)
        await model.load()
        await model.refreshMetaWindow()
        model.composerTextChanged("We open at nine.")
        let before = transport.requests.count

        await model.generateDraft()

        XCTAssertTrue(model.metaHumanAgent)
        XCTAssertFalse(model.metaWindowClosed)
        XCTAssertTrue(model.canSendNow)
        XCTAssertEqual(transport.requests.count, before, "no generation was asked for")
    }

    /// ⛔ AN UNKNOWN STATE BLOCKS NOTHING, and neither does a failed read.
    func testAnUnknownStateOrAFailedReadBlocksNothing() async {
        let transport = ParityTransport()
        transport.on(.get, "/messages/send", 200, #"{"success":true,"window":{"state":"ad_window","until":null}}"#)
        transport.on(.get, "/messages/send", 500, #"{"success":false,"error":"Something went wrong."}"#)
        transport.on(.get, "/timeline", 200, ParityFixtures.timeline)
        let model = thread(transport)
        await model.load()
        model.composerTextChanged("We open at nine.")

        await model.refreshMetaWindow()
        XCTAssertEqual(model.meta.window, .unknown)
        XCTAssertTrue(model.canSendNow)

        await model.refreshMetaWindow()
        XCTAssertEqual(model.meta.window, .unknown)
        XCTAssertFalse(model.metaWindowClosed)
        XCTAssertFalse(model.metaHumanAgent)
    }

    /// ⚠️ ANOTHER CHANNEL READS NOTHING, and forgets a Meta answer.
    func testAnotherChannelReadsNothing() async {
        let transport = ParityTransport()
        transport.on(.get, "/messages/send", 200, Self.closed)
        let sms = ReplyTarget(to: "+14165550177", channel: MessageChannel.sms)
        let model = thread(transport, [Self.messenger, sms])
        await model.refreshMetaWindow()
        XCTAssertTrue(model.metaWindowClosed)

        model.selectReplyTarget(1)
        await model.refreshMetaWindow()

        XCTAssertEqual(transport.requests(to: "/messages/send").count, 1)
        XCTAssertEqual(model.meta.window, .unknown)
    }

    /// ⛔ A VIEWER READS NOTHING: it has no reply box to gate.
    func testAViewerReadsNothing() async {
        let transport = ParityTransport()
        let model = ParityFixtures.thread(
            transport,
            role: .viewer,
            threadKey: "addr:fb:5550101",
            targets: [Self.messenger]
        )

        await model.refreshMetaWindow()

        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(model.meta.window, .unknown)
    }

    // MARK: - The send

    /// ⛔ A SEND REFUSED FOR A CLOSED WINDOW CLOSES IT AT ONCE, as the website's `markClosed`
    /// does, and the text is kept.
    func testA409WindowClosedClosesTheComposer() async {
        let transport = ParityTransport()
        transport.on(.get, "/messages/send", 200, Self.open)
        transport.on(.get, "/timeline", 200, ParityFixtures.timeline)
        transport.on(.post, "/messages/send", 409, Self.refused)
        let model = thread(transport, [Self.instagram])
        await model.load()
        await model.refreshMetaWindow()
        model.composerTextChanged("We open at nine.")

        await model.send()

        XCTAssertTrue(model.metaWindowClosed)
        XCTAssertFalse(model.canSendNow)
        XCTAssertEqual(model.composerText, "We open at nine.")
        XCTAssertEqual(transport.requests(to: "/messages/send").filter { $0.method == .get }.count, 1)
    }

    /// ⛔ AND A READ STILL IN FLIGHT CANNOT REOPEN IT: its "open" answers after the refusal.
    func testAReadInFlightCannotReopenARefusedWindow() async {
        let transport = ParityTransport()
        transport.on(.get, "/messages/send", 200, Self.open)
        let gate = transport.hold(.get, "/messages/send")
        let model = thread(transport)

        let read = Task { await model.refreshMetaWindow() }
        await waitUntil { transport.requests(to: "/messages/send").count == 1 }
        model.noteMetaWindowRefusal(Self.windowClosed, for: Self.messenger)
        gate.open()
        await read.value

        XCTAssertTrue(model.metaWindowClosed)
    }

    /// ⚠️ ANY OTHER REFUSAL, OR ANOTHER CHANNEL'S, LEAVES THE WINDOW ALONE.
    func testAnotherRefusalLeavesTheWindowAlone() async {
        let transport = ParityTransport()
        transport.on(.get, "/messages/send", 200, Self.open)
        let model = thread(transport)
        await model.refreshMetaWindow()
        let sms = ReplyTarget(to: "+14165550177", channel: MessageChannel.sms)

        model.noteMetaWindowRefusal(ApiError.http(status: 429, message: nil, code: "rate_limited"), for: Self.messenger)
        model.noteMetaWindowRefusal(Self.windowClosed, for: sms)

        XCTAssertEqual(model.meta.window, .open(to: "fb:5550101"))
    }

    /// ⚠️ A REFUSAL FOR A REPLY NO LONGER SELECTED CLOSES NOTHING ON SCREEN.
    func testARefusalAfterAChannelSwitchClosesNothing() {
        let transport = ParityTransport()
        let model = thread(transport, [Self.messenger, Self.instagram])
        model.selectReplyTarget(1)

        model.noteMetaWindowRefusal(Self.windowClosed, for: Self.messenger)

        XCTAssertEqual(model.meta.window, .unknown)
    }

    /// ⚠️ A SENT META REPLY READS THE WINDOW AGAIN, as the website does.
    func testASentReplyRereadsTheWindow() async {
        let transport = ParityTransport()
        transport.on(.get, "/messages/send", 200, Self.open)
        transport.on(.get, "/messages/send", 200, Self.humanAgent)
        transport.on(.get, "/timeline", 200, ParityFixtures.timeline)
        transport.on(.post, "/messages/send", 200, ParityFixtures.sent)
        transport.on(.delete, "/messages/drafts", 200, #"{"success":true}"#)
        let model = thread(transport)
        await model.load()
        await model.refreshMetaWindow()
        model.composerTextChanged("We open at nine.")

        await model.send()

        XCTAssertEqual(transport.requests(to: "/messages/send").filter { $0.method == .get }.count, 2)
        XCTAssertTrue(model.metaHumanAgent)
    }

    // MARK: - Overlapping reads (the WhatsApp window's guards, #99 and #95)

    /// ⛔ AN OLDER READ THAT ANSWERS LAST IS DROPPED: its "open" must not undo a newer "closed".
    func testAnOlderReadThatAnswersLastIsDropped() async {
        let transport = ParityTransport()
        transport.on(.get, "/messages/send", 200, Self.open)
        transport.on(.get, "/messages/send", 200, Self.closed)
        let gate = transport.hold(.get, "/messages/send")
        let model = thread(transport)

        let older = Task { await model.refreshMetaWindow() }
        await waitUntil { transport.requests(to: "/messages/send").count == 1 }
        await model.refreshMetaWindow()
        XCTAssertTrue(model.metaWindowClosed)
        gate.open()
        await older.value

        XCTAssertTrue(model.metaWindowClosed, "the newer answer stands")
    }

    /// ⛔ A CANCELLED READ'S ANSWER IS IGNORED: the composer's `.task(id:)` cancels it.
    func testACancelledReadIsIgnored() async {
        let transport = ParityTransport()
        transport.on(.get, "/messages/send", 200, Self.closed)
        let gate = transport.hold(.get, "/messages/send")
        let model = thread(transport)

        let read = Task { await model.refreshMetaWindow() }
        await waitUntil { transport.requests(to: "/messages/send").count == 1 }
        read.cancel()
        gate.open()
        await read.value

        XCTAssertEqual(model.meta.window, .unknown)
    }

    /// ⛔ A READ THAT ANSWERS AFTER A CHANNEL SWITCH IS DROPPED.
    func testAStaleReadIsDroppedAfterAChannelSwitch() async {
        let transport = ParityTransport()
        transport.on(.get, "/messages/send", 200, Self.closed)
        let gate = transport.hold(.get, "/messages/send")
        let model = thread(transport, [Self.messenger, Self.instagram])

        let stale = Task { await model.refreshMetaWindow() }
        await waitUntil { transport.requests(to: "/messages/send").count == 1 }
        model.selectReplyTarget(1)
        gate.open()
        await stale.value

        XCTAssertEqual(model.meta.window, .unknown)
        model.selectReplyTarget(0)
        XCTAssertFalse(model.metaWindowClosed, "the old answer was never applied")
    }

    func testEachServerStateMapsToTheComposersWindow() {
        XCTAssertEqual(ThreadModel.composerWindow(.open, to: "fb:1"), .open(to: "fb:1"))
        XCTAssertEqual(ThreadModel.composerWindow(.humanAgent, to: "fb:1"), .humanAgent(to: "fb:1"))
        XCTAssertEqual(ThreadModel.composerWindow(.closed, to: "fb:1"), .closed(to: "fb:1"))
        XCTAssertEqual(ThreadModel.composerWindow(.unknown("ad_window"), to: "fb:1"), .unknown)
    }
}
