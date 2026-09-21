import DistrictData
import DistrictModel
import SwiftUI

/// The controls that open the Developer tab's writes.
///
/// ⛔ THE TWO CREATES BUILD A MODEL PER PRESS AND THE THREE DESTRUCTIVE ONES DO
/// NOT, AND THAT SPLIT IS FORCED BY ``SchedulingWriteConfirmationsC``. One model per
/// screen holds the row being asked about, and each row's button carries a dialog
/// that presents only while that row is the pending one. So a revoke/delete button
/// here calls `ask(_:)` on a model the screen owns, while a create owns its own.
///
/// ⛔ AND NOTHING HERE EVER HOLDS THE SECRET. `apiKeys.create` and
/// `webhooks.create` each answer a credential exactly once and the sheet that
/// presents it drops it on dismissal (see ``SchedulingAPIKeyCreateModel`` and
/// ``SchedulingWebhookEditorModel``); these buttons carry the model in and read
/// nothing back out.
struct SchedulingAPIKeyCreateButton: View {
    let admin: SchedulingAdminRepository
    let workspaceId: String
    let onChanged: () -> Void

    @State private var creating: SchedulingWritePresentation<SchedulingAPIKeyCreateModel>?

    var body: some View {
        Button(SchedulingWriteCopyC.keyCreate) {
            creating = SchedulingWritePresentation(model: makeModel())
        }
        .buttonStyle(.districtPrimary)
        .accessibilityIdentifier(A11yID.SchedulingWriteEntry.keyCreate)
        .sheet(item: $creating) { entry in
            SchedulingAPIKeyCreateSheet(model: entry.model)
        }
    }

    private func makeModel() -> SchedulingAPIKeyCreateModel {
        SchedulingAPIKeyCreateModel(
            repository: admin,
            workspaceId: workspaceId,
            onChanged: onChanged
        )
    }
}

/// "Revoke key", on one row, with its prompt.
struct SchedulingAPIKeyRevokeButton: View {
    let model: SchedulingAPIKeyRevokeModel
    let key: SchedulingAPIKey

    var body: some View {
        Button(SchedulingWriteCopyC.keyRevokeAction) { model.ask(key) }
            .buttonStyle(.districtGhost)
            .disabled(model.busy)
            .accessibilityIdentifier(
                A11yID.row(A11yID.SchedulingDeveloperWrites.keyRevoke, key.id)
            )
            .schedulingRevokeKeyDialogC(model, for: key)
    }
}

/// "Revoke access", on one connected app.
struct SchedulingOAuthConnectionRevokeButton: View {
    let model: SchedulingOAuthConnectionRevokeModel
    let connection: SchedulingOAuthConnection

    var body: some View {
        Button(SchedulingWriteCopyC.appRevokeAction) { model.ask(connection) }
            .buttonStyle(.districtGhost)
            .disabled(model.busy)
            .accessibilityIdentifier(
                A11yID.row(A11yID.SchedulingDeveloperWrites.appRevoke, connection.id)
            )
            .schedulingRevokeAppDialogC(model, for: connection)
    }
}

/// "Add webhook", on the webhooks card.
struct SchedulingWebhookCreateButton: View {
    let admin: SchedulingAdminRepository
    let workspaceId: String
    let onChanged: () -> Void

    @State private var editing: SchedulingWritePresentation<SchedulingWebhookEditorModel>?

    var body: some View {
        Button(SchedulingWriteCopyC.webhookAddAction) {
            editing = SchedulingWritePresentation(model: makeModel())
        }
        .buttonStyle(.districtPrimary)
        .accessibilityIdentifier(A11yID.SchedulingWriteEntry.webhookCreate)
        .sheet(item: $editing) { entry in
            SchedulingWebhookEditorSheet(model: entry.model)
        }
    }

    private func makeModel() -> SchedulingWebhookEditorModel {
        SchedulingWebhookEditorModel(
            repository: admin,
            workspaceId: workspaceId,
            mode: .create,
            onChanged: onChanged
        )
    }
}

/// "Edit" and "Delete webhook", on one row.
///
/// ⚠️ THE EDIT CARRIES THE WHOLE ROW RATHER THAN AN ID, because the sheet renders
/// the URL it may NOT change and has to name the events this build does not know
/// before it drops them. See ``SchedulingWebhookEditorModel/droppedEvents``.
struct SchedulingWebhookRowActions: View {
    let admin: SchedulingAdminRepository
    let workspaceId: String
    let webhook: SchedulingWebhook
    let deleteModel: SchedulingWebhookDeleteModel
    let onChanged: () -> Void

    @State private var editing: SchedulingWritePresentation<SchedulingWebhookEditorModel>?

    var body: some View {
        HStack(spacing: DistrictSpacing.tight) {
            Button(SchedulingWriteCopy.edit) {
                editing = SchedulingWritePresentation(model: makeModel())
            }
            .buttonStyle(.districtGhost)
            .accessibilityIdentifier(A11yID.row(A11yID.SchedulingWriteEntry.webhookEdit, webhook.id))
            Button(SchedulingWriteCopyC.webhookDeleteAction) { deleteModel.ask(webhook) }
                .buttonStyle(.districtGhost)
                .disabled(deleteModel.busy)
                .accessibilityIdentifier(
                    A11yID.row(A11yID.SchedulingDeveloperWrites.webhookDelete, webhook.id)
                )
                .schedulingDeleteWebhookDialogC(deleteModel, for: webhook)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $editing) { entry in
            SchedulingWebhookEditorSheet(model: entry.model)
        }
    }

    private func makeModel() -> SchedulingWebhookEditorModel {
        SchedulingWebhookEditorModel(
            repository: admin,
            workspaceId: workspaceId,
            mode: .edit(webhook),
            onChanged: onChanged
        )
    }
}
