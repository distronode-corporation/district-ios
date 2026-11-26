@testable import DistrictAI
import DistrictData
import DistrictModel
import SwiftUI
import XCTest

/// The developer screen's editors: an API key minted and shown once, and a webhook added
/// or edited, over the recorded keys and webhooks.
///
/// ⚠️ THE SECRETS DRAWN HERE ARE THE FIXTURES' OWN PLACEHOLDERS (`cno_contract_new_api_key`,
/// `whsec_contract_shown_once`), never a credential.
final class SchedulingDeveloperWriteSnapshotTests: SchedulingWriteSnapshotCase {
    // MARK: - API keys

    func testKeyCreateBlank() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            SchedulingAPIKeyCreateSheet(model: self.keyModel(container))
        }
    }

    func testKeyCreateNameMissing() async throws {
        try await assertScreen(devices: [.iPhone], locales: [.en]) { container in
            let model = self.keyModel(container)
            model.name = "  "
            return SnapshotPrepared(SchedulingAPIKeyCreateSheet(model: model)) { await model.create() }
        }
    }

    func testKeyCreateRefused() async throws {
        try await assertScreen(["op:apiKeys.create": .refused], devices: [.iPhone]) { container in
            let model = self.keyModel(container)
            model.name = "Zapier"
            return SnapshotPrepared(SchedulingAPIKeyCreateSheet(model: model)) { await model.create() }
        }
    }

    /// The one sight of a minted key, as the second sheet draws it.
    func testKeyReveal() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            SchedulingAPIKeyRevealSheet(
                minted: SchedulingAPIKeyMintedC(name: "Zapier", key: "cno_contract_new_api_key"),
                model: self.keyModel(container)
            )
        }
    }

    // MARK: - Webhooks

    func testWebhookAddBlank() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            SchedulingWebhookEditorSheet(model: self.webhookModel(container, mode: .create))
        }
    }

    /// ⛔ A PRIVATE ADDRESS IS REFUSED BEFORE IT IS SENT, and no event ticked is the second
    /// sentence.
    func testWebhookAddRefusedBeforeSending() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            let model = self.webhookModel(container, mode: .create)
            model.draft.url = "http://192.168.1.10/hook"
            model.draft.events = []
            return SnapshotPrepared(SchedulingWebhookEditorSheet(model: model)) { await model.submit() }
        }
    }

    func testWebhookAddRefusedByScheduler() async throws {
        try await assertScreen(["op:webhooks.create": .refused], devices: [.iPhone], locales: [.en]) { container in
            let model = self.webhookModel(container, mode: .create)
            model.draft.url = "https://hooks.contract.test/bookings"
            return SnapshotPrepared(SchedulingWebhookEditorSheet(model: model)) { await model.submit() }
        }
    }

    /// Editing the recorded active webhook: the address fixed, its events and fields ticked.
    func testWebhookEdit() async throws {
        let hook = try await XCTUnwrap(recordedWebhooks().first)
        try await assertScreen(devices: [.iPhone]) { container in
            SchedulingWebhookEditorSheet(model: self.webhookModel(container, mode: .edit(hook)))
        }
    }

    /// ⚠️ AN EVENT THIS BUILD DOES NOT KNOW AT ALL (a newer server's) is listed as kept,
    /// rather than drawn as a box nobody could untick.
    func testWebhookEditWithUnknownEvent() async throws {
        let list = FixtureTransport.Reply.json("""
        {"ok":true,"data":{"items":[{"id":"wh-contract-3","url":"https://hooks.contract.test/later",
         "events":["booking.created","booking.no_show"],"fields":null,"is_active":true,
         "created_at":"2026-09-07T11:00:00Z"}]}}
        """)
        let hook = try await XCTUnwrap(admin(["op:webhooks.list": list]).webhooks(workspaceId: Self.workspace).first)
        try await assertScreen(devices: [.iPhone]) { container in
            SchedulingWebhookEditorSheet(model: self.webhookModel(container, mode: .edit(hook)))
        }
    }

    /// The recorded second webhook subscribes only to `recording.completed`, which the
    /// editor no longer offers: nothing is ticked, so there is nothing to save.
    func testWebhookEditRetiredEventOnly() async throws {
        let hook = try await XCTUnwrap(recordedWebhooks().last)
        try await assertScreen(devices: [.iPhone], locales: [.en]) { container in
            SchedulingWebhookEditorSheet(model: self.webhookModel(container, mode: .edit(hook)))
        }
    }

    func testWebhookEditSaved() async throws {
        let hook = try await XCTUnwrap(recordedWebhooks().first)
        try await assertScreen(
            ["op:webhooks.patch": .fixture("district-scheduling-ok")],
            devices: [.iPhone],
            locales: [.en]
        ) { container in
            let model = self.webhookModel(container, mode: .edit(hook))
            return SnapshotPrepared(SchedulingWebhookEditorSheet(model: model)) { await model.submit() }
        }
    }

    /// The signing secret, shown once after an add.
    func testWebhookSecret() async throws {
        try await assertScreen(devices: [.iPhone]) { _ in
            SchedulingWebhookSecretSheet(secret: SchedulingWebhookSecretC(
                url: "https://hooks.contract.test/bookings",
                secret: "whsec_contract_shown_once"
            ))
        }
    }

    // MARK: - Models

    private func keyModel(_ container: AppContainer) -> SchedulingAPIKeyCreateModel {
        SchedulingAPIKeyCreateModel(repository: container.schedulingAdmin, workspaceId: Self.workspace, onChanged: {})
    }

    private func webhookModel(
        _ container: AppContainer,
        mode: SchedulingWebhookEditorModel.ModeC
    ) -> SchedulingWebhookEditorModel {
        SchedulingWebhookEditorModel(
            repository: container.schedulingAdmin,
            workspaceId: Self.workspace,
            mode: mode,
            onChanged: {}
        )
    }
}
