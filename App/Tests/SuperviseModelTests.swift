@testable import DistrictAI
import DistrictCall
import DistrictL10n
import DistrictModel
import XCTest

/// ⛔ THE ORDER A SUPERVISION PERFORMS THE CORE REDUCER'S COMMANDS IN, ON THIS APP'S SEAMS.
///
/// `SuperviseSession` is district-core-swift's and tested there; what is this app's is the
/// sequence across CallKit, the two routes and the two engines: the system call before the
/// seat, the listen room left before the coach room is joined, every ending reported or
/// requested exactly once, and the claim dropped on every terminal path.
@MainActor
final class SuperviseModelTests: XCTestCase {
    private var media = FakeSuperviseMedia()
    private let server = FakeSuperviseServer()

    private func makeModel(role: WorkspaceRole? = .agency, receptionistOnCall: Bool? = true) throws -> SuperviseModel {
        try SuperviseFixtures.model(
            call: SuperviseFixtures.call(receptionistOnCall: receptionistOnCall),
            role: role,
            server: server,
            media: media
        )
    }

    /// Press Listen, let the OS perform the start, and let the listen room connect.
    private func listen(_ model: SuperviseModel) async {
        server.answerMonitor(.success(SuperviseFixtures.listenSeat))
        let engines = media.engines.count
        model.listen()
        media.performStart()
        // ⚠️ THE ENGINE MUST EXIST BEFORE IT CAN SPEAK: an event yielded earlier goes nowhere.
        await waitUntil(state: "\(media.log)") {
            self.media.engines.count > engines && self.media.log.last == "connect wss://sfu.example.test listen.jwt"
        }
        media.engine(.listen, .connected)
        await waitUntil(state: "\(model.state.phase)") { model.state.phase == .listening }
    }

    // MARK: - Listen

    /// ⛔ THE CLAIM, THEN THE SYSTEM CALL, THEN (ONLY ONCE THE OS PERFORMED IT) THE SEAT, THEN A
    /// LISTEN-ONLY LEG. Q3: a listen-in is a CallKit call.
    func test_IOS_SUPERVISE_01_listenStartsTheSystemCallBeforeAskingForTheSeat() async throws {
        let model = try makeModel()
        server.answerMonitor(.success(SuperviseFixtures.listenSeat))

        model.listen()
        XCTAssertEqual(media.log, ["claim", "start +15555550100"])
        XCTAssertTrue(model.starting)
        XCTAssertEqual(server.requests, [], "nothing is asked of the server before the OS performs the start")

        media.performStart()
        await waitUntil(state: "\(media.log)") { self.media.log.last == "connect wss://sfu.example.test listen.jwt" }
        media.engine(.listen, .connected)
        await waitUntil(state: "\(media.log)") { model.state.phase == .listening }

        XCTAssertEqual(server.requests, ["monitor cmh1live0001 ios"])
        XCTAssertEqual(media.log, [
            "claim", "start +15555550100", "connecting Marie Tremblay", "beginLeg listen",
            "connect wss://sfu.example.test listen.jwt", "connected",
        ])
        XCTAssertFalse(model.state.media.microphoneEnabled, "a listener publishes nothing")
    }

    /// The system call a listen-in is goes into Recents, so the call it was is remembered for a
    /// tap there, once the OS has performed the start and not before.
    func test_IOS_SUPERVISE_24_aStartedListenInIsRememberedForRecents() async throws {
        let suite = "test.supervise-recents.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let recents = ListenInRecents(defaults: UserDefaults(suiteName: suite) ?? .standard, keys: MemoryRecentsKeys())
        let model = try makeModel()
        model.recents = recents
        server.answerMonitor(.success(SuperviseFixtures.listenSeat))

        model.listen()
        XCTAssertNil(recents.entry(forHandle: "+15555550100"), "not before the OS performed the start")
        media.performStart()
        await waitUntil { recents.entry(forHandle: "+15555550100") != nil }

        XCTAssertEqual(recents.entry(forHandle: "+15555550100")?.callId, SuperviseFixtures.callId)
        XCTAssertEqual(recents.entry(forHandle: "+15555550100")?.workspaceId, SuperviseFixtures.workspaceId)
    }

    /// ⛔ ONE CALL ON THE DEVICE: refused with a sentence while a call or a room holds it, and
    /// nothing is claimed or started.
    func test_IOS_SUPERVISE_02_aBusyDeviceRefusesListenWithItsSentence() throws {
        let model = try makeModel()
        media.hasLiveCall = true
        model.listen()
        XCTAssertEqual(model.startRefusal, SuperviseCopy.busyWithCall)

        media.hasLiveCall = false
        media.hasLiveRoom = true
        model.listen()
        XCTAssertEqual(model.startRefusal, SuperviseCopy.busyInRoom)
        XCTAssertEqual(media.log, [])
    }

    /// Listening to an ended call is refused by the server (`call_ended`): the core's sentence
    /// for that code, the OS told the call is over, and the claim released.
    func test_IOS_SUPERVISE_03_anEndedCallsRefusalIsSaidByItsCodeAndReported() async throws {
        let model = try makeModel()
        server.answerMonitor(.failure(.http(status: 409, message: "This call has ended.", code: "call_ended")))
        model.listen()
        media.performStart()
        await waitUntil(state: "\(media.log)") { self.media.log.contains("release") }

        let expected = try XCTUnwrap(ApiErrorText.sentence(for: "call_ended"))
        XCTAssertEqual(SuperviseCopy.problem(model.state.problem), expected)
        XCTAssertEqual(model.state.phase, .idle)
        XCTAssertEqual(media.log.suffix(3), ["reportEnded", "endLeg", "release"])
        XCTAssertFalse(media.isClaimed)
    }

    /// ⚠️ A START THE OS REFUSES ENDS THE ATTEMPT AT ONCE, with the not-started sentence, and
    /// the server is never asked.
    func test_IOS_SUPERVISE_04_aRefusedSystemStartSaysSoAndAsksNothing() async throws {
        let model = try makeModel()
        model.listen()
        media.onRefused?()
        await waitUntil { !self.media.isClaimed }

        XCTAssertEqual(model.startRefusal, SuperviseCopy.notStarted)
        XCTAssertFalse(model.starting)
        XCTAssertEqual(server.requests, [])
        XCTAssertEqual(media.log, ["claim", "start +15555550100", "requestEnd", "endLeg", "release"])
    }

    /// ⛔ STOP LISTENING: the OS is asked to end its call, the room is left, and nothing is
    /// REPORTED (CallKit performed this ending).
    func test_IOS_SUPERVISE_05_stopRequestsTheEndAndLeavesTheRoomWithoutAReport() async throws {
        let model = try makeModel()
        await listen(model)
        media.clearLog()

        await model.stop()

        XCTAssertEqual(media.log, ["requestEnd", "disconnect", "endLeg", "release"])
        XCTAssertEqual(model.state.phase, .idle)
        XCTAssertTrue(model.mayListen, "listening again is allowed, on a fresh engine")
    }

    /// The lock screen's end button reaches the reducer too, and is not reported back to it.
    func test_IOS_SUPERVISE_06_anEndFromTheSystemLeavesTheRoom() async throws {
        let model = try makeModel()
        await listen(model)
        media.clearLog()

        try media.system(.endRequested(uuid: XCTUnwrap(media.uuid)))
        await waitUntil { model.state.phase == .idle }

        XCTAssertEqual(media.log, ["disconnect", "endLeg", "release"])
    }

    // MARK: - Take over and hand back

    /// ⛔ THE COACH SEAT IS ASKED FOR WHILE STILL LISTENING; THE GRANT LEAVES THE LISTEN ROOM,
    /// THEN JOINS THE COACH ROOM, THEN OPENS THE MICROPHONE.
    func test_IOS_SUPERVISE_07_takeOverLeavesTheListenRoomBeforeJoiningTheCoachRoom() async throws {
        let model = try makeModel()
        await listen(model)
        media.clearLog()
        server.answerTakeover(.success(SuperviseFixtures.coachSeat))

        await model.takeOver()
        media.engine(.takeover, .connected)
        await waitUntil(state: "\(media.log)") { model.state.phase == .takenOver }

        XCTAssertEqual(server.requests.last, "takeOver ws_1 cmh1live0001")
        XCTAssertEqual(media.log, [
            "disconnect", "beginLeg takeover", "connect wss://sfu.example.test coach.jwt", "setMuted false",
        ])
        XCTAssertFalse(model.state.mayWhisper, "no note while holding the call")
    }

    /// ⛔ A REFUSED TAKEOVER LEAVES THE PERSON LISTENING, with the refusal's sentence.
    func test_IOS_SUPERVISE_08_aRefusedTakeoverLeavesThePersonListening() async throws {
        let model = try makeModel()
        await listen(model)
        media.clearLog()
        server.answerTakeover(.failure(.http(status: 429, message: nil, code: "rate_limited")))

        await model.takeOver()

        XCTAssertEqual(model.state.phase, .listening)
        XCTAssertEqual(media.log, [], "nothing torn down")
        XCTAssertEqual(SuperviseCopy.problem(model.state.problem), ApiErrorText.sentence(for: "rate_limited"))
    }

    /// ⛔ THE MICROPHONE IS ASKED BEFORE THE SERVER: a refusal asks nothing and keeps listening,
    /// with Sean's sentence for a microphone that cannot be used.
    func test_IOS_SUPERVISE_09_aRefusedMicrophoneAsksNoTakeover() async throws {
        media = FakeSuperviseMedia(microphone: FakeMicrophoneAccess(status: .denied))
        let model = try makeModel()
        await listen(model)

        await model.takeOver()

        XCTAssertEqual(model.state.phase, .listening)
        XCTAssertFalse(server.requests.contains { $0.hasPrefix("takeOver") })
        XCTAssertEqual(model.startRefusal, SuperviseCopy.takeOverJoinFailed)
    }

    /// ⛔ HAND BACK IS LEAVING: the OS is asked to end, the coach room is left, no report.
    func test_IOS_SUPERVISE_10_handBackLeavesTheCoachRoom() async throws {
        let model = try makeModel()
        await listen(model)
        server.answerTakeover(.success(SuperviseFixtures.coachSeat))
        await model.takeOver()
        media.engine(.takeover, .connected)
        await waitUntil { model.state.phase == .takenOver }
        media.clearLog()

        await model.stop()

        XCTAssertEqual(media.log, ["requestEnd", "disconnect", "endLeg", "release"])
    }

    /// The system's mute control reaches the coach's microphone, once per real change.
    func test_IOS_SUPERVISE_11_theSystemMuteControlMutesTheCoach() async throws {
        let model = try makeModel()
        await listen(model)
        server.answerTakeover(.success(SuperviseFixtures.coachSeat))
        await model.takeOver()
        media.engine(.takeover, .connected)
        media.engine(.takeover, .microphoneChanged(enabled: true))
        await waitUntil { model.state.media.microphoneEnabled }
        media.clearLog()

        model.toggleMute()
        XCTAssertEqual(media.log, ["requestMuted true"], "through CallKit, never straight to the engine")
        try media.system(.muteRequested(uuid: XCTUnwrap(media.uuid), muted: true))
        await waitUntil(state: "\(media.log)") { self.media.log.contains("setMuted true") }
    }

    // MARK: - Roles and the colleague's own call

    /// ⛔ A VIEWER LISTENS AND DOES NOTHING ELSE.
    func test_IOS_SUPERVISE_12_aViewerMayOnlyListen() async throws {
        let model = try makeModel(role: .viewer)
        XCTAssertTrue(model.mayListen)
        XCTAssertFalse(model.state.mayWhisper)
        await listen(model)
        XCTAssertFalse(model.state.mayTakeOver)

        model.draft = "Offer the Tuesday slot."
        await model.sendWhisper()
        await model.takeOver()
        XCTAssertEqual(server.requests, ["monitor cmh1live0001 ios"])
    }

    /// ⛔ Q2: ON A COLLEAGUE'S OWN SOFTPHONE CALL, LISTEN STAYS AND WHISPER AND TAKE OVER GO.
    func test_IOS_SUPERVISE_13_aColleaguesOwnCallOffersListenOnly() async throws {
        let model = try makeModel(receptionistOnCall: false)
        XCTAssertFalse(model.state.receptionistOnCall)
        XCTAssertFalse(model.state.mayWhisper)
        await listen(model)
        XCTAssertFalse(model.state.mayTakeOver)
    }

    /// ⚠️ A SERVER BEFORE LIVE SUPERVISE SENDS NO `receptionistOnCall`: read as `true`, the
    /// website's default, with the route's 409 as the fallback.
    func test_IOS_SUPERVISE_14_anAbsentReceptionistFlagReadsAsPresent() throws {
        let model = try makeModel(receptionistOnCall: nil)
        XCTAssertTrue(model.state.receptionistOnCall)
        XCTAssertTrue(model.state.mayWhisper)
    }

    // MARK: - The note and its receipt

    /// The note is trimmed, sent once, and cleared; the previous receipt goes with it.
    func test_IOS_SUPERVISE_15_aDeliveredNoteClearsTheDraftAndTheReceipt() async throws {
        let model = try makeModel()
        model.events.onEvent?(SuperviseFixtures.envelope(.whisperApplied, .object([
            "applied": .bool(true), "firstWords": .string("Sure."),
        ])))
        await waitUntil { model.state.receipt != nil }

        model.draft = "  Offer the Tuesday slot.  "
        await model.sendWhisper()

        XCTAssertEqual(server.requests, ["whisper Offer the Tuesday slot."])
        XCTAssertEqual(model.draft, "")
        XCTAssertNil(model.state.receipt)
    }

    /// ⛔ ONE NOTE AT A TIME: a second press while one is on its way sends nothing.
    func test_IOS_SUPERVISE_16_aSecondSendWhileOneIsOnItsWayIsDropped() async throws {
        let model = try makeModel()
        server.holdsWhispers = true
        model.draft = "Offer the Tuesday slot."
        let first = Task { await model.sendWhisper() }
        await waitUntil { self.server.isHoldingWhisper }
        XCTAssertTrue(model.sending)

        await model.sendWhisper()
        server.releaseWhisper()
        await first.value

        XCTAssertEqual(server.requests, ["whisper Offer the Tuesday slot."])
    }

    /// The route's limit is checked here, with Sean's sentence, and nothing is sent.
    func test_IOS_SUPERVISE_17_aNoteOverTheLimitIsRefusedLocally() async throws {
        let model = try makeModel()
        model.draft = String(repeating: "a", count: SuperviseCopy.whisperLimit + 1)
        await model.sendWhisper()
        XCTAssertEqual(model.whisperProblem, SuperviseCopy.whisperTooLong(2000))
        XCTAssertEqual(server.requests, [])
    }

    /// A refusal is said by its code; one this build does not know gets the website's fallback,
    /// and the draft is kept for another try.
    func test_IOS_SUPERVISE_18_aFailedNoteKeepsTheDraft() async throws {
        let model = try makeModel()
        server.answerWhisper(.failure(.http(status: 409, message: nil, code: "call_has_no_receptionist")))
        model.draft = "Offer the Tuesday slot."
        await model.sendWhisper()
        XCTAssertEqual(model.whisperProblem, ApiErrorText.sentence(for: "call_has_no_receptionist"))
        XCTAssertEqual(model.draft, "Offer the Tuesday slot.")

        server.answerWhisper(.failure(.http(status: 400, message: nil, code: "not_a_code_this_build_knows")))
        await model.sendWhisper()
        XCTAssertEqual(model.whisperProblem, SuperviseCopy.whisperFailed)
    }

    /// ⛔ ONLY THIS CALL'S RECEIPT: the event is relayed to the whole workspace.
    func test_IOS_SUPERVISE_19_aReceiptForAnotherCallIsIgnored() async throws {
        let model = try makeModel()
        model.events.onEvent?(SuperviseFixtures.envelope(
            .whisperApplied,
            .object(["applied": .bool(false), "reason": .string("transfer")]),
            callId: "cmh1other0002"
        ))
        model.events.onEvent?(SuperviseFixtures.envelope(
            .whisperApplied,
            .object(["applied": .bool(false), "reason": .string("taken_over")])
        ))
        await waitUntil { model.state.receipt != nil }
        XCTAssertEqual(model.state.receipt?.reason, .takenOver)
    }

    // MARK: - The call ending

    /// ⛔ THE CALL ENDING WHILE LISTENING IS REPORTED (CallKit did not perform it) and the
    /// screen says the call has ended.
    func test_IOS_SUPERVISE_20_theCallEndingWhileListeningIsReported() async throws {
        let model = try makeModel()
        await listen(model)
        media.clearLog()

        model.events.onEvent?(SuperviseFixtures.envelope(.callEnded, .object(["status": .string("completed")])))
        await waitUntil { model.state.phase == .over }

        XCTAssertEqual(media.log, ["reportEnded", "disconnect", "endLeg", "release"])
        XCTAssertFalse(model.mayListen)
    }

    /// ⛔ THE CALL ENDING WHILE THE OS IS STILL STARTING THE LISTEN-IN: the system call is
    /// ended, and the server is never asked for a seat.
    func test_IOS_SUPERVISE_21_theCallEndingDuringTheStartEndsTheSystemCall() async throws {
        let model = try makeModel()
        model.listen()
        model.events.onEvent?(SuperviseFixtures.envelope(.callUpdated, .object(["status": .string("completed")])))
        await waitUntil { model.state.phase == .over }
        XCTAssertTrue(media.isClaimed, "the start is still the OS's to answer")

        media.performStart()
        await waitUntil { !self.media.isClaimed }

        XCTAssertEqual(server.requests, [])
        XCTAssertEqual(media.log, ["claim", "start +15555550100", "requestEnd", "endLeg", "release"])
    }

    /// ⛔ STOP, THEN LISTEN AGAIN: the first engine's late `disconnected` ends nothing (Seer, on
    /// district-core-swift 8.2.0; the session ignores an engine generation it has left).
    func test_IOS_SUPERVISE_23_aStoppedEnginesLateEventEndsNothing() async throws {
        let model = try makeModel()
        await listen(model)
        await model.stop()
        await listen(model)
        XCTAssertEqual(media.engines.count, 2)

        media.engine(at: 0, .disconnected(reason: "late"))
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(model.state.phase, .listening)
        XCTAssertNil(model.state.problem)
    }

    /// The handle the lock screen and Recents show: the caller's number, never the call id.
    func test_IOS_SUPERVISE_22_theSystemHandleIsTheCallersNumber() throws {
        let inbound = try SuperviseFixtures.call()
        XCTAssertEqual(SuperviseModel.handle(for: inbound), "+15555550100")
        let withheld = try LiveFixtures.call(id: SuperviseFixtures.callId, status: "in-progress", from: "Unknown")
        XCTAssertEqual(SuperviseModel.handle(for: withheld), CallDisplay(withheld).callerLabel)
    }
}
