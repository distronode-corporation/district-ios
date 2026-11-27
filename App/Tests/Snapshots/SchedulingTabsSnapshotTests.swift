@testable import DistrictAI
import DistrictModel
import SwiftUI
import XCTest

/// The scheduling settings and developer screens opened on each of their tabs, as a client
/// and as a viewer, and with the tab's read refused.
///
/// ⚠️ ONLY THE OPEN TAB READS, so each drawing answers the reads of the tab it opens on
/// and nothing else (the harness fails a request nobody stubbed).
final class SchedulingTabsSnapshotTests: SchedulingWriteSnapshotCase {
    // MARK: - Settings

    /// ⛔ BRANDING IS `client`-LEVEL: a viewer sees it and is offered no edit.
    func testSettingsBookingPageAsViewer() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            SchedulingSettingsView(container: container, workspaceId: Self.workspace, role: .viewer)
        }
    }

    func testSettingsBookingPageRefused() async throws {
        try await assertScreen(["op:settings.branding.get": .refused], devices: [.iPhone]) { container in
            SchedulingSettingsView(container: container, workspaceId: Self.workspace, role: .client)
        }
    }

    // MARK: - Developer

    func testDeveloperKeysAsViewer() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            SchedulingDeveloperView(container: container, workspaceId: Self.workspace, role: .viewer)
        }
    }

    func testDeveloperKeysEmpty() async throws {
        try await assertScreen(["op:apiKeys.list": .noItems], devices: [.iPhone]) { container in
            SchedulingDeveloperView(container: container, workspaceId: Self.workspace, role: .client)
        }
    }

    func testDeveloperKeysRefused() async throws {
        try await assertScreen(["op:apiKeys.list": .refused], devices: [.iPhone]) { container in
            SchedulingDeveloperView(container: container, workspaceId: Self.workspace, role: .client)
        }
    }
}
