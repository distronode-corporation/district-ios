@testable import DistrictAI
import Foundation
import SwiftUI
import XCTest

/// The account screens: Account (with the per-workspace availability row in each of its
/// shapes) and the signed-in devices, drawn from the service's recorded responses.
///
/// ⚠️ THE SELECTED WORKSPACE IS PINNED PER TEST through the selection store's own key, so a
/// choice another test left in the standard defaults cannot decide which row is drawn.
///
/// ⚠️ THE ACCOUNT SCREEN'S FOOTER CARRIES THE APP'S VERSION, so its references are recorded
/// again when `MARKETING_VERSION` moves.
final class AccountScreenSnapshotTests: ScreenSnapshotTestCase {
    private static let availabilityPath = "/api/district/workspace/availability"
    private static let devicesPath = "/api/auth/native/devices"

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: WorkspaceSelectionStore.defaultsKey)
        try await super.tearDown()
    }

    private func select(_ workspaceId: String?) {
        WorkspaceSelectionStore().setSelectedWorkspaceId(workspaceId)
    }

    private func assertAccount(
        _ replies: [String: FixtureTransport.Reply],
        devices: [Device] = Device.allCases,
        testName: String = #function,
        line: UInt = #line
    ) async throws {
        try await assertScreen(replies, devices: devices, testName: testName, line: line) { container in
            let push = PushRegistrar(container: container)
            return AccountView(
                container: container,
                session: SessionModel(container: container, push: push),
                push: push
            )
        }
    }

    // MARK: - Account

    /// A client in Bravo Client who may be rung: the switch, on.
    func testAccountAvailable() async throws {
        select("ws-contract-client")
        try await assertAccount([
            Self.availabilityPath: .json(#"{"success":true,"availableForCalls":true,"reason":null}"#),
        ])
    }

    /// A viewer (the list's default workspace): no switch, the sentence that says why.
    func testAccountViewerCannotBeRung() async throws {
        select(nil)
        try await assertAccount([
            Self.availabilityPath: .json(#"{"success":true,"availableForCalls":false,"reason":"role"}"#),
        ], devices: [.iPhone])
    }

    /// A member with no membership row: the other sentence, the one an administrator can fix.
    func testAccountNoMemberRow() async throws {
        select("ws-contract-client")
        try await assertAccount([
            Self.availabilityPath: .json(#"{"success":true,"availableForCalls":false,"reason":"no_member_row"}"#),
        ], devices: [.iPhone])
    }

    /// The availability read refused: the failure held inside its card, the rest of the screen up.
    func testAccountAvailabilityFailed() async throws {
        select("ws-contract-client")
        try await assertAccount([
            Self.availabilityPath: .json(#"{"error":"Something went wrong."}"#, status: 500),
        ], devices: [.iPhone])
    }

    /// No workspace resolves: the availability card is absent, sign-out and deletion remain.
    func testAccountNoWorkspace() async throws {
        select(nil)
        try await assertAccount([
            "/api/district/workspace/list": ShellSnapshotTests.emptyList(inactive: 0),
        ], devices: [.iPhone])
    }

    // MARK: - Devices

    /// The recorded two installs: a named Pixel and an unnamed iPhone that has never been used.
    func testDevices() async throws {
        try await assertScreen([Self.devicesPath: .fixture("district-devices")]) { container in
            let push = PushRegistrar(container: container)
            return DevicesView(container: container, session: SessionModel(container: container, push: push))
        }
    }

    /// No other install signed in.
    func testDevicesEmpty() async throws {
        try await assertScreen(
            [Self.devicesPath: .json(#"{"success":true,"devices":[]}"#)],
            devices: [.iPhone]
        ) { container in
            let push = PushRegistrar(container: container)
            return DevicesView(container: container, session: SessionModel(container: container, push: push))
        }
    }

    /// The list could not be read: the failure and Retry.
    func testDevicesFailed() async throws {
        try await assertScreen(
            [Self.devicesPath: .json(#"{"error":"Something went wrong."}"#, status: 500)],
            devices: [.iPhone]
        ) { container in
            let push = PushRegistrar(container: container)
            return DevicesView(container: container, session: SessionModel(container: container, push: push))
        }
    }
}
