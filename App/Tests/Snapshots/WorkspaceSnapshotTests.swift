@testable import DistrictAI
import SwiftUI
import XCTest

/// The workspace screens, each drawn from the service's recorded responses as a client
/// who may edit sees them, in English and French, on a phone and an iPad.
final class WorkspaceSnapshotTests: ScreenSnapshotTestCase {
    private static let workspace = "ws-contract-test"

    func testBilling() async throws {
        try await assertScreen { container in
            BillingView(container: container, workspaceId: Self.workspace, role: .client)
        }
    }

    func testDesk() async throws {
        try await assertScreen { container in
            DeskView(container: container, workspaceId: Self.workspace, role: .client)
        }
    }

    func testDialer() async throws {
        try await assertScreen { container in
            DialerView(container: container, workspaceId: Self.workspace, role: .client)
        }
    }

    func testHQ() async throws {
        try await assertScreen { container in
            HQView(container: container, workspaceId: Self.workspace, role: .client)
        }
    }

    func testLiveCalls() async throws {
        try await assertScreen { container in
            LiveCallsView(container: container, workspaceId: Self.workspace, role: .client)
        }
    }

    func testMarketplace() async throws {
        try await assertScreen { container in
            MarketplaceView(container: container, workspaceId: Self.workspace, role: .client)
        }
    }

    func testRoomsLobby() async throws {
        try await assertScreen { container in
            RoomsLobbyView(container: container, workspaceId: Self.workspace, role: .client)
        }
    }

    func testSupport() async throws {
        try await assertScreen { container in
            SupportView(container: container, workspaceId: Self.workspace, role: .client)
        }
    }

    func testWorkflows() async throws {
        try await assertScreen { container in
            WorkflowsView(container: container, workspaceId: Self.workspace, role: .client)
        }
    }

    func testCapabilities() async throws {
        try await assertScreen { container in
            CapabilitiesView(container: container, workspaceId: Self.workspace)
        }
    }

    func testAnalytics() async throws {
        try await assertScreen { container in
            AnalyticsView(container: container, workspaceId: Self.workspace)
        }
    }
}
