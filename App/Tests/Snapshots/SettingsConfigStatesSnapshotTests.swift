@testable import DistrictAI
import DistrictModel
import SwiftUI
import XCTest

/// The settings screens that hydrate from `workspace/config`, and call handling, in the states
/// the full recorded config does not reach: a sparse workspace with nothing stored, a stored
/// value this build will not edit, a refused read, and a viewer.
final class SettingsConfigStatesSnapshotTests: ScreenSnapshotTestCase {
    private static let workspace = "ws-contract-test"
    private static let config = "/api/district/workspace/config"
    private static let callHandling = "/api/district/workspace/call-handling"

    private static func screen(
        _ section: SettingsSection,
        _ container: AppContainer,
        role: WorkspaceRole? = .client
    ) -> some View {
        SettingsDestinations.view(for: section, container: container, workspaceId: workspace, role: role)
    }

    // MARK: - A sparse workspace

    /// The transfer directory with no rows yet.
    func testDirectorySparse() async throws {
        try await assertScreen([Self.config: .fixture("district-workspace-config-sparse")], devices: [.iPhone]) {
            Self.screen(.directory, $0)
        }
    }

    /// No stored tool list: every skill on, and the list not editable.
    func testCapabilitiesSparse() async throws {
        try await assertScreen([Self.config: .fixture("district-workspace-config-sparse")], devices: [.iPhone]) {
            Self.screen(.capabilities, $0)
        }
    }

    func testRoutingSparse() async throws {
        try await assertScreen([Self.config: .fixture("district-workspace-config-sparse")], devices: [.iPhone]) {
            Self.screen(.routing, $0)
        }
    }

    func testPersonaSparse() async throws {
        try await assertScreen([Self.config: .fixture("district-workspace-config-sparse")], devices: [.iPhone]) {
            Self.screen(.persona, $0)
        }
    }

    // MARK: - Stored values this build will not edit

    /// ⛔ A DIRECTORY THAT IS NOT A LIST OF ROWS IS SHOWN AS NOT EDITABLE, so a save cannot
    /// overwrite whatever is stored.
    func testDirectoryNotEditable() async throws {
        let reply = FixtureTransport.Reply.recorded("district-workspace-config") { json in
            json.editObject("config") { $0["callDirectory"] = "+14165550177" }
        }
        try await assertScreen([Self.config: reply], devices: [.iPhone]) {
            Self.screen(.directory, $0)
        }
    }

    /// A routing rules value that is not a list of rows, likewise.
    func testRoutingNotEditable() async throws {
        let reply = FixtureTransport.Reply.recorded("district-workspace-config") { json in
            json.editObject("config") { $0["routingRules"] = ["unexpected": true] }
        }
        try await assertScreen([Self.config: reply], devices: [.iPhone], locales: [.en]) {
            Self.screen(.routing, $0)
        }
    }

    /// ⚠️ A CALL HANDLING MODE THIS BUILD HAS NOT LEARNED IS SHOWN AS ITSELF and none of the
    /// three is ticked.
    func testCallHandlingWithAnUnknownMode() async throws {
        let reply = FixtureTransport.Reply.json(
            #"{"success":true,"callHandling":"voicemail_only","appRingSeconds":20}"#
        )
        try await assertScreen([Self.callHandling: reply], devices: [.iPhone]) {
            Self.screen(.calls, $0)
        }
    }

    /// The app rings first, for longer.
    func testCallHandlingAppFirst() async throws {
        let reply = FixtureTransport.Reply.json(#"{"success":true,"callHandling":"app_first","appRingSeconds":45}"#)
        try await assertScreen([Self.callHandling: reply], devices: [.iPhone], locales: [.en]) {
            Self.screen(.calls, $0)
        }
    }

    // MARK: - Refused reads

    func testDirectoryFailed() async throws {
        try await assertScreen([Self.config: .refused(500)], devices: [.iPhone], locales: [.en]) {
            Self.screen(.directory, $0)
        }
    }

    func testCapabilitiesFailed() async throws {
        try await assertScreen([Self.config: .refused(500)], devices: [.iPhone], locales: [.en]) {
            Self.screen(.capabilities, $0)
        }
    }

    func testRoutingFailed() async throws {
        try await assertScreen([Self.config: .refused(500)], devices: [.iPhone], locales: [.en]) {
            Self.screen(.routing, $0)
        }
    }

    func testPersonaFailed() async throws {
        try await assertScreen([Self.config: .refused(500)], devices: [.iPhone], locales: [.en]) {
            Self.screen(.persona, $0)
        }
    }

    /// ⚠️ A 403 IS NOT RETRYABLE: the sentence says why and offers no retry.
    func testCallHandlingRefused() async throws {
        try await assertScreen([Self.callHandling: .refused(403, "Forbidden")], devices: [.iPhone], locales: [.en]) {
            Self.screen(.calls, $0)
        }
    }

    // MARK: - A viewer

    // ⚠️ ONLY INTEGRATIONS: `workspace/config` refuses a viewer, so the hub hides the directory,
    // routing and persona rows from one (``RouteGate``), and drawing them over a successful
    // config read would be a state the service cannot produce.

    func testIntegrationsForAViewer() async throws {
        try await assertScreen(
            ["/api/district/connections": .fixture("district-connections-viewer")],
            devices: [.iPhone]
        ) { Self.screen(.integrations, $0, role: .viewer) }
    }
}
