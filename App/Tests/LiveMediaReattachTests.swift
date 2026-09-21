@testable import DistrictAI
import DistrictNetwork
import Foundation
import XCTest

/// A screen rebuilt around a live call or meeting finds the model that owns it.
///
/// ⛔ ON REGULAR WIDTH THE DIAL AND ROOM SCREENS ARE DESTROYED BY ORDINARY NAVIGATION: a
/// different sidebar section, or a rotation that swaps the tab bar for the sidebar. The
/// call or meeting goes on (``CallStack`` holds it), so a screen that came back with a
/// fresh model would draw a keypad or a Join button over it, with no way to hang up.
///
/// ⚠️ EVERY CONTAINER POINTS AT `https://calls.invalid`, and the dial uses a DENIED
/// microphone, so the attempt is refused before CallKit or the network is asked. See
/// ``MicrophoneAccessTests``, which this borrows both from.
@MainActor
final class LiveMediaReattachTests: XCTestCase {
    private let unreachable = URL(string: "https://calls.invalid")!

    // MARK: - The dialler

    func test_IOS_REATTACH_01_aDiallerIsFoundOnlyWhileItHasACallForThatWorkspace() async {
        let container = AppContainer(baseURL: unreachable, microphone: FakeMicrophoneAccess(status: .denied))
        let model = DialerModel(container: container, workspaceId: "ws_1", role: .agency)
        model.onEntryChange("+14165550100")
        XCTAssertNil(container.callStack.softphone, "an idle keypad is never registered")
        XCTAssertNil(DialerModel.attached(to: container.callStack, workspaceId: "ws_1"))

        model.placeCall()
        XCTAssertTrue(model.placing, "the fixture must reach the placing state or this proves nothing")
        XCTAssertTrue(container.callStack.softphone === model, "the dial registers the model that owns it")
        XCTAssertTrue(DialerModel.attached(to: container.callStack, workspaceId: "ws_1") === model)
        XCTAssertNil(DialerModel.attached(to: container.callStack, workspaceId: "ws_2"), "another tenant")

        await waitUntil { !model.placing }
        XCTAssertNil(model.call)
        XCTAssertNil(DialerModel.attached(to: container.callStack, workspaceId: "ws_1"), "a refused dial")
    }

    /// ⚠️ WEAK, SO A MODEL NOTHING ELSE HOLDS IS NOT KEPT ALIVE BY THE LOOKUP SLOT.
    func test_IOS_REATTACH_02_theSlotDoesNotKeepADiallerAlive() {
        let container = AppContainer(baseURL: unreachable)
        var model: DialerModel? = DialerModel(container: container, workspaceId: "ws_1", role: .agency)
        container.callStack.softphone = model
        model = nil
        XCTAssertNil(container.callStack.softphone)
    }

    // MARK: - The room

    func test_IOS_REATTACH_03_aRoomIsFoundByItsNameWhileItHoldsTheClaim() throws {
        let container = AppContainer(baseURL: unreachable)
        let name = try XCTUnwrap(RoomName(joining: "meet_ws_1_standup"))
        let other = try XCTUnwrap(RoomName(joining: "meet_ws_1_review"))
        let model = ActiveRoomModel(container: container, roomName: name, role: .agency)
        XCTAssertNil(ActiveRoomModel.attached(to: container.callStack, roomName: name), "no claim yet")

        container.callStack.claimRoom(model)
        XCTAssertTrue(ActiveRoomModel.attached(to: container.callStack, roomName: name) === model)
        XCTAssertNil(ActiveRoomModel.attached(to: container.callStack, roomName: other), "another room")

        container.callStack.releaseRoom(model)
        XCTAssertNil(ActiveRoomModel.attached(to: container.callStack, roomName: name), "a released room")
    }

    // MARK: - Support

    /// ⚠️ A BOUNDED POLL, as ``MicrophoneAccessTests`` uses: the model's work runs in tasks
    /// it owns and exposes no completion to await.
    private func waitUntil(
        timeout seconds: Double = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out after \(seconds)s", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}
