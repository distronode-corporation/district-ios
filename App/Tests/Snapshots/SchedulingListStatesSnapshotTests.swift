@testable import DistrictAI
import SwiftUI
import XCTest

/// The scheduling section screens besides "loaded, as a client": as a viewer, who reads the
/// same rows and is offered no write, with nothing in them, and with their main read refused.
final class SchedulingListStatesSnapshotTests: SchedulingWriteSnapshotCase {
    private typealias Reply = FixtureTransport.Reply

    private static let noBookings = Reply.json(
        #"{"ok":true,"data":{"items":[],"total":0,"counts":{"upcoming":0,"past":0},"limit":50,"offset":0}}"#
    )

    /// No calendar connected on an instance that offers all three providers.
    private static let noCalendar = Reply.json("""
    {"ok":true,"data":{"connected":false,"configured":true,"providers":["google","microsoft","caldav"],
     "connections":[],"unconfigured_providers":null,"provider":null}}
    """)

    // MARK: - Overview

    func testOverviewAsViewer() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            SchedulingOverviewView(container: container, workspaceId: Self.workspace, role: .viewer)
        }
    }

    /// ⚠️ ONE READ REFUSED DOES NOT HIDE THE OTHERS: the event types fail in their own row.
    func testOverviewOneReadRefused() async throws {
        try await assertScreen(["op:eventTypes.list": .refused], devices: [.iPhone]) { container in
            SchedulingOverviewView(container: container, workspaceId: Self.workspace, role: .client)
        }
    }

    // MARK: - Event types

    func testEventTypesAsViewer() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            SchedulingEventTypesView(container: container, workspaceId: Self.workspace, role: .viewer)
        }
    }

    func testEventTypesEmpty() async throws {
        try await assertScreen(["op:eventTypes.list": .noItems], devices: [.iPhone]) { container in
            SchedulingEventTypesView(container: container, workspaceId: Self.workspace, role: .client)
        }
    }

    /// ⛔ A LIST THAT FAILED OFFERS NO CREATE: the taken slugs come from the rows on screen.
    func testEventTypesRefused() async throws {
        try await assertScreen(["op:eventTypes.list": .notReady], devices: [.iPhone]) { container in
            SchedulingEventTypesView(container: container, workspaceId: Self.workspace, role: .client)
        }
    }

    // MARK: - Bookings

    func testBookingsAsViewer() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            SchedulingBookingsView(container: container, workspaceId: Self.workspace, role: .viewer)
        }
    }

    func testBookingsEmpty() async throws {
        try await assertScreen(["op:bookings.list": Self.noBookings], devices: [.iPhone]) { container in
            SchedulingBookingsView(container: container, workspaceId: Self.workspace, role: .client)
        }
    }

    func testBookingsRefused() async throws {
        try await assertScreen(["op:bookings.list": .refused], devices: [.iPhone]) { container in
            SchedulingBookingsView(container: container, workspaceId: Self.workspace, role: .client)
        }
    }

    // MARK: - Hours

    func testHoursAsViewer() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            SchedulingHoursView(container: container, workspaceId: Self.workspace, role: .viewer)
        }
    }

    func testHoursRefused() async throws {
        try await assertScreen(
            ["op:availability.rules.list": .refused, "op:availability.overrides.list": .refused],
            devices: [.iPhone]
        ) { container in
            SchedulingHoursView(container: container, workspaceId: Self.workspace, role: .client)
        }
    }

    // MARK: - Calendar

    func testCalendarAsViewer() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            SchedulingCalendarView(container: container, workspaceId: Self.workspace, role: .viewer)
        }
    }

    func testCalendarNothingConnected() async throws {
        try await assertScreen(["op:calendar.status": Self.noCalendar], devices: [.iPhone]) { container in
            SchedulingCalendarView(container: container, workspaceId: Self.workspace, role: .client)
        }
    }

    func testCalendarRefused() async throws {
        try await assertScreen(["op:calendar.status": .notReady], devices: [.iPhone], locales: [.en]) { container in
            SchedulingCalendarView(container: container, workspaceId: Self.workspace, role: .client)
        }
    }

    // MARK: - Team

    func testTeamAsViewer() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            SchedulingTeamView(container: container, workspaceId: Self.workspace, role: .viewer)
        }
    }

    func testTeamNoTeams() async throws {
        try await assertScreen(["op:teams.list": .noItems], devices: [.iPhone], locales: [.en]) { container in
            SchedulingTeamView(container: container, workspaceId: Self.workspace, role: .client)
        }
    }

    /// ⚠️ `users.list` IS ADMIN-ONLY: refused, the member table says so and the teams stay.
    func testTeamDirectoryRefused() async throws {
        try await assertScreen(["op:users.list": .refused], devices: [.iPhone]) { container in
            SchedulingTeamView(container: container, workspaceId: Self.workspace, role: .client)
        }
    }
}
