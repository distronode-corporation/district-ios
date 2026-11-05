@testable import DistrictAI
import DistrictData
import DistrictL10n
import DistrictModel
import Foundation
import XCTest

/// What a sent message's status badge says for the statuses the service really writes.
///
/// ⛔ THE SERVICE'S VOCABULARY IS FIVE WORDS: `queued`, `sent`, `delivered` and `failed`
/// on an outbound message (the website's `DeliveryStatus`) and `received` on an inbound
/// one. `read` is not among them: every read receipt is recorded as `delivered`. The
/// first closed-window screenshots showed "read" and « Autre » because their seed said
/// `read`; ``ParityFixtures/answeredTimeline`` is the realistic thread.
@MainActor
final class InboxDeliveryStatusTests: XCTestCase {
    private static let whatsApp = [ReplyTarget(to: "+14165550177", channel: MessageChannel.whatsapp)]

    private func french<T>(_ body: () -> T) -> T {
        L10nRuntime.withLocale(.frCA, body)
    }

    /// ⛔ EVERY STATUS THE SERVICE WRITES HAS A LABEL IN BOTH LANGUAGES: none falls through
    /// to the wire word in English or to « Autre » in French.
    func testEveryStatusTheServiceWritesIsLabelledInBothLanguages() {
        let other = french { AppWire.label(.messageDeliveryStatus, "not-a-status") }
        for status in ["queued", "sent", "delivered", "failed", "received"] {
            XCTAssertNotNil(WireLabel.knownLabel(.messageDeliveryStatus, status), status)
            XCTAssertNotEqual(french { AppWire.label(.messageDeliveryStatus, status) }, other, status)
        }
    }

    /// The screenshots' thread, read through the real repository and decoder: the reply
    /// the customer has read shows "Delivered" / « Livré » in the success tone.
    func testAReadReplyShowsDeliveredInBothLanguages() async throws {
        let transport = ParityTransport()
        transport.on(.get, "/timeline", 200, ParityFixtures.answeredTimeline)
        let model = ParityFixtures.thread(transport, targets: Self.whatsApp)
        await model.load()

        let events = try XCTUnwrap(model.current?.events)
        let reply = try XCTUnwrap(events.first { $0.isOutbound })
        XCTAssertEqual(reply.status, "delivered")
        XCTAssertFalse(events.contains { $0.status == "read" })
        XCTAssertEqual(AppWire.label(.messageDeliveryStatus, reply.status), "Delivered")
        XCTAssertEqual(french { AppWire.label(.messageDeliveryStatus, reply.status) }, "Livré")
        XCTAssertEqual(ThreadMessageTone.tone(for: reply.status), .success)
    }
}
