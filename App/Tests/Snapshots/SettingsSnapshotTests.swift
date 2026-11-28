@testable import DistrictAI
import SwiftUI
import XCTest

// ⚠️ NO CALL HANDLING DRAWING: its English title is longer than the large-title bar, and UIKit
// laid the screen out 6 points lower on some runs than on others (CI runs 45828178685 and
// 45820857719), so a reference for it could not be held. It is left undrawn rather than
// compared loosely.

/// The settings screens, each drawn from the service's recorded responses as a client
/// who may edit sees them, in English and French, on a phone and an iPad.
final class SettingsSnapshotTests: ScreenSnapshotTestCase {
    private static let workspace = "ws-contract-test"

    func testDirectory() async throws {
        try await assertScreen { container in
            DirectoryView(container: container, workspaceId: Self.workspace, role: .client)
        }
    }

    func testIntegrations() async throws {
        try await assertScreen { container in
            IntegrationsView(container: container, workspaceId: Self.workspace, role: .client)
        }
    }

    func testKnowledge() async throws {
        try await assertScreen { container in
            KnowledgeView(container: container, workspaceId: Self.workspace, role: .client)
        }
    }

    func testMembers() async throws {
        try await assertScreen { container in
            MembersView(container: container, workspaceId: Self.workspace, role: .client)
        }
    }

    func testMessaging() async throws {
        try await assertScreen { container in
            MessagingView(container: container, workspaceId: Self.workspace, role: .client)
        }
    }

    func testPersona() async throws {
        try await assertScreen { container in
            PersonaView(container: container, workspaceId: Self.workspace, role: .client)
        }
    }

    func testRouting() async throws {
        try await assertScreen { container in
            RoutingView(container: container, workspaceId: Self.workspace, role: .client)
        }
    }

    func testVoiceStudio() async throws {
        try await assertScreen { container in
            VoiceStudioView(container: container, workspaceId: Self.workspace, role: .client)
        }
    }
}
