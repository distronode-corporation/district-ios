@testable import DistrictAI
import DistrictCall
import DistrictModel
import Foundation
import XCTest

/// ``DialerModel``'s keypad half over a real container, none of it reaching CallKit: the role
/// gate, the recent callers read and its failure, and the two refusals (a call already owns
/// the bridge, a meeting room owns the audio) that must place nothing.
///
/// ⚠️ THE BUSY AND IN-ROOM STATES ARE SET ON THE CONTAINER'S OWN ``CallStack``: a claim on
/// ``CallStack/onSystemRequest`` is what ``CallStack/hasLiveCall`` reads, and
/// ``CallStack/claimRoom(_:)`` is what ``CallStack/hasLiveRoom`` reads. Both are dropped in
/// each test, so no claim outlives it.
final class DialerModelMarginTests: ScreenSnapshotTestCase {
    private static let callsPath = "/api/district/calls"
    private let dialable = "+14165550100"

    private func model(
        _ replies: [String: FixtureTransport.Reply] = [:],
        role: WorkspaceRole? = .agency
    ) async throws -> (DialerModel, AppContainer) {
        let container = try await container(FixtureTransport(replies))
        return (DialerModel(container: container, workspaceId: "ws-contract-test", role: role), container)
    }

    // MARK: - The role gate

    /// A viewer, and a role the wire did not recognise, may not spend the workspace's minutes:
    /// a dialable number still lights nothing, and a press only says the length.
    func testAViewerAndAnUnknownRoleCannotDial() async throws {
        for role in [WorkspaceRole.viewer, nil] {
            let (model, container) = try await model(role: role)
            model.onEntryChange(dialable)
            XCTAssertNotNil(model.destination.e164, "the fixture number must be dialable or this proves nothing")
            XCTAssertFalse(model.canDial)
            XCTAssertFalse(model.canPlaceCall)
            model.placeCall()
            XCTAssertTrue(model.lengthChecked, "a refused press says a wrong length, as leaving the field does")
            XCTAssertFalse(model.placing)
            XCTAssertNil(model.call)
            XCTAssertFalse(container.callStack.hasLiveCall, "a refused press must not claim the call stack")
        }
    }

    /// An incomplete number is refused before any claim, and the press checks its length.
    func testAnIncompleteNumberIsRefusedAndItsLengthChecked() async throws {
        let (model, container) = try await model()
        model.onEntryChange("+1416")
        XCTAssertFalse(model.canPlaceCall)
        model.placeCall()
        XCTAssertTrue(model.lengthChecked)
        XCTAssertNil(model.refusal)
        XCTAssertFalse(container.callStack.hasLiveCall)

        model.onEntryChange("+14165")
        XCTAssertFalse(model.lengthChecked, "an edit clears the length check")
    }

    // MARK: - One call, one audio owner

    /// A call already holding the bridge (here, any claim on it) refuses the press with the
    /// busy sentence, places nothing, and leaves the other owner's claim in place.
    func testALiveCallRefusesTheDialAndKeepsTheOtherClaim() async throws {
        let (model, container) = try await model()
        var reached: [CallKitRequest] = []
        container.callStack.onSystemRequest = { reached.append($0) }
        defer { container.callStack.onSystemRequest = nil }
        model.onEntryChange(dialable)
        XCTAssertTrue(model.canPlaceCall)

        model.placeCall()
        XCTAssertEqual(model.refusal?.message, DialerModel.busy.message)
        XCTAssertFalse(model.placing)
        XCTAssertNil(model.call)
        XCTAssertTrue(container.callStack.hasLiveCall, "the other call's claim must survive the refusal")
        XCTAssertNil(container.callStack.softphone, "a refused dialer must not register itself")
        XCTAssertTrue(reached.isEmpty)

        model.onEntryChange("+14165550101")
        XCTAssertNil(model.refusal, "the sentence is about a number the operator has moved on from")
    }

    /// A live meeting room refuses the press with the room sentence, and the room is not ended.
    func testALiveRoomRefusesTheDialAndIsNotEnded() async throws {
        let (model, container) = try await model()
        let room = MarginRoom()
        container.callStack.claimRoom(room)
        defer { container.callStack.releaseRoom(room) }
        model.onEntryChange(dialable)

        model.placeCall()
        XCTAssertEqual(model.refusal?.message, DialerModel.inRoom.message)
        XCTAssertFalse(model.placing)
        XCTAssertFalse(container.callStack.hasLiveCall, "a refusal claims nothing")
        XCTAssertTrue(container.callStack.hasLiveRoom)
        XCTAssertTrue(room.yields.isEmpty, "the operator is told to leave; the room is not taken from them")
    }

    // MARK: - Recent callers

    /// Only inbound rows with a callable number are offered: the recorded feed has five rows,
    /// two of them outbound.
    func testRecentCallersAreTheInboundRowsOnly() async throws {
        let (model, _) = try await model()
        guard case .loading = model.callbacks else { return XCTFail("expected loading before the read") }
        await model.loadCallbacks()
        guard case let .ready(rows) = model.callbacks else {
            return XCTFail("expected rows, got \(model.callbacks)")
        }
        XCTAssertEqual(rows.map(\.id), ["call_contract_answered", "call_contract_missed", "call_contract_busy"])
    }

    /// An empty feed is "nobody called", a legitimate answer, not a failure.
    func testAnEmptyFeedIsReadyWithNoRows() async throws {
        let (model, _) = try await model([Self.callsPath: .json("[]")])
        await model.loadCallbacks()
        guard case let .ready(rows) = model.callbacks else {
            return XCTFail("expected an empty list, got \(model.callbacks)")
        }
        XCTAssertTrue(rows.isEmpty)
    }

    /// A failed read is a failure, never an empty list, and it does not disable the keypad.
    func testAFailedReadIsAFailureAndTheKeypadStillWorks() async throws {
        let (model, _) = try await model([Self.callsPath: .json(#"{"error":"Internal error"}"#, status: 500)])
        await model.loadCallbacks()
        guard case let .failed(text) = model.callbacks else {
            return XCTFail("expected a failure, got \(model.callbacks)")
        }
        XCTAssertFalse(text.message.isEmpty)
        XCTAssertNil(model.refusal, "a failed read writes no refusal")
        model.onEntryChange(dialable)
        XCTAssertTrue(model.canPlaceCall)
    }

    /// A body that is not the feed's shape is a failure too, not rows.
    func testAMalformedFeedIsAFailure() async throws {
        let (model, _) = try await model([Self.callsPath: .json(#"{"calls":[]}"#)])
        await model.loadCallbacks()
        guard case .failed = model.callbacks else { return XCTFail("expected a failure, got \(model.callbacks)") }
    }

    // MARK: - Teardown paths with no call

    /// With no call, hang-up, mute and dismiss do nothing and claim nothing.
    func testTheCallControlsAreInertWithNoCall() async throws {
        let (model, container) = try await model()
        await model.hangUp()
        model.toggleMute()
        model.dismissEndedCall()
        model.reportEnded()
        XCTAssertFalse(model.endedByOperator, "no call means nobody hung one up")
        XCTAssertNil(model.call)
        XCTAssertFalse(container.callStack.hasLiveCall)
    }
}
