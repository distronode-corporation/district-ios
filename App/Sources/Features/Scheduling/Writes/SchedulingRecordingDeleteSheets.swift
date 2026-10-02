import SwiftUI

/// Delete one recording, behind a dialog that names what goes with it.
///
/// ⚠️ A `confirmationDialog` RATHER THAN A SHEET, because there is nothing to fill
/// in — the decision is the whole interaction. The bulk delete below is a sheet for
/// exactly the opposite reason.
struct SchedulingRecordingDeleteButton: View {
    @Bindable var model: SchedulingRecordingDeleteModel
    let recordingId: String
    let label: String

    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            Button(label) { confirming = true }
                .buttonStyle(.districtDestructive)
                .disabled(model.busy)
                .accessibilityIdentifier(
                    A11yID.row(A11yID.SchedulingWritesB.recordingDeleteConfirm, recordingId)
                )
                // ⚠️ ON THE BUTTON, NOT THE STACK WITH THE NOTICE UNDER IT, so the popover
                // a regular-width layout draws points at the button.
                .confirmationDialog(
                    SchedulingRecordingWriteCopy.deleteTitle,
                    isPresented: $confirming,
                    titleVisibility: .visible
                ) {
                    Button(SchedulingRecordingWriteCopy.deleteConfirm, role: .destructive) {
                        Task { await model.delete(recordingId: recordingId) }
                    }
                    Button(SchedulingRecordingWriteCopy.deleteCancel, role: .cancel) {}
                } message: {
                    Text(SchedulingRecordingWriteCopy.deleteBody)
                }
            SchedulingWriteOutcome(state: model.state)
        }
    }
}

/// Delete every recording the tenancy holds, behind a typed confirmation.
///
/// ⛔ THE WORD HAS TO BE TYPED AND IT IS LOWER-CASE `delete`, TRIMMED, EXACT AND
/// CASE-SENSITIVE — the web recordings table's gate byte for byte. ⚠️ It is NOT the
/// workspace name.
///
/// ⛔ AND THE FIELD TURNS AUTOCAPITALISATION OFF. iOS offers "Delete" for the first
/// word of an empty field, so without it the commonest thing a thumb produces does
/// not satisfy a gate that is deliberately case-sensitive — the control would read
/// as broken rather than as strict.
struct SchedulingRecordingDeleteAllSheet: View {
    @Bindable var model: SchedulingRecordingDeleteModel
    let onClose: () -> Void

    var body: some View {
        SchedulingWriteSheet(
            title: SchedulingRecordingWriteCopy.deleteAllTitle,
            subtitle: SchedulingRecordingWriteCopy.deleteAllBody,
            cancelLabel: SchedulingRecordingWriteCopy.deleteAllCancel,
            confirmLabel: SchedulingRecordingWriteCopy.deleteAllConfirm,
            destructive: true,
            confirmEnabled: model.canDeleteAll,
            confirmIdentifier: A11yID.SchedulingWritesB.recordingDeleteAllConfirm,
            state: model.state
        ) {
            VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
                SettingsField(
                    label: SchedulingRecordingWriteCopy.deleteAllFieldLabel,
                    text: Binding(get: { model.confirmation }, set: { model.editConfirmation($0) }),
                    enabled: !model.busy
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier(A11yID.SchedulingWritesB.recordingDeleteAllField)
                SchedulingWriteHint(text: SchedulingRecordingWriteCopy.deleteAllFieldHint)
            }
        } onCancel: {
            onClose()
        } onConfirm: {
            Task { await model.deleteAll() }
        }
        .accessibilityIdentifier(A11yID.SchedulingWritesB.recordingDeleteAllSheet)
    }
}
