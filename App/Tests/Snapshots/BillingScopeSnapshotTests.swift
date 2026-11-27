@testable import DistrictAI
import SwiftUI
import XCTest

/// The billing screen in the states the service records for its two reads: no Stripe
/// customer yet, Stripe unreachable, a plan past due over its cap, and each read refused.
final class BillingScopeSnapshotTests: ScreenSnapshotTestCase {
    private static let workspace = "ws-contract-test"
    private static let stripe = "/api/billing"
    private static let plan = "/api/district/workspace/billing"

    private func draw(
        _ replies: [String: FixtureTransport.Reply],
        devices: [Device] = Device.allCases,
        testName: String = #function
    ) async throws {
        try await assertScreen(replies, devices: devices, testName: testName) { container in
            BillingView(container: container, workspaceId: Self.workspace, role: .client)
        }
    }

    /// No Stripe customer yet: the plan card, and the account card saying billing has not
    /// started rather than drawing empty invoices.
    func testBillingNoCustomer() async throws {
        try await draw([Self.stripe: .fixture("district-billing-no-customer")])
    }

    /// Stripe unreachable: said as such, not as "no invoices".
    func testBillingUnavailable() async throws {
        try await draw([Self.stripe: .fixture("district-billing-unavailable")], devices: [.iPhone])
    }

    /// A plan past due and over its hard cap, with no usage this month.
    func testBillingPastDueOverCap() async throws {
        try await draw([Self.plan: .fixture("district-workspace-billing-null-usage")], devices: [.iPhone])
    }

    /// The Stripe read refused: its own failure, the plan still drawn.
    func testBillingStripeFailed() async throws {
        try await draw([Self.stripe: .refused(500)], devices: [.iPhone])
    }

    /// The plan read refused: the screen's failure with its retry.
    func testBillingPlanFailed() async throws {
        try await draw([Self.plan: .refused(500)], devices: [.iPhone])
    }
}
