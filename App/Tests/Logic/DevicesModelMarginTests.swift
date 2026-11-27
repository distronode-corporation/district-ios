@testable import DistrictAI
import DistrictModel
import XCTest

/// ``DevicesModel`` over a real container: the read and its failure, a revoke of another device
/// and of this one, the `revoked: 0` notice, a refused write that keeps the rows, revoking all,
/// and the second tap that is dropped while a write is in flight.
final class DevicesModelMarginTests: ScreenSnapshotTestCase {
    private static let listPath = "/api/auth/native/devices"
    private static let revokePath = "/api/auth/native/devices/revoke"
    private static let revokeAllPath = "/api/auth/native/revoke-all"
    private static let refused = #"{"error":"Internal error"}"#

    private func model(
        _ replies: [String: FixtureTransport.Reply],
        sequences: [String: [FixtureTransport.Reply]] = [:]
    ) async throws -> (DevicesModel, FixtureTransport) {
        var all = replies
        if all[Self.listPath] == nil, sequences[Self.listPath] == nil {
            all[Self.listPath] = .fixture("district-devices")
        }
        let transport = FixtureTransport(all, sequences: sequences)
        return try await (DevicesModel(container: container(transport)), transport)
    }

    private func rows(_ model: DevicesModel) -> [DeviceSession]? {
        guard case let .ready(rows) = model.list else { return nil }
        return rows
    }

    func testTheReadListsTheRecordedDevices() async throws {
        let (model, transport) = try await model([:])
        await model.load()
        XCTAssertEqual(rows(model)?.map(\.deviceId), ["device-contract-android-1", "device-contract-ios-2"])
        XCTAssertFalse(model.busy)
        XCTAssertNil(model.mutationFailure)
        XCTAssertEqual(transport.unanswered, [])
    }

    /// ⛔ A failed read is a failure, never an empty list.
    func testAFailedReadIsAFailureNotAnEmptyList() async throws {
        let (model, _) = try await model([Self.listPath: .json(Self.refused, status: 500)])
        await model.load()
        guard case .failed = model.list else { return XCTFail("expected a failure, got \(model.list)") }
    }

    /// An empty list on a good session is a ready state, not a failure.
    func testAnEmptyListIsReady() async throws {
        let (model, _) = try await model([Self.listPath: .json(#"{"success":true,"devices":[]}"#)])
        await model.load()
        XCTAssertEqual(rows(model)?.count, 0)
    }

    /// A body that claims no success is refused by the envelope, not drawn as rows.
    func testASuccessFalseBodyIsAFailure() async throws {
        let (model, _) = try await model([Self.listPath: .json(#"{"success":false,"devices":[]}"#)])
        await model.load()
        guard case .failed = model.list else { return XCTFail("expected a failure, got \(model.list)") }
    }

    /// Revoking another device keeps this session and re-reads the list without blanking it.
    func testRevokingAnotherDeviceRereadsAndKeepsTheSession() async throws {
        let afterRevoke = #"{"success":true,"devices":[{"deviceId":"device-contract-ios-2","deviceName":null,"#
            + #""platform":"ios","lastUsedAt":null,"createdAt":"2026-08-01T09:00:00.000Z"}]}"#
        let (model, transport) = try await model(
            [Self.revokePath: .fixture("district-device-revoke")],
            sequences: [Self.listPath: [.fixture("district-devices"), .json(afterRevoke)]]
        )
        await model.load()
        let signsOut = await model.revoke(deviceId: "device-contract-android-1")
        XCTAssertFalse(signsOut)
        XCTAssertFalse(model.nothingRevoked)
        XCTAssertFalse(model.busy)
        XCTAssertEqual(rows(model)?.map(\.deviceId), ["device-contract-ios-2"])
        XCTAssertEqual(transport.requested.filter { $0 == "GET \(Self.listPath)" }.count, 2)
    }

    /// ⛔ `revoked: 0` for another device is a notice, not a failure, and the list is re-read.
    func testNothingRevokedForAnotherDeviceIsANotice() async throws {
        let (model, transport) = try await model([Self.revokePath: .json(#"{"success":true,"revoked":0}"#)])
        await model.load()
        let signsOut = await model.revoke(deviceId: "device-not-on-this-account")
        XCTAssertFalse(signsOut)
        XCTAssertTrue(model.nothingRevoked)
        XCTAssertNil(model.mutationFailure)
        XCTAssertEqual(transport.requested.filter { $0 == "GET \(Self.listPath)" }.count, 2)
        model.dismissNotices()
        XCTAssertFalse(model.nothingRevoked)
    }

    /// ⛔ Revoking THIS device demands the sign-out even on `revoked: 0`, raises no notice and
    /// does not re-read a list that is about to go away.
    func testRevokingThisDeviceSignsOutEvenOnAZeroCount() async throws {
        let (model, transport) = try await model([Self.revokePath: .json(#"{"success":true,"revoked":0}"#)])
        await model.load()
        let signsOut = await model.revoke(deviceId: model.thisDeviceId)
        XCTAssertTrue(signsOut)
        XCTAssertFalse(model.nothingRevoked)
        XCTAssertFalse(model.busy)
        XCTAssertEqual(transport.requested.filter { $0 == "GET \(Self.listPath)" }.count, 1)
    }

    /// A refused revoke keeps the rows on screen and says why beside them.
    func testARefusedRevokeKeepsTheRows() async throws {
        let (model, _) = try await model([Self.revokePath: .json(Self.refused, status: 500)])
        await model.load()
        let signsOut = await model.revoke(deviceId: "device-contract-android-1")
        XCTAssertFalse(signsOut)
        XCTAssertNotNil(model.mutationFailure)
        XCTAssertFalse(model.busy)
        XCTAssertEqual(rows(model)?.count, 2)
        model.dismissNotices()
        XCTAssertNil(model.mutationFailure)
    }

    /// ⛔ Revoking all signs this device out on success, whatever the count.
    func testRevokeAllSignsOutOnSuccess() async throws {
        let (model, transport) = try await model([Self.revokeAllPath: .json(#"{"success":true,"revoked":0}"#)])
        await model.load()
        let signsOut = await model.revokeAll()
        XCTAssertTrue(signsOut)
        XCTAssertFalse(model.nothingRevoked)
        XCTAssertTrue(transport.requested.contains("POST \(Self.revokeAllPath)"))
    }

    func testARefusedRevokeAllKeepsTheSessionAndTheRows() async throws {
        let (model, _) = try await model([Self.revokeAllPath: .json(Self.refused, status: 500)])
        await model.load()
        let signsOut = await model.revokeAll()
        XCTAssertFalse(signsOut)
        XCTAssertNotNil(model.mutationFailure)
        XCTAssertEqual(rows(model)?.count, 2)
    }

    /// ⛔ A second write while one is in flight is dropped, not queued.
    func testASecondWriteWhileBusyIsDropped() async throws {
        let (model, transport) = try await model([Self.revokePath: .fixture("district-device-revoke")])
        await model.load()
        // The first revoke is held in flight until both overlapping calls have returned.
        transport.hold("POST \(Self.revokePath)")
        let first = Task { await model.revoke(deviceId: "device-contract-android-1") }
        await transport.waitUntilHeld("POST \(Self.revokePath)")
        XCTAssertTrue(model.busy)
        let droppedAll = await model.revokeAll()
        let droppedOne = await model.revoke(deviceId: "device-contract-ios-2")
        XCTAssertFalse(droppedAll)
        XCTAssertFalse(droppedOne)
        transport.release("POST \(Self.revokePath)")
        _ = await first.value
        XCTAssertFalse(model.busy)
        XCTAssertFalse(transport.requested.contains("POST \(Self.revokeAllPath)"))
        XCTAssertEqual(transport.requested.filter { $0 == "POST \(Self.revokePath)" }.count, 1)
    }
}
