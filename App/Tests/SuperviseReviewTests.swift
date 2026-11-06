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
        try server.answerDetail(.success(SuperviseFixtures.call(status: "completed")))

        model.events.onOpen?()
        await waitUntil { model.state.phase == .over }

        XCTAssertTrue(server.requests.contains("detail ws_1 cmh1live0001"))
        XCTAssertEqual(media.log, ["reportEnded", "disconnect", "endLeg", "release"])
    }

    func testAReconnectOnALiveCallChangesNothing() async throws {
        let model = try makeModel()
        await listen(model)
        try server.answerDetail(.success(SuperviseFixtures.call(status: "in-progress")))

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

    // MARK: - The max review

    /// ⛔ AN END DURING THE ROOM SWAP BUILDS NO ORPHAN COACH ENGINE (item 2): the engine already
    /// built is ended, connected to nothing.
    func testAnEndDuringTheSwapEndsTheCoachEngineUnconnected() async throws {
        let model = try makeModel()
        await listen(model)
        server.answerTakeover(.success(SuperviseFixtures.coachSeat))
        media.holdsBeginLeg = true
        let taking = Task { await model.takeOver() }
        await waitUntil { self.media.isHoldingBeginLeg }

        await model.stop()
        media.clearLog()
        media.releaseBeginLeg()
        await taking.value

        XCTAssertEqual(media.log, ["endLeg"], "ended, and never connected")
        XCTAssertFalse(media.log.contains { $0.hasPrefix("connect") })
        XCTAssertEqual(model.state.phase, .idle)
    }

    /// ⛔ A DROP IS CHECKED AGAINST THE ROW (item 3): a room deleted because the call ended ends
    /// as over; a drop on a live call stays a drop.
    func testADropOnAnEndedCallEndsOverAndOnALiveCallStaysADrop() async throws {
        let model = try makeModel()
        await listen(model)
        try server.answerDetail(.success(SuperviseFixtures.call(status: "in-progress")))
        media.engine(.listen, .disconnected(reason: "network"))
        await waitUntil { model.state.problem != nil }
        await waitUntil { self.server.requests.contains { $0.hasPrefix("detail") } }
        XCTAssertEqual(model.state.problem, .listenDropped(reason: "network"))
        XCTAssertEqual(model.state.phase, .idle)

        await listen(model)
        try server.answerDetail(.success(SuperviseFixtures.call(status: "completed")))
        media.engine(.listen, .disconnected(reason: "room deleted"))
        await waitUntil { model.state.phase == .over }
    }

    /// ⛔ A REFUSAL FOR AN ABANDONED LISTEN IS NOT THE NEXT ONE'S (item 7).
    func testAStaleRefusalAfterStopAndListenAgainIsDropped() async throws {
        let model = try makeModel()
        server.answerMonitor(.failure(.http(status: 409, message: nil, code: "call_ended")))
        server.holdsMonitor = true
        model.listen()
        media.performStart()
        await waitUntil { self.server.isHoldingMonitor }
        await model.stop()

        server.answerMonitor(.success(SuperviseFixtures.listenSeat))
        model.listen()
        media.performStart()
        await waitUntil { self.media.log.contains("connect wss://sfu.example.test listen.jwt") }
        server.releaseMonitor()
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertNil(model.state.problem, "the first attempt's refusal is dropped")
        XCTAssertEqual(model.state.phase, .joiningListen)
    }

    /// ⛔ A MUTE PRESSED WHILE THE TAKEOVER IS ON ITS WAY IS KEPT AND APPLIED ONCE JOINED (item 8).
    func testAMuteDuringTheTakeoverIsAppliedOnceJoined() async throws {
        let model = try makeModel()
        await listen(model)
        let uuid = try XCTUnwrap(media.uuid)
        server.answerTakeover(.success(SuperviseFixtures.coachSeat))
        await model.takeOver()
        XCTAssertEqual(model.state.phase, .joiningTakeover)
        media.clearLog()

        media.system(.muteRequested(uuid: uuid, muted: true))
        media.engine(.takeover, .connected)
        await waitUntil(state: "\(media.log)") { self.media.log.contains("setMuted true") }

        XCTAssertEqual(media.log, ["setMuted false", "setMuted true"])
        XCTAssertFalse(media.log.contains("requestMuted false"), "not undone")
    }

    // MARK: - The dialler and a workspace switch

    /// ⛔ THE KEYPAD'S CALL ENDS ON SIGN-OUT ONLY (Sean, 2026-11-06), never on `unavailable`.
    func testTheKeypadCallEndsOnSignOutOnly() async {
        XCTAssertTrue(CallTeardown.endsSoftphone(.signedOut("Signed out.")))
        XCTAssertFalse(CallTeardown.endsSoftphone(.unavailable("Try again.")))
        XCTAssertFalse(CallTeardown.endsSoftphone(.signedIn))
        XCTAssertFalse(CallTeardown.endsSoftphone(.checking))

        final class Softphone: SoftphoneEnding {
            var ended = 0
            func endSoftphone() async {
                ended += 1
            }
        }
        let softphone = Softphone()
        let stack = CallStack(microphone: FakeMicrophoneAccess(status: .granted))
        stack.softphone = softphone
        await stack.endSoftphone()
        XCTAssertEqual(softphone.ended, 1)
    }

    /// ⛔ A SWITCH FROM ONE WORKSPACE TO ANOTHER, HOWEVER MADE (the picker included), ends a
    /// supervision; the first workspace resolving does not (item 5).
    func testOnlyAWorkspaceToWorkspaceChangeIsASwitch() {
        XCTAssertTrue(CallTeardown.isWorkspaceSwitch(from: "ws_1", to: "ws_2"))
        XCTAssertFalse(CallTeardown.isWorkspaceSwitch(from: nil, to: "ws_1"))
        XCTAssertFalse(CallTeardown.isWorkspaceSwitch(from: "ws_1", to: "ws_1"))
        XCTAssertFalse(CallTeardown.isWorkspaceSwitch(from: "ws_1", to: nil))
    }

    /// ⛔ A PICKER SWITCH PASSES THROUGH NIL AND STILL ENDS A SUPERVISION (Seer, district-macos
    /// PR #98): `WorkspaceSessionModel.select(_:)` puts the state back to `.loading` while the new
    /// list is read, so the shell sees A, nil, B, and neither step alone is a switch.
    func testASwitchThroughNilEndsASupervision() async throws {
        final class Supervisor: SupervisionEnding {
            var ended = 0
            func endSupervision() async {
                ended += 1
            }
        }
        let supervisor = Supervisor()
        let stack = CallStack(microphone: FakeMicrophoneAccess(status: .granted))
        stack.supervisor = supervisor

        // The first workspace resolving, and the same one read again, are not switches.
        for workspaceId in [nil, "ws_1", nil, "ws_1"] {
            stack.workspaceSelected(workspaceId)
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(supervisor.ended, 0)

        stack.workspaceSelected(nil)
        stack.workspaceSelected("ws_2")
        await waitUntil(state: "ended \(supervisor.ended)") { supervisor.ended == 1 }
    }
}
