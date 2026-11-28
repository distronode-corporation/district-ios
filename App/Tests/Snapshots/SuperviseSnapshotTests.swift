@testable import DistrictAI
import DistrictCall
import DistrictModel
import SwiftUI
import XCTest

/// Supervising a live call: the screen before Listen, while listening (the note to the
/// receptionist), after a takeover, once the call is over, and each refusal that keeps a person
/// from listening.
///
/// ⚠️ THE MODEL IS THE REAL ``SuperviseModel`` OVER THE SUPERVISION TESTS' FAKES (the device's
/// CallKit and engines, the server and two sockets that never open), handed to the screen the way
/// the app hands a supervision already under way back to it: through the call stack's
/// `supervisor`. ``SuperviseView`` then draws that model rather than reading the call again.
final class SuperviseSnapshotTests: ScreenSnapshotTestCase {
    private var media = FakeSuperviseMedia()
    private let server = FakeSuperviseServer()
    private var model: SuperviseModel?

    override func tearDown() async throws {
        if let model {
            await model.endSupervision()
        }
        model = nil
        try await super.tearDown()
    }

    private func makeModel(
        role: WorkspaceRole? = .agency,
        receptionistOnCall: Bool? = true,
        status: String = "in-progress"
    ) throws -> SuperviseModel {
        let made = try SuperviseFixtures.model(
            call: SuperviseFixtures.call(receptionistOnCall: receptionistOnCall, status: status),
            role: role,
            server: server,
            media: media
        )
        model = made
        return made
    }

    /// Press Listen, let the OS perform the start, and let the listen room connect.
    private func listen(_ model: SuperviseModel) async {
        server.answerMonitor(.success(SuperviseFixtures.listenSeat))
        let engines = media.engines.count
        model.listen()
        media.performStart()
        await waitUntil(state: "\(media.log)") {
            self.media.engines.count > engines && self.media.log.last == "connect wss://sfu.example.test listen.jwt"
        }
        media.engine(.listen, .connected)
        await waitUntil(state: "\(model.state.phase)") { model.state.phase == .listening }
    }

    private func assertSupervise(
        _ model: SuperviseModel,
        role: WorkspaceRole? = .agency,
        devices: [Device] = [.iPhone],
        testName: String = #function,
        line: UInt = #line
    ) async throws {
        try await assertScreen(devices: devices, testName: testName, line: line) { container in
            container.callStack.supervisor = model
            return SuperviseView(
                container: container,
                workspaceId: SuperviseFixtures.workspaceId,
                role: role,
                callId: SuperviseFixtures.callId
            )
        }
    }

    // MARK: - Before Listen

    /// An agency member on a call the receptionist is answering: Listen offered.
    func testBeforeListen() async throws {
        try await assertSupervise(makeModel(), devices: Device.allCases)
    }

    /// A colleague's own softphone call: no receptionist to write a note to.
    func testReceptionistNotOnCall() async throws {
        try await assertSupervise(makeModel(receptionistOnCall: false))
    }

    /// A viewer: the call is shown, nothing to press.
    func testViewer() async throws {
        try await assertSupervise(makeModel(role: .viewer), role: .viewer)
    }

    /// Listen while this device is on another call: the refusal, said in words.
    func testRefusedBusyWithCall() async throws {
        media.hasLiveCall = true
        let model = try makeModel()
        model.listen()
        XCTAssertEqual(model.startRefusal, SuperviseCopy.busyWithCall)
        try await assertSupervise(model)
    }

    // MARK: - Under way

    /// Listening: the listen-only leg, Take over, and the note to the receptionist.
    func testListening() async throws {
        let model = try makeModel()
        await listen(model)
        try await assertSupervise(model, devices: Device.allCases)
    }

    /// Holding the call after a takeover: the microphone live, no note.
    func testTakenOver() async throws {
        let model = try makeModel()
        await listen(model)
        server.answerTakeover(.success(SuperviseFixtures.coachSeat))
        await model.takeOver()
        media.engine(.takeover, .connected)
        await waitUntil(state: "\(model.state.phase)") { model.state.phase == .takenOver }
        try await assertSupervise(model)
    }

    /// A takeover the service refused: still listening, with the refusal's sentence.
    func testTakeOverRefused() async throws {
        let model = try makeModel()
        await listen(model)
        server.answerTakeover(.failure(.http(status: 429, message: nil, code: "rate_limited")))
        await model.takeOver()
        XCTAssertEqual(model.state.phase, .listening)
        try await assertSupervise(model)
    }

    // MARK: - Over

    /// A row that had already ended when it was opened: "The call has ended.", never Listen.
    func testAlreadyOver() async throws {
        let model = try makeModel(status: "completed")
        XCTAssertEqual(model.state.phase, .over)
        try await assertSupervise(model)
    }
}
