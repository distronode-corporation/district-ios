@testable import DistrictAI
import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// App parity (5), DistrictCore 8.2.0, the window half (xhigh review, #99 and #95): a WhatsApp
/// window that closes while the thread is open is noticed, by the send's 409 or at its
/// `expiresAt`, and a read that answers after a channel switch is dropped.
@MainActor
final class WhatsAppWindowTests: XCTestCase {
    private static let whatsApp = [ReplyTarget(to: "+14165550177", channel: MessageChannel.whatsapp)]

    /// ⛔ A FREE-TEXT SEND REFUSED FOR A CLOSED WINDOW FLIPS THE COMPOSER TO TEMPLATES (xhigh
    /// review): the window shut while the thread was open, and the 409 re-reads it.
    func testA409WindowClosedRereadsTheWindowAndOffersTemplates() async {
        let transport = ParityTransport()
        transport.on(.get, "/whatsapp/window", 200, ParityFixtures.windowOpen)
        transport.on(.get, "/whatsapp/window", 200, ParityFixtures.windowClosed)
        transport.on(.get, "/timeline", 200, ParityFixtures.timeline)
        transport.on(
            .post, "/messages/send", 409,
            #"{"success":false,"error":"The WhatsApp window is closed.","code":"whatsapp_window_closed"}"#
        )
        let model = ParityFixtures.thread(transport, targets: Self.whatsApp)
        await model.load()
        await model.refreshWhatsAppWindow()
        XCTAssertFalse(model.whatsAppWindowClosed)
        model.composerTextChanged("Yes, we do.")

        await model.send()

        XCTAssertTrue(model.whatsAppWindowClosed, "the template button is where the box was")
        XCTAssertEqual(transport.requests(to: "/whatsapp/window").count, 2)
        XCTAssertEqual(model.composerText, "Yes, we do.", "the text is kept")
    }

    /// ⚠️ ANY OTHER REFUSAL LEAVES THE WINDOW ALONE: no second read.
    func testAnotherRefusalDoesNotRereadTheWindow() async {
        let transport = ParityTransport()
        transport.on(.get, "/whatsapp/window", 200, ParityFixtures.windowOpen)
        transport.on(.get, "/timeline", 200, ParityFixtures.timeline)
        transport.on(.post, "/messages/send", 429, #"{"success":false,"error":"Slow down."}"#)
        let model = ParityFixtures.thread(transport, targets: Self.whatsApp)
        await model.load()
        await model.refreshWhatsAppWindow()
        model.composerTextChanged("Yes, we do.")

        await model.send()

        XCTAssertEqual(transport.requests(to: "/whatsapp/window").count, 1)
        XCTAssertFalse(model.whatsAppWindowClosed)
    }

    /// ⛔ A WINDOW READ THAT ANSWERS AFTER A CHANNEL SWITCH IS DROPPED: the reply is no longer
    /// WhatsApp, so its answer must not close (or open) anything.
    func testAStaleWindowReadIsDroppedAfterAChannelSwitch() async {
        let transport = ParityTransport()
        transport.on(.get, "/whatsapp/window", 200, ParityFixtures.windowClosed)
        let gate = transport.hold(.get, "/whatsapp/window")
        let model = ParityFixtures.thread(transport, targets: [
            Self.whatsApp[0],
            ReplyTarget(to: "+14165550177", channel: MessageChannel.sms),
        ])

        let stale = Task { await model.refreshWhatsAppWindow() }
        await waitUntil { transport.requests(to: "/whatsapp/window").count == 1 }
        model.selectReplyTarget(1)
        await model.refreshWhatsAppWindow()
        gate.open()
        await stale.value

        XCTAssertEqual(model.whatsApp.window, .unknown)
        model.selectReplyTarget(0)
        XCTAssertFalse(model.whatsAppWindowClosed, "the old answer was never applied")
    }

    /// ⛔ AN OPEN WINDOW IS RE-READ AT ITS CLOSE (xhigh review): the wait is the time to
    /// `expiresAt`, none once it has passed, and no wait without an instant.
    func testTheWindowIsRereadWhenItCloses() async throws {
        let now = try XCTUnwrap(WireInstant.parse("2026-08-16T14:00:00.000Z"))
        XCTAssertEqual(ThreadModel.untilWindowCloses("2026-08-16T14:05:00.000Z", now: now), .seconds(300))
        XCTAssertEqual(ThreadModel.untilWindowCloses("2026-08-16T13:00:00.000Z", now: now), .zero)
        XCTAssertNil(ThreadModel.untilWindowCloses(nil, now: now))
        XCTAssertNil(ThreadModel.untilWindowCloses("soon", now: now))

        let transport = ParityTransport()
        transport.on(.get, "/whatsapp/window", 200, ParityFixtures.windowOpen)
        transport.on(.get, "/whatsapp/window", 200, ParityFixtures.windowClosed)
        let model = ParityFixtures.thread(transport, targets: Self.whatsApp)
        await model.refreshWhatsAppWindow()
        XCTAssertFalse(model.whatsAppWindowClosed)

        // The fixture's window closes on 2026-08-16, long before the test runs: no wait.
        await model.rereadWindowAtExpiry()

        XCTAssertTrue(model.whatsAppWindowClosed)
        XCTAssertEqual(transport.requests(to: "/whatsapp/window").count, 2)
    }
}
