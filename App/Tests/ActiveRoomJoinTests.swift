@testable import DistrictAI
import DistrictModel
import Foundation
import XCTest

/// A room join that is still reading its token when the room is left or yields its audio.
///
/// ⛔ THE STALE JOIN MUST NOT CONNECT. A telephone call that takes the audio while the
/// token read is in flight ends the join through ``CallStack/endRoom(_:)``; a join that
/// resumed anyway would build an engine, connect and publish the microphone into the
/// meeting while the call held the audio, with no claim left for anything to end.
///
/// ⚠️ THE TOKEN READ AND THE OS PROMPTS ARE STUBBED, so nothing reaches the network or
/// asks for a permission. The token parks until the test releases it, which is what
/// lets the leave or the yield land inside the await.
@MainActor
final class ActiveRoomJoinTests: XCTestCase {
    private let unreachable = URL(string: "https://calls.invalid")!

    func test_IOS_ROOMJOIN_01_aYieldDuringTheTokenReadEndsTheJoin() async throws {
        let container = AppContainer(baseURL: unreachable)
        let token = ParkedToken()
        let model = try makeModel(container: container, token: token)
        let credential = try Self.credential()

        let joining = Task { await model.join() }
        await token.waitUntilAsked()
        XCTAssertEqual(model.phase, .joining, "the fixture must park inside the join or this proves nothing")
        XCTAssertTrue(container.callStack.hasLiveRoom)

        await container.callStack.endRoom(.telephoneCall)
        await token.release(with: .success(credential))
        await joining.value

        XCTAssertEqual(model.phase, .yielded(.telephoneCall), "a stale join must not take the phase back")
        XCTAssertFalse(container.callStack.hasLiveRoom, "and must not hold the claim")
        XCTAssertFalse(model.microphone.isOn)
        XCTAssertFalse(model.microphone.inFlight)
    }

    func test_IOS_ROOMJOIN_02_aLeaveDuringTheTokenReadEndsTheJoin() async throws {
        let container = AppContainer(baseURL: unreachable)
        let token = ParkedToken()
        let model = try makeModel(container: container, token: token)
        let credential = try Self.credential()

        let joining = Task { await model.join() }
        await token.waitUntilAsked()

        await model.leave()
        await token.release(with: .success(credential))
        await joining.value

        XCTAssertEqual(model.phase, .left)
        XCTAssertFalse(container.callStack.hasLiveRoom)
        XCTAssertFalse(model.microphone.isOn)
        XCTAssertFalse(model.microphone.inFlight)
    }

    /// ⚠️ A FAILED READ THAT ARRIVES LATE IS NOT SHOWN EITHER: the screen is the yield's.
    func test_IOS_ROOMJOIN_03_aLateTokenFailureDoesNotOverwriteTheYield() async throws {
        let container = AppContainer(baseURL: unreachable)
        let token = ParkedToken()
        let model = try makeModel(container: container, token: token)

        let joining = Task { await model.join() }
        await token.waitUntilAsked()

        await container.callStack.endRoom(.telephoneCall)
        await token.release(with: .failure(.transport("offline")))
        await joining.value

        XCTAssertEqual(model.phase, .yielded(.telephoneCall))
        XCTAssertNil(model.joinFailure)
    }

    private func makeModel(container: AppContainer, token: ParkedToken) throws -> ActiveRoomModel {
        let name = try XCTUnwrap(RoomName(joining: "meet_ws_1_standup"))
        return ActiveRoomModel(
            container: container,
            roomName: name,
            role: .agency,
            seams: RoomJoinSeams(
                fetchToken: { _ in await token.read() },
                askPermissions: { RoomPermissions(requested: true, microphoneGranted: true, cameraGranted: true) }
            )
        )
    }

    private static func credential() throws -> RoomTokenResponse {
        let json = #"{"success":true,"token":"t","url":"wss://rooms.invalid"}"#
        return try JSONDecoder().decode(RoomTokenResponse.self, from: Data(json.utf8))
    }
}

/// A token read that parks until the test releases it.
private actor ParkedToken {
    private var parked: CheckedContinuation<Result<RoomTokenResponse, ApiError>, Never>?
    private var arrivalWaiter: CheckedContinuation<Void, Never>?
    private var arrived = false

    func read() async -> Result<RoomTokenResponse, ApiError> {
        arrived = true
        arrivalWaiter?.resume()
        arrivalWaiter = nil
        return await withCheckedContinuation { parked = $0 }
    }

    func waitUntilAsked() async {
        guard !arrived else { return }
        await withCheckedContinuation { arrivalWaiter = $0 }
    }

    func release(with outcome: Result<RoomTokenResponse, ApiError>) {
        parked?.resume(returning: outcome)
        parked = nil
    }
}
