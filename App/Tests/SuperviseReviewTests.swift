@testable import DistrictAI
import DistrictCall
import DistrictModel
import XCTest

/// The xhigh review of PR #101 (Sean: "All 1-11 + tests"), on the supervision's own seams:
/// an ended row, a reconnect, sign-out mid-call, a system mute while listening, a receipt
/// before the 200, and a stop while the join is still in flight.
@MainActor
final class SuperviseReviewTests: XCTestCase {
    private let media = FakeSuperviseMedia()
    private let server = FakeSuperviseServer()

    private func makeModel(status: String = "in-progress") throws -> SuperviseModel {
        try SuperviseFixtures.model(call: SuperviseFixtures.call(status: status), server: server, media: media)
    }

    private func listen(_ model: SuperviseModel) async {
        server.answerMonitor(.success(SuperviseFixtures.listenSeat))
        let engines = media.engines.count
        model.listen()
        media.performStart()
        await waitUntil(state: "\(media.log)") {
            self.media.engines.count > engines && self.media.log.contains("connect wss://sfu.example.test listen.jwt")
        }
        media.engine(.listen, .connected)
        await waitUntil(state: "\(model.state.phase)") { model.state.phase == .listening }
    }

    // MARK: - Item 3: an ended call

    /// ⛔ A ROW THAT HAS ALREADY ENDED OPENS ON "The call has ended.", never on Listen.
    func testARowThatEndedOpensOver() throws {
        let model = try makeModel(status: "completed")
        XCTAssertEqual(model.state.phase, .over)
        XCTAssertFalse(model.mayListen)
        XCTAssertFalse(model.state.mayWhisper)
        XCTAssertEqual(media.log, [], "nothing to report: the OS held nothing")

        let ringing = try makeModel(status: "ringing")
        XCTAssertEqual(ringing.state.phase, .idle, "ringing is not over")
    }

    /// ⛔ EVERY SOCKET OPEN RE-READS THE ROW: an end missed while no socket was open is caught.
    func testAReconnectReReadsTheRowAndEndsAnEndedCall() async throws {
        let model = try makeModel()
        await listen(model)
        media.clearLog()
        server.answerDetail(.success(SuperviseFixtures.call(status: "completed")))

        model.events.onOpen?()
        await waitUntil { model.state.phase == .over }

        XCTAssertTrue(server.requests.contains("detail ws_1 cmh1live0001"))
        XCTAssertEqual(media.log, ["reportEnded", "disconnect", "endLeg", "release"])
    }

    func testAReconnectOnALiveCallChangesNothing() async throws {
        let model = try makeModel()
        await listen(model)
        server.answerDetail(.success(SuperviseFixtures.call(status: "in-progress")))

        await model.refresh()

        XCTAssertEqual(model.state.phase, .listening)
    }

    // MARK: - Item 4: sign-out or a workspace switch

    /// ⛔ THE CALL STACK ENDS A LIVE SUPERVISION, as it ends a meeting room.
    func testTheCallStackEndsALiveSupervision() async throws {
        let model = try makeModel()
        await listen(model)
        let stack = CallStack(microphone: FakeMicrophoneAccess(status: .granted))
        stack.supervisor = model
        media.clearLog()

        await stack.endSupervision()

        XCTAssertEqual(media.log, ["requestEnd", "disconnect", "endLeg", "release"])
        XCTAssertEqual(model.state.phase, .idle)
    }

    // MARK: - Item 5: a system mute while listening

    /// ⛔ THE SYSTEM'S MUTE IS PUT BACK WHILE LISTENING, ONCE, so a takeover never opens the
    /// microphone under a system UI that says muted.
    func testASystemMuteWhileListeningIsPutBack() async throws {
        let model = try makeModel()
        await listen(model)
        let uuid = try XCTUnwrap(media.uuid)
        media.clearLog()

        media.system(.muteRequested(uuid: uuid, muted: true))
        media.system(.muteRequested(uuid: uuid, muted: false))

        XCTAssertEqual(media.log, ["requestMuted false"], "answered once; the echo is ignored")

        server.answerTakeover(.success(SuperviseFixtures.coachSeat))
        await model.takeOver()
        media.engine(.takeover, .connected)
        await waitUntil(state: "\(media.log)") { self.media.log.contains("setMuted false") }
        XCTAssertFalse(media.log.contains("requestMuted true"))
    }

    // MARK: - Item 6: a receipt before the 200

    /// ⛔ A RECEIPT THAT ARRIVES BEFORE THE ROUTE ANSWERS IS KEPT.
    func testAReceiptBeforeTheTwoHundredIsKept() async throws {
        let model = try makeModel()
        server.holdsWhispers = true
        model.draft = "Offer the Tuesday slot."
        let sending = Task { await model.sendWhisper() }
        await waitUntil { self.server.isHoldingWhisper }

        model.events.onEvent?(SuperviseFixtures.envelope(.whisperApplied, .object([
            "applied": .bool(true), "firstWords": .string("Tuesday works."),
        ])))
        await waitUntil { model.state.receipt != nil }
        server.releaseWhisper()
        await sending.value

        XCTAssertEqual(model.state.receipt?.firstWords, "Tuesday works.")
    }

    // MARK: - A stop while the join is in flight

    /// ⛔ STOP DURING A HELD CONNECT LEAVES CLEANLY, the late connect changes nothing, and
    /// Listen works again on a fresh engine.
    func testStopDuringAnInFlightConnect() async throws {
        let model = try makeModel()
        media.holdsConnect = true
        server.answerMonitor(.success(SuperviseFixtures.listenSeat))
        model.listen()
        media.performStart()
        await waitUntil { self.media.isHoldingConnect }

        await model.stop()
        XCTAssertEqual(model.state.phase, .idle)
        media.engine(.listen, .connected)
        media.releaseConnect()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.state.phase, .idle, "the stopped engine's late connect ends nothing")
        XCTAssertFalse(media.isClaimed)

        media.holdsConnect = false
        await listen(model)
        XCTAssertEqual(media.engines.count, 2)
    }
}
