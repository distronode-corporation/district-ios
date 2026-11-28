@testable import DistrictAI
import DistrictModel
import DistrictNetwork
import SwiftUI
import XCTest

/// The settings screens as each role sees them, and in the states the recorded responses do
/// not reach on their own, opened through ``SettingsDestinations`` as the shell opens them.
final class SettingsRolesSnapshotTests: ScreenSnapshotTestCase {
    private static let workspace = "ws-contract-test"
    private static let members = "/api/district/workspace/members"

    // MARK: - The hub

    /// Agency sees every row and the "more on the web" footnote.
    func testHubForAgency() async throws {
        try await assertScreen { container in
            SettingsDestinations.view(for: .hub, container: container, workspaceId: Self.workspace, role: .agency)
        }
    }

    /// A viewer sees only the rows a viewer may open, and the read-only footnote.
    func testHubForAViewer() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            SettingsDestinations.view(
                for: .scheduling, container: container, workspaceId: Self.workspace, role: .viewer
            )
        }
    }

    /// ⛔ A ROLE THAT DID NOT PARSE IS GATED AS A VIEWER, never as a client.
    func testHubForAnUnparsedRole() async throws {
        try await assertScreen(devices: [.iPhone], locales: [.en]) { container in
            SettingsDestinations.view(for: .hub, container: container, workspaceId: Self.workspace, role: nil)
        }
    }

    // MARK: - Members

    /// Agency manages the roster: a role picker and Remove on every row, and the add card.
    func testMembersForAgency() async throws {
        try await assertScreen { container in
            SettingsDestinations.view(for: .members, container: container, workspaceId: Self.workspace, role: .agency)
        }
    }

    /// ⚠️ A ROLE THE APP DOES NOT KNOW IS SHOWN AS ITSELF, not guessed at.
    func testMembersWithAnUnknownRole() async throws {
        let reply = FixtureTransport.Reply.recorded("district-members") { json in
            json.editEach("members") { row in
                if row["email"] as? String == "auditor@contract.test" {
                    row["role"] = "billing"
                }
            }
        }
        try await assertScreen([Self.members: reply], devices: [.iPhone], locales: [.en]) { container in
            SettingsDestinations.view(for: .members, container: container, workspaceId: Self.workspace, role: .agency)
        }
    }

    func testMembersFailed() async throws {
        try await assertScreen([Self.members: .refused(500)], devices: [.iPhone]) { container in
            SettingsDestinations.view(for: .members, container: container, workspaceId: Self.workspace, role: .agency)
        }
    }

    // MARK: - Other screens for a viewer

    func testCallHandlingForAViewer() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            SettingsDestinations.view(for: .calls, container: container, workspaceId: Self.workspace, role: .viewer)
        }
    }

    func testKnowledgeForAViewer() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            SettingsDestinations.view(
                for: .knowledge, container: container, workspaceId: Self.workspace, role: .viewer
            )
        }
    }

    /// Knowledge with no documents yet.
    func testKnowledgeEmpty() async throws {
        let reply = FixtureTransport.Reply.recorded("district-knowledge") { json in json["documents"] = [Any]() }
        try await assertScreen(["/api/district/workspace/knowledge": reply], devices: [.iPhone]) { container in
            SettingsDestinations.view(
                for: .knowledge, container: container, workspaceId: Self.workspace, role: .client
            )
        }
    }

    /// ⚠️ THE DOCUMENTS READ BUT THE MODE DID NOT: the list stands and the mode is said to be
    /// unavailable rather than drawn as a choice.
    func testKnowledgeWithTheModeUnreadable() async throws {
        try await assertScreen(
            ["/api/district/workspace/knowledge-mode": .refused(500)],
            devices: [.iPhone]
        ) { container in
            SettingsDestinations.view(
                for: .knowledge, container: container, workspaceId: Self.workspace, role: .client
            )
        }
    }

    func testKnowledgeFailed() async throws {
        try await assertScreen(
            ["/api/district/workspace/knowledge": .refused(500)],
            devices: [.iPhone],
            locales: [.en]
        ) { container in
            SettingsDestinations.view(
                for: .knowledge, container: container, workspaceId: Self.workspace, role: .client
            )
        }
    }

    // MARK: - The persona preview

    /// The preview before it starts: the intro and Start, nothing connected.
    func testPersonaPreviewIdle() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            PersonaPreviewView(
                container: container,
                workspaceId: Self.workspace,
                form: PersonaPreviewForm(name: "Ada")
            )
        }
    }

    // MARK: - The shared notices

    /// Every save notice the settings screens draw, with their controls, and the not-editable
    /// and unset-value rows.
    func testSaveNotices() async throws {
        try await assertScreen(devices: [.iPhone]) { _ in
            ScrollView {
                VStack(alignment: .leading, spacing: DistrictSpacing.section) {
                    SettingsSaveNotice(state: .idle)
                    SettingsSaveNotice(state: .saved, onDismiss: {})
                    SettingsSaveNotice(
                        state: .savedButStale(FailureText(message: SessionCopy.somethingWentWrongOur, action: .retry)),
                        onReread: {},
                        onDismiss: {}
                    )
                    SettingsSaveNotice(state: .savedButStale(FailureText(
                        message: SessionCopy.appearOfflineCheckConnection,
                        action: .retry
                    )))
                    SettingsSaveNotice(
                        state: .failed(FailureText(message: SessionCopy.doNotHavePermission, action: .none))
                    )
                    SettingsNotEditableNotice()
                    SettingsReadOnlyRow(label: SettingsCopy.savedAs, value: nil)
                    SettingsReadOnlyRow(label: "sk_live_identifier_label", value: "Stored", identifierLabel: true)
                    SettingsLoadFailureView(
                        failure: FailureText(message: SessionCopy.sessionHasEndedPlease, action: .signIn),
                        onRetry: {},
                        onSignIn: {}
                    )
                }
                .padding(DistrictSpacing.gutter)
            }
        }
    }
}
