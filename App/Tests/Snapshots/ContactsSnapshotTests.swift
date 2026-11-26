@testable import DistrictAI
import SwiftUI
import XCTest

/// The contacts list, drawn from the service's recorded contacts and blocked list.
final class ContactsSnapshotTests: ScreenSnapshotTestCase {
    private static let empty = #"{"success":true,"contacts":[],"total":0,"limit":50,"offset":0}"#

    /// Two recorded contacts, one of them blocked, as a client who may edit sees them (the
    /// add button is in the bar).
    func testContactsLoaded() async throws {
        try await assertScreen { container in
            ContactsView(container: container, workspaceId: "ws-contract-test", role: .client, selection: nil)
        }
    }

    /// A viewer sees the same rows without the add button.
    func testContactsForAViewer() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            ContactsView(container: container, workspaceId: "ws-contract-test", role: .viewer, selection: nil)
        }
    }

    func testContactsEmpty() async throws {
        try await assertScreen(["/api/district/contacts": .json(Self.empty)]) { container in
            ContactsView(container: container, workspaceId: "ws-contract-test", role: .client, selection: nil)
        }
    }

    /// A refused read draws the failure with its retry, not an empty list.
    func testContactsFailed() async throws {
        try await assertScreen(
            ["/api/district/contacts": .json(#"{"error":"Internal error"}"#, status: 500)]
        ) { container in
            ContactsView(container: container, workspaceId: "ws-contract-test", role: .client, selection: nil)
        }
    }
}
