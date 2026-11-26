@testable import DistrictAI
import Foundation
import SwiftUI
import XCTest

/// The signed-in shell from the top: ``RootView`` resolving the session, then the tab bar on a
/// phone and the split view on an iPad (``ShellView`` picks by size class), over the recorded
/// workspace list; and the workspace picker and header the shell opens with.
///
/// ⚠️ THE SELECTED WORKSPACE IS PINNED PER TEST through the selection store's own key, so a
/// choice another test left in the standard defaults cannot decide which tenant is drawn.
final class ShellSnapshotTests: ScreenSnapshotTestCase {
    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: WorkspaceSelectionStore.defaultsKey)
        try await super.tearDown()
    }

    /// The list's shape with no workspace in it, and `inactive` lapsed ones.
    static func emptyList(inactive: Int) -> FixtureTransport.Reply {
        .json(
            #"{"success":true,"workspaces":[],"total":0,"limit":100,"offset":0,"degradedRegions":[],"#
                + #""inactiveCount":\#(inactive)}"#
        )
    }

    /// The recorded degraded answer, at the status the service sends it with.
    static var degraded: FixtureTransport.Reply {
        FixtureTransport.Reply(status: 503, body: FixtureTransport.fixtureData("district-workspace-list-degraded"))
    }

    private func select(_ workspaceId: String?) {
        WorkspaceSelectionStore().setSelectedWorkspaceId(workspaceId)
    }

    private func assertRoot(
        _ replies: [String: FixtureTransport.Reply] = [:],
        devices: [Device] = Device.allCases,
        testName: String = #function,
        line: UInt = #line
    ) async throws {
        try await assertScreen(replies, devices: devices, testName: testName, line: line) { container in
            RootView(
                container: container,
                push: PushRegistrar(container: container),
                incoming: IncomingCallModel(container: container)
            )
        }
    }

    // MARK: - The shell

    /// No workspace at all: the shell's empty state rather than a tab bar over nothing.
    func testShellNoWorkspace() async throws {
        select(nil)
        try await assertRoot([
            "/api/district/workspace/list": Self.emptyList(inactive: 0),
        ], devices: [.iPhone])
    }

    /// Every workspace lapsed: the plan sentence, not an empty list.
    func testShellLapsed() async throws {
        select(nil)
        try await assertRoot([
            "/api/district/workspace/list": Self.emptyList(inactive: 2),
        ], devices: [.iPhone])
    }

    /// The recorded 503 `REGIONS_DEGRADED`: two regions unreachable, said as such rather than as no
    /// workspaces.
    func testShellDegraded() async throws {
        select(nil)
        try await assertRoot(
            ["/api/district/workspace/list": Self.degraded],
            devices: [.iPhone]
        )
    }

    /// The list could not be read.
    func testShellListFailed() async throws {
        select(nil)
        try await assertRoot(
            ["/api/district/workspace/list": .json(#"{"error":"Something went wrong."}"#, status: 500)],
            devices: [.iPhone]
        )
    }

    // MARK: - The workspace picker

    /// The recorded three workspaces, the selected one marked.
    func testWorkspacePicker() async throws {
        select(nil)
        let model = try await loadedWorkspaces(FixtureTransport())
        try await assertScreen(devices: [.iPhone]) { _ in WorkspacePickerSheet(workspaceSession: model) }
    }

    /// The recorded partial list: what was read, and which regions could not be.
    func testWorkspacePickerPartial() async throws {
        select(nil)
        let model = try await loadedWorkspaces(FixtureTransport([
            "/api/district/workspace/list": .fixture("district-workspace-list-partial"),
        ]))
        try await assertScreen(devices: [.iPhone]) { _ in WorkspacePickerSheet(workspaceSession: model) }
    }

    private func loadedWorkspaces(_ transport: FixtureTransport) async throws -> WorkspaceSessionModel {
        let model = try await WorkspaceSessionModel(container: container(transport))
        await model.load()
        XCTAssertNotNil(model.selectedEntry)
        XCTAssertEqual(transport.unanswered, [])
        return model
    }

    // MARK: - The workspace header

    /// A workspace that may be edited, with the switcher.
    func testWorkspaceHeader() async throws {
        try await assertScreen(devices: [.iPhone]) { _ in
            VStack {
                WorkspaceHeader(name: "Bravo Client", region: "ca", isReadOnly: false, canSwitch: true, onSwitch: {})
                Spacer()
            }
            .padding()
        }
    }

    /// Read only, the only workspace (no switcher), in a region the registry does not name.
    func testWorkspaceHeaderReadOnly() async throws {
        try await assertScreen(devices: [.iPhone]) { _ in
            VStack {
                WorkspaceHeader(name: "Alpha Client", region: "zz", isReadOnly: true, canSwitch: false, onSwitch: {})
                PartialWorkspacesCaption(regions: ["eu", "apac"])
                Spacer()
            }
            .padding()
        }
    }
}
