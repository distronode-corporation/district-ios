@testable import DistrictAI
import DistrictCall
import DistrictModel
import Foundation
import XCTest

/// ``DialerModel``'s guards for work that arrives with no call of its own, none of it reaching
/// CallKit: a start watchdog for an attempt this model never made, and a reducer event with no
/// session. ⚠️ Each must leave the keypad exactly as it was, and claim nothing on the stack.
final class DialerIdleMarginTests: ScreenSnapshotTestCase {
    private func model() async throws -> (DialerModel, AppContainer) {
        let container = try await container(FixtureTransport())
        return (DialerModel(container: container, workspaceId: "ws-contract-test", role: .agency), container)
    }

    /// ⛔ A watchdog for a start this model does not hold says nothing: a stranger's UUID must
    /// not put "the call did not start" over an idle keypad.
    func testAWatchdogForAnotherAttemptSaysNothing() async throws {
        let (model, container) = try await model()
        model.onEntryChange("+14165550100")
        let entry = model.entry
        XCTAssertFalse(entry.isEmpty)

        await model.abandonStart(uuid: UUID())
        await model.abandonStart(uuid: UUID(), because: DialerModel.busy)

        XCTAssertNil(model.refusal)
        XCTAssertFalse(model.placing)
        XCTAssertNil(model.call)
        XCTAssertFalse(container.callStack.hasLiveCall, "nothing claimed, nothing released")
        XCTAssertEqual(model.entry, entry, "the field is untouched")
    }

    /// ⚠️ An event with no session is dropped: no call appears, and no end is counted.
    func testAnEventWithNoSessionIsDropped() async throws {
        let (model, container) = try await model()
        for event: SoftphoneEvent in [.dialRequested, .hangUpPressed, .muteToggled, .dialRefused] {
            await model.apply(event)
        }
        XCTAssertNil(model.call)
        XCTAssertNil(model.refusal)
        XCTAssertFalse(model.endedByOperator)
        XCTAssertFalse(container.callStack.hasLiveCall)
    }
}
