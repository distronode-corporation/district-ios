@testable import DistrictAI
import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// When District Desk offers "New ticket", and where a failed submit is said.
///
/// ⛔ THE RULE IS THE OTHER CLIENTS': a role that may write, a desk that is ON and a queue
/// that answered (Windows `can_start`, Android's compose button on its loaded state). Each
/// case below is one of the screen's other states, where the button must not be drawn.
@MainActor
final class DeskModelStartTests: XCTestCase {
    func testOfferedOnceTheDeskIsOnAndTheQueueAnswered() async {
        let model = Self.model(SettingsTransport([Self.on, Self.queue]))
        XCTAssertFalse(model.canStartTicket, "nothing is offered before the desk has been read")

        await model.load()

        XCTAssertTrue(model.canStartTicket)
        XCTAssertTrue(model.startTicket())
    }

    func testOfferedOnAnEmptyQueue() async {
        let model = Self.model(SettingsTransport([Self.on, Self.emptyQueue]))
        await model.load()
        XCTAssertTrue(model.canStartTicket, "an empty queue is where every desk starts")
    }

    func testNotOfferedToAViewer() async {
        let model = Self.model(SettingsTransport([Self.on, Self.queue]), role: .viewer)
        await model.load()
        XCTAssertFalse(model.canStartTicket)
        XCTAssertFalse(model.startTicket())
    }

    func testNotOfferedForARoleThatDidNotParse() async {
        let model = Self.model(SettingsTransport([Self.on, Self.queue]), role: nil)
        await model.load()
        XCTAssertFalse(model.canStartTicket)
    }

    func testNotOfferedWhileTheDeskIsOff() async {
        let model = Self.model(SettingsTransport([Self.off]))
        await model.load()
        XCTAssertTrue(model.availability.isOff)
        XCTAssertFalse(model.canStartTicket, "the off card's one action is turning the desk on")
        XCTAssertFalse(model.startTicket())
    }

    /// ⚠️ THE QUEUE IS STILL READ WHEN THE SETTINGS READ FAILS, and it answers here, but
    /// whether the desk is taking tickets at all is the open question on that screen.
    func testNotOfferedWhenTheSettingsReadFailed() async {
        let model = Self.model(SettingsTransport(responses: [(500, "{}"), (200, Self.queue)]))
        await model.load()
        guard case .unknown = model.availability else {
            XCTFail("a failed settings read is the unknown state")
            return
        }
        XCTAssertEqual(model.allTickets.count, 1, "the queue was read")
        XCTAssertFalse(model.canStartTicket)
    }

    func testNotOfferedWhenTheQueueReadFailed() async {
        let model = Self.model(SettingsTransport(responses: [(200, Self.on), (500, "{}")]))
        await model.load()
        guard case .failed = model.queue else {
            XCTFail("the queue read failed")
            return
        }
        XCTAssertFalse(model.canStartTicket)
    }

    // MARK: - Where the outcome is said

    /// ⛔ A FAILED SUBMIT IS SAID IN THE FORM, which covers the queue's notice.
    func testAFailedCreateIsTheFormsFailureNotTheQueuesNotice() async {
        let transport = SettingsTransport(responses: [(200, Self.on), (200, Self.queue), (500, "{}")])
        let model = Self.model(transport)
        await model.load()

        let created = await model.createTicket(Self.draft)

        XCTAssertFalse(created)
        XCTAssertNotNil(model.composeFailure)
        XCTAssertNil(model.notice)
        XCTAssertTrue(model.canStartTicket, "a failed create leaves the button for the next one")
    }

    func testAnIncompleteDraftIsRefusedInTheFormWithoutARequest() async {
        let transport = SettingsTransport([Self.on, Self.queue])
        let model = Self.model(transport)
        await model.load()
        var draft = Self.draft
        draft.subject = "Hi"

        let created = await model.createTicket(draft)

        XCTAssertFalse(created)
        XCTAssertEqual(model.composeFailure, DeskCopy.createIncomplete)
        XCTAssertNil(model.notice)
        XCTAssertTrue(transport.requests.filter { $0.method == .post }.isEmpty)
    }

    /// ⚠️ A REOPENED FORM STARTS CLEAN, the way its draft does.
    func testStartingAgainClearsTheLastFormsFailure() async {
        let model = Self.model(SettingsTransport([Self.on, Self.queue]))
        await model.load()
        var draft = Self.draft
        draft.message = "  "
        _ = await model.createTicket(draft)
        XCTAssertNotNil(model.composeFailure)

        XCTAssertTrue(model.startTicket())

        XCTAssertNil(model.composeFailure)
    }

    func testASuccessfulCreateIsTheQueuesNotice() async {
        let model = Self.model(SettingsTransport([Self.on, Self.emptyQueue, Self.created, Self.queue]))
        await model.load()

        let created = await model.createTicket(Self.draft)

        XCTAssertTrue(created)
        XCTAssertEqual(model.notice, DeskCopy.createSucceeded)
        XCTAssertNil(model.composeFailure)
        XCTAssertEqual(model.allTickets.count, 1, "the queue is re-read after the create")
    }

    // MARK: - Helpers

    private static func model(_ transport: SettingsTransport, role: WorkspaceRole? = .client) -> DeskModel {
        DeskModel(
            desk: DeskRepository(client: ApiClient(
                baseURL: ApiClient.productionBaseURL,
                transport: transport,
                accessToken: { "session-token" }
            )),
            workspaceId: "ws_1",
            role: role
        )
    }

    private static var draft: DeskComposerState {
        var draft = DeskComposerState()
        draft.subject = "Refund not received"
        draft.message = "Ordered on the 3rd."
        return draft
    }

    private static func settings(enabled: Bool) -> String {
        #"{"success":true,"settings":{"enabled":\#(enabled),"notifyCustomersByEmail":false,"#
            + #""publicBrandName":null,"publicLogoUrl":null}}"#
    }

    private static let on = settings(enabled: true)
    private static let off = settings(enabled: false)

    private static let summary = #"""
    {"id":"tkt_1","reference":7,"displayReference":"T-7","subject":"Refund not received",
     "status":"open","source":"manual","contactId":null,"requesterName":null,
     "requesterEmail":null,"requesterPhone":null,"createdAt":"2026-09-06T09:41:00.000Z",
     "updatedAt":"2026-09-06T09:45:00.000Z","resolvedAt":null,"messageCount":1}
    """#

    private static let created = #"{"success":true,"ticket":\#(summary)}"#
    private static let queue = #"{"success":true,"tickets":[\#(summary)]}"#
    private static let emptyQueue = #"{"success":true,"tickets":[]}"#
}
