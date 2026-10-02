@testable import DistrictAI
import XCTest

/// A meeting's microphone and camera controls.
///
/// ⛔ THE BUG THIS PINS: "Start video" then "Stop video" in quick succession both read
/// the camera as off and both asked for ON, so the camera stayed published.
final class RoomMediaToggleTests: XCTestCase {
    func testASecondChangeWhileOneIsInFlightIsRefused() {
        var camera = RoomMediaToggle()

        let first = camera.begin()
        let second = camera.begin()

        XCTAssertEqual(first, true, "the first tap asks for ON")
        XCTAssertNil(second, "the second tap must not also ask for ON")
        XCTAssertTrue(camera.inFlight)
    }

    func testAnAcceptedChangeLandsAndUnlocksTheControl() {
        var camera = RoomMediaToggle()
        let target = camera.begin()

        camera.finish(requested: true, accepted: true)

        XCTAssertEqual(target, true)
        XCTAssertTrue(camera.isOn)
        XCTAssertFalse(camera.inFlight)
        XCTAssertFalse(camera.failed)
        XCTAssertEqual(camera.begin(), false, "the next tap asks for OFF")
    }

    /// ⛔ A REFUSAL IS SHOWN, and the state is what the SDK accepted.
    func testARefusedChangeIsReportedAndKeepsTheTrueState() {
        var microphone = RoomMediaToggle()
        _ = microphone.begin()

        microphone.finish(requested: true, accepted: false)

        XCTAssertFalse(microphone.isOn)
        XCTAssertTrue(microphone.failed)
        XCTAssertFalse(microphone.inFlight)
    }

    func testTheNextChangeThatLandsClearsTheRefusal() {
        var microphone = RoomMediaToggle()
        _ = microphone.begin()
        microphone.finish(requested: true, accepted: false)

        _ = microphone.begin()
        microphone.finish(requested: true, accepted: true)

        XCTAssertFalse(microphone.failed)
        XCTAssertTrue(microphone.isOn)
    }

    func testAnSDKReportMovesTheStateWithoutTouchingTheLock() {
        var camera = RoomMediaToggle()
        _ = camera.begin()

        camera.observe(true)

        XCTAssertTrue(camera.isOn)
        XCTAssertTrue(camera.inFlight)
    }
}
