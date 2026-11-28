@testable import DistrictAI
import SwiftUI
import XCTest

/// The scheduling screens, each drawn from the service's recorded responses as a client
/// who may edit sees them, in English and French, on a phone and an iPad.
final class SchedulingSnapshotTests: ScreenSnapshotTestCase {
    private static let workspace = "ws-contract-test"

    func testSchedulingHub() async throws {
        try await assertScreen { container in
            SchedulingHubView(container: container, workspaceId: Self.workspace, role: .client)
        }
    }

    func testSchedulingOverview() async throws {
        try await assertScreen { container in
            SchedulingOverviewView(container: container, workspaceId: Self.workspace, role: .client)
        }
    }

    func testSchedulingBookings() async throws {
        try await assertScreen { container in
            SchedulingBookingsView(container: container, workspaceId: Self.workspace, role: .client)
        }
    }

    func testSchedulingCalendar() async throws {
        try await assertScreen { container in
            SchedulingCalendarView(container: container, workspaceId: Self.workspace, role: .client)
        }
    }

    func testSchedulingDeveloper() async throws {
        try await assertScreen { container in
            SchedulingDeveloperView(container: container, workspaceId: Self.workspace, role: .client)
        }
    }

    func testSchedulingEventTypes() async throws {
        try await assertScreen { container in
            SchedulingEventTypesView(container: container, workspaceId: Self.workspace, role: .client)
        }
    }

    func testSchedulingHours() async throws {
        try await assertScreen { container in
            SchedulingHoursView(container: container, workspaceId: Self.workspace, role: .client)
        }
    }

    func testSchedulingSettings() async throws {
        try await assertScreen { container in
            SchedulingSettingsView(container: container, workspaceId: Self.workspace, role: .client)
        }
    }

    func testSchedulingTeam() async throws {
        try await assertScreen { container in
            SchedulingTeamView(container: container, workspaceId: Self.workspace, role: .client)
        }
    }
}
