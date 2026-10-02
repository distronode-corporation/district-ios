@testable import DistrictAI
import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// Raising a Desk ticket on a customer's behalf.
///
/// ⛔ ONE TICKET PER SUBMIT, WHATEVER THE TAPS. Each call mints its own idempotency
/// key and the server's claim is fail-open, so a second call that reaches the wire is
/// a second ticket in a human's queue. A disabled button does not stop two taps
/// dispatched before a re-render; ``DeskModel/createTicket(_:)`` has to.
@MainActor
final class DeskModelCreateTests: XCTestCase {
    func testTwoConcurrentCreatesSendOneRequest() async {
        let transport = SettingsTransport([Self.created, Self.queue])
        let model = Self.model(transport)

        async let first = model.createTicket(Self.draft)
        async let second = model.createTicket(Self.draft)
        let outcomes = await [first, second]

        let posts = transport.requests.filter { $0.method == .post }
        XCTAssertEqual(posts.count, 1, "the second create must not reach the wire")
        XCTAssertEqual(outcomes.filter(\.self).count, 1, "exactly one create succeeds")
        XCTAssertFalse(model.creating, "the flag clears when the create finishes")
    }

    /// ⚠️ THE FLAG IS A LOCK FOR ONE ROUND TRIP, NOT A LATCH. A later ticket is a new
    /// submit and goes out.
    func testASecondCreateAfterTheFirstFinishesIsSent() async {
        let transport = SettingsTransport([Self.created, Self.queue, Self.created, Self.queue])
        let model = Self.model(transport)

        let first = await model.createTicket(Self.draft)
        let second = await model.createTicket(Self.draft)

        XCTAssertTrue(first)
        XCTAssertTrue(second)
        XCTAssertEqual(transport.requests.filter { $0.method == .post }.count, 2)
    }

    // MARK: - Helpers

    private static func model(_ transport: SettingsTransport) -> DeskModel {
        DeskModel(
            desk: DeskRepository(client: ApiClient(
                baseURL: ApiClient.productionBaseURL,
                transport: transport,
                accessToken: { "session-token" }
            )),
            workspaceId: "ws_1",
            role: .client
        )
    }

    private static var draft: DeskComposerState {
        var draft = DeskComposerState()
        draft.subject = "Refund not received"
        draft.message = "Ordered on the 3rd."
        return draft
    }

    private static let summary = #"""
    {"id":"tkt_1","reference":7,"displayReference":"T-7","subject":"Refund not received",
     "status":"open","source":"manual","contactId":null,"requesterName":null,
     "requesterEmail":null,"requesterPhone":null,"createdAt":"2026-09-06T09:41:00.000Z",
     "updatedAt":"2026-09-06T09:45:00.000Z","resolvedAt":null,"messageCount":1}
    """#

    private static let created = #"{"success":true,"ticket":\#(summary)}"#

    private static let queue = #"{"success":true,"tickets":[\#(summary)]}"#
}
