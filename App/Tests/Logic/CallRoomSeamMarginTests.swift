@testable import DistrictAI
import DistrictCall
import Foundation
import XCTest

/// The parts of the call seams that hold no LiveKit room and no CallKit transaction: the
/// latch an engine waits on before reporting the microphone, a room's default answer for who
/// is present, and the supervision claim ``CallStackSuperviseMedia`` puts on the stack.
@MainActor
final class CallRoomSeamMarginTests: XCTestCase {
    // MARK: - ConnectedLatch

    func testAWaitOnAnOpenLatchReturnsAtOnce() async {
        let latch = ConnectedLatch()
        latch.open()
        await latch.wait()
        await latch.wait()
    }

    /// ⚠️ Every waiter is released by the one open, whatever order they arrived in.
    func testOneOpenReleasesEveryWaiter() async throws {
        let latch = ConnectedLatch()
        let released = LatchCount()
        let waiters = (0 ..< 3).map { _ in
            Task {
                await latch.wait()
                released.bump()
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(released.value, 0, "nothing passes a closed latch")

        latch.open()
        for waiter in waiters {
            await waiter.value
        }
        XCTAssertEqual(released.value, 3)
    }

    /// Opening twice changes nothing, and a wait after the second open still returns.
    func testOpeningAgainIsHarmless() async {
        let latch = ConnectedLatch()
        latch.open()
        latch.open()
        await latch.wait()
    }

    // MARK: - CallRoom's default

    /// ⚠️ A room that cannot say who is present reports nobody.
    func testARoomThatCannotSayReportsNobody() {
        let room: any CallRoom = SilentCallRoom()
        XCTAssertEqual(room.presentParticipants(), [])
    }

    // MARK: - CallStackSuperviseMedia's claim

    private func makeStack(_ microphone: FakeMicrophoneAccess = FakeMicrophoneAccess(status: .granted)) -> CallStack {
        CallStack(microphone: microphone)
    }

    func testAClaimHoldsTheDeviceCallAndRoutesTheSystemsRequests() {
        let stack = makeStack()
        let media = CallStackSuperviseMedia(stack: stack)
        let owner = MarginSupervisor()
        let requests = StagedRequests()
        let uuid = UUID()
        XCTAssertFalse(media.hasLiveCall)

        media.claim(owner) { requests.all.append($0) }
        XCTAssertTrue(media.hasLiveCall, "a supervision holds the device's call")
        XCTAssertTrue(stack.supervisor === owner)

        stack.onSystemRequest?(.endRequested(uuid: uuid))
        stack.onSystemRequest?(.muteRequested(uuid: uuid, muted: true))
        XCTAssertEqual(requests.all, [.endRequested(uuid: uuid), .muteRequested(uuid: uuid, muted: true)])
    }

    /// ⛔ Only the owner's release gives the claim back.
    func testOnlyTheOwnersReleaseGivesTheClaimBack() {
        let stack = makeStack()
        let media = CallStackSuperviseMedia(stack: stack)
        let owner = MarginSupervisor()
        let stranger = MarginSupervisor()
        media.claim(owner) { _ in }

        media.release(stranger)
        XCTAssertTrue(media.hasLiveCall)
        XCTAssertTrue(stack.supervisor === owner)

        media.release(owner)
        XCTAssertFalse(media.hasLiveCall)
        XCTAssertNil(stack.supervisor)
        XCTAssertNil(stack.onSystemRequest)

        media.release(owner)
        XCTAssertFalse(media.hasLiveCall, "a second release is harmless")
    }

    func testTheRoomAndTheMicrophoneAreTheStacks() {
        let microphone = FakeMicrophoneAccess(status: .denied)
        let stack = makeStack(microphone)
        let media = CallStackSuperviseMedia(stack: stack)
        XCTAssertFalse(media.hasLiveRoom)
        XCTAssertEqual(media.microphone.status, .denied)

        let room = MarginRoom()
        stack.claimRoom(room)
        XCTAssertTrue(media.hasLiveRoom, "a meeting room on the stack is a room on the device")
        stack.releaseRoom(room)
        XCTAssertFalse(media.hasLiveRoom)
    }

    /// ⚠️ With no leg begun there is no engine: a command is dropped and an end is harmless.
    func testCommandsWithNoLegReachNothing() async {
        let stack = makeStack()
        let media = CallStackSuperviseMedia(stack: stack)
        await media.perform(.setMuted(true))
        await media.perform(.disconnect)
        media.endLeg()
        media.endLeg()
        XCTAssertFalse(media.hasLiveCall)
        XCTAssertFalse(media.hasLiveRoom)
    }
}

/// A room with no answer of its own for who is present.
private final class SilentCallRoom: CallRoom, @unchecked Sendable {
    func connect(url _: String, token _: String) async throws {}
    func setMicrophone(enabled _: Bool) async throws {}
    func disconnect() async {}
}

/// How many waiters passed the latch. ⚠️ `@unchecked Sendable`: the count is behind the lock.
private final class LatchCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func bump() {
        lock.withLock { count += 1 }
    }
}
