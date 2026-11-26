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

    func testSettingsAssistant() async throws {
        try await assertScreen { container in
            SchedulingSettingsView(container: container, workspaceId: Self.workspace, role: .client, tab: "assistant")
        }
    }

    func testSettingsAssistantAsViewer() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            SchedulingSettingsView(container: container, workspaceId: Self.workspace, role: .viewer, tab: "assistant")
        }
    }

    /// The assistant switched off with no instructions of its own.
    func testSettingsAssistantOff() async throws {
        let off = FixtureTransport.Reply.json(#"{"ok":true,"data":{"enabled":false,"extra_instructions":""}}"#)
        try await assertScreen(["op:settings.llm.get": off], devices: [.iPhone]) { container in
            SchedulingSettingsView(container: container, workspaceId: Self.workspace, role: .client, tab: "assistant")
        }
    }

    func testSettingsAssistantRefused() async throws {
        try await assertScreen(["op:settings.llm.get": .notReady], devices: [.iPhone]) { container in
            SchedulingSettingsView(container: container, workspaceId: Self.workspace, role: .client, tab: "assistant")
        }
    }

    func testSettingsProfile() async throws {
        try await assertScreen { container in
            SchedulingSettingsView(container: container, workspaceId: Self.workspace, role: .client, tab: "profile")
        }
    }

    /// ⛔ THE PROFILE IS `viewer`-LEVEL: a viewer may still set their own timezone.
    func testSettingsProfileAsViewer() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            SchedulingSettingsView(container: container, workspaceId: Self.workspace, role: .viewer, tab: "profile")
        }
    }

    func testSettingsProfileRefused() async throws {
        try await assertScreen(["op:me.get": .refused], devices: [.iPhone]) { container in
            SchedulingSettingsView(container: container, workspaceId: Self.workspace, role: .client, tab: "profile")
        }
    }

    func testSettingsNotifications() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            SchedulingSettingsView(
                container: container,
                workspaceId: Self.workspace,
                role: .client,
                tab: "notifications"
            )
        }
    }

    func testSettingsNotificationsRefused() async throws {
        try await assertScreen(["op:me.get": .notReady], devices: [.iPhone], locales: [.en]) { container in
            SchedulingSettingsView(
                container: container,
                workspaceId: Self.workspace,
                role: .client,
                tab: "notifications"
            )
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

    func testDeveloperApps() async throws {
        try await assertScreen { container in
            SchedulingDeveloperView(container: container, workspaceId: Self.workspace, role: .client, tab: "apps")
        }
    }

    func testDeveloperAppsEmpty() async throws {
        try await assertScreen(["op:oauth.connections.list": .noItems], devices: [.iPhone]) { container in
            SchedulingDeveloperView(container: container, workspaceId: Self.workspace, role: .client, tab: "apps")
        }
    }

    func testDeveloperAppsAsViewer() async throws {
        try await assertScreen(devices: [.iPhone], locales: [.en]) { container in
            SchedulingDeveloperView(container: container, workspaceId: Self.workspace, role: .viewer, tab: "apps")
        }
    }

    /// Without a live tenancy there is no host to build the MCP address from.
    func testDeveloperAppsNoTenancy() async throws {
        try await assertScreen(
            ["/api/district/scheduling/status": .fixture("district-scheduling-status-legacy")],
            devices: [.iPhone],
            locales: [.en]
        ) { container in
            SchedulingDeveloperView(container: container, workspaceId: Self.workspace, role: .client, tab: "apps")
        }
    }

    func testDeveloperAppsRefused() async throws {
        try await assertScreen(["op:oauth.connections.list": .refused], devices: [.iPhone]) { container in
            SchedulingDeveloperView(container: container, workspaceId: Self.workspace, role: .client, tab: "apps")
        }
    }

    func testDeveloperWebhooks() async throws {
        try await assertScreen { container in
            SchedulingDeveloperView(container: container, workspaceId: Self.workspace, role: .client, tab: "webhooks")
        }
    }

    func testDeveloperWebhooksEmpty() async throws {
        try await assertScreen(["op:webhooks.list": .noItems], devices: [.iPhone]) { container in
            SchedulingDeveloperView(container: container, workspaceId: Self.workspace, role: .client, tab: "webhooks")
        }
    }

    func testDeveloperWebhooksAsViewer() async throws {
        try await assertScreen(devices: [.iPhone], locales: [.en]) { container in
            SchedulingDeveloperView(container: container, workspaceId: Self.workspace, role: .viewer, tab: "webhooks")
        }
    }

    func testDeveloperWebhooksRefused() async throws {
        try await assertScreen(["op:webhooks.list": .notReady], devices: [.iPhone]) { container in
            SchedulingDeveloperView(container: container, workspaceId: Self.workspace, role: .client, tab: "webhooks")
        }
    }
}
