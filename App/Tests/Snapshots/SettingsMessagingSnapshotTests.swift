@testable import DistrictAI
import DistrictModel
import SwiftUI
import XCTest

/// The carrier accounts screen in the states the recorded list does not reach, and the
/// account sheet in each of its states, drawn from the service's recorded messaging
/// responses.
///
/// ⚠️ THE SHEET IS DRAWN OVER A ``MessagingModel`` THE TEST DRIVES, the way the screen drives
/// it: the list is read, a draft is opened (``MessagingModel/startEditing(accountId:)``), and
/// the probe or the save runs against the stubbed route.
final class SettingsMessagingSnapshotTests: ScreenSnapshotTestCase {
    private static let workspace = "ws-contract-test"
    private static let messaging = "/api/district/workspace/messaging"
    private static let probe = "/api/district/workspace/messaging/test"

    // MARK: - The screen

    /// A viewer reads the same accounts with no add, edit or default controls.
    func testMessagingForAViewer() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            SettingsDestinations.view(
                for: .messaging, container: container, workspaceId: Self.workspace, role: .viewer
            )
        }
    }

    /// A workspace with no accounts, no managed number and no channel defaults.
    func testMessagingWithNoAccounts() async throws {
        try await assertScreen([Self.messaging: .fixture("district-messaging-unmanaged")]) { container in
            SettingsDestinations.view(
                for: .messaging, container: container, workspaceId: Self.workspace, role: .client
            )
        }
    }

    /// Accounts with no default named: the screen says so rather than implying one.
    func testMessagingWithNoDefaultAccount() async throws {
        let reply = FixtureTransport.Reply.recorded("district-messaging") { json in
            json["defaultAccountId"] = NSNull()
        }
        try await assertScreen([Self.messaging: reply], devices: [.iPhone]) { container in
            SettingsDestinations.view(
                for: .messaging, container: container, workspaceId: Self.workspace, role: .client
            )
        }
    }

    /// A refused read draws the failure with its retry.
    func testMessagingFailed() async throws {
        try await assertScreen([Self.messaging: .refused(500)], devices: [.iPhone]) { container in
            SettingsDestinations.view(
                for: .messaging, container: container, workspaceId: Self.workspace, role: .client
            )
        }
    }

    // MARK: - The account sheet

    /// A new account: Twilio's two secret boxes, every one required.
    func testAddAccountSheet() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            Self.sheet(container) { model in
                model.startEditing(accountId: nil)
            }
        }
    }

    /// An existing account: its numbers shown as stored, the secrets redacted and optional.
    func testEditAccountSheet() async throws {
        try await assertScreen { container in
            Self.sheet(container) { model in
                model.startEditing(accountId: "acct-twilio")
            }
        }
    }

    /// The carrier switched on an existing account: Sinch's five boxes, now all required,
    /// and edited numbers that will replace the stored ones.
    func testEditAccountSheetWithANewCarrierAndNumbers() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            Self.sheet(container) { model in
                model.startEditing(accountId: "acct-twilio")
                guard var draft = model.draft else { return }
                draft.provider = "sinch"
                draft.secrets = [:]
                draft.phoneNumbers = "+14165550111\n+14165550120"
                draft.numbersEdited = true
                model.editDraft(draft)
            }
        }
    }

    /// The carrier accepted the typed credentials, and names the account it found.
    func testProbePassed() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            Self.sheet(container) { model in
                Self.typeTwilioSecrets(model)
                await model.testCredentials()
            }
        }
    }

    /// The carrier refused them, in its own words.
    func testProbeRejected() async throws {
        let rejected = FixtureTransport.Reply.fixture("district-messaging-test-rejected")
        try await assertScreen([Self.probe: rejected], devices: [.iPhone]) { container in
            Self.sheet(container) { model in
                Self.typeTwilioSecrets(model)
                await model.testCredentials()
            }
        }
    }

    /// The probe could not be asked at all, which says nothing about the credentials.
    func testProbeUnreachable() async throws {
        try await assertScreen([Self.probe: .refused(503)], devices: [.iPhone]) { container in
            Self.sheet(container) { model in
                Self.typeTwilioSecrets(model)
                await model.testCredentials()
            }
        }
    }

    /// A save the carrier refused (502): the carrier's message under the form, and the typed
    /// draft still on screen.
    func testSaveRefusedByTheCarrier() async throws {
        let refusal = FixtureTransport.Reply.refused(502, "Twilio rejected +14165550199: not on this account")
        try await assertScreen(["PATCH \(Self.messaging)": refusal]) { container in
            Self.sheet(container) { model in
                Self.typeTwilioSecrets(model)
                await model.saveAccount()
            }
        }
    }

    // MARK: - Helpers

    /// The sheet over a client's model, with the list read and then `drive` run.
    private static func sheet(
        _ container: AppContainer,
        drive: @escaping @MainActor @Sendable (MessagingModel) async -> Void
    ) -> some View {
        let model = MessagingModel(container: container, workspaceId: workspace, role: .client)
        return MessagingAccountSheet(model: model)
            .task {
                await model.loadAccounts()
                await drive(model)
            }
    }

    /// A new Twilio draft with both secrets typed, so Test and Save are offered.
    private static func typeTwilioSecrets(_ model: MessagingModel) {
        model.startEditing(accountId: nil)
        guard var draft = model.draft else { return }
        draft.label = "Front desk"
        draft.secrets = ["accountSid": "AC00000000000000000000000000000000", "authToken": "contract-token"]
        model.editDraft(draft)
    }
}
