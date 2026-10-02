import SwiftUI

/// Create a team, or rename and delete one.
///
/// ⚠️ THE DELETE IS NOT THE SHEET'S PRIMARY BUTTON AND NEVER SHARES ITS
/// CONFIRMATION. The primary commits a rename; the delete is a separate control
/// behind its own dialog, because the two differ by everything and sit under the
/// same thumb.
struct SchedulingTeamEditorSheet: View {
    @Bindable var model: SchedulingTeamEditorModel
    /// ⚠️ Shown in the delete dialog's title. Empty falls back to a generic
    /// question rather than to "Delete ?".
    let teamName: String
    let onClose: () -> Void

    @State private var confirmingDelete = false

    var body: some View {
        SchedulingWriteSheet(
            title: model.isCreating ? SchedulingTeamWriteCopy.createTitle : teamName,
            subtitle: SchedulingTeamWriteCopy.teamsHint,
            cancelLabel: model.isCreating ? SchedulingTeamWriteCopy.cancel : SchedulingTeamWriteCopy.close,
            confirmLabel: model.submitLabel,
            confirmIdentifier: model.isCreating
                ? A11yID.SchedulingWritesB.teamCreateConfirm
                : A11yID.SchedulingWritesB.teamRenameConfirm,
            state: model.state
        ) {
            VStack(alignment: .leading, spacing: DistrictSpacing.row) {
                SettingsField(
                    label: SchedulingTeamWriteCopy.nameLabel,
                    text: Binding(get: { model.name }, set: { model.editName($0) }),
                    enabled: !model.busy
                )
                .accessibilityIdentifier(A11yID.SchedulingWritesB.teamNameField)
                SchedulingWriteRejection(message: model.nameRejected)
                if !model.isCreating {
                    SchedulingWriteHint(text: SchedulingTeamWriteCopy.slugReadOnlyHint)
                    deleteControl
                }
            }
        } onCancel: {
            onClose()
        } onConfirm: {
            Task { await model.submit() }
        }
        .accessibilityIdentifier(A11yID.SchedulingWritesB.teamCreateSheet)
    }

    private var deleteControl: some View {
        Button(SchedulingTeamWriteCopy.deleteConfirm) {
            confirmingDelete = true
        }
        .buttonStyle(.districtDestructive)
        .disabled(!model.canDelete)
        .accessibilityIdentifier(A11yID.SchedulingWritesB.teamDeleteConfirm)
        .confirmationDialog(
            SchedulingTeamWriteCopy.deleteTitle(teamName),
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button(SchedulingTeamWriteCopy.deleteConfirm, role: .destructive) {
                Task { await model.delete() }
            }
            Button(SchedulingTeamWriteCopy.deleteKeep, role: .cancel) {}
        } message: {
            // ⛔ NAMES THE CONSEQUENCE IN THE OPERATOR'S OWN UNITS. "This cannot be
            // undone" tells nobody what they are weighing; what a deleted team
            // takes with it is the rotation every event type routing to it uses.
            Text(SchedulingTeamWriteCopy.deleteBody)
        }
    }
}
