import SwiftUI

/// What can be done to an event type without opening it: turn it on or off,
/// archive it, send yourself one of its emails, delete it.
///
/// ⛔ THE DELETE IS THE ONLY ONE BEHIND A CONFIRMATION, AND ARCHIVE IS OFFERED
/// BESIDE IT ON PURPOSE. Archiving hides the event type and leaves its bookings
/// addressable; deleting removes the row and stops the booking page. Most people
/// reaching for "delete" mean the first, so both are on screen with the second
/// one's consequence spelled out.
///
/// ⚠️ THE TEST EMAILS SEND THE STORED WORDING, not anything typed in the editor,
/// which is why they live here and not there. There is no recipient control: the
/// fork addresses the calling member's own scheduler address, and the answer names
/// it.
struct SchedulingEventTypeActionsSheet: View {
    let model: SchedulingEventTypeActionsModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        SchedulingWriteSheet(title: model.eventType.name) {
            stateButtons
            testEmails
            Button(SchedulingWriteCopy.deleteEventTypeConfirm) {
                model.confirmingDelete = true
            }
            .buttonStyle(.districtDestructive)
            .disabled(model.busy)
            .accessibilityIdentifier(A11yID.SchedulingWrites.actionsDelete)
            .confirmationDialog(
                SchedulingWriteCopy.deleteEventTypeTitle,
                isPresented: Binding(
                    get: { model.confirmingDelete },
                    set: { model.confirmingDelete = $0 }
                ),
                titleVisibility: .visible
            ) {
                Button(SchedulingWriteCopy.deleteEventTypeConfirm, role: .destructive) {
                    delete()
                }
                Button(SchedulingWriteCopy.cancel, role: .cancel) {
                    model.confirmingDelete = false
                }
            } message: {
                Text(SchedulingWriteCopy.deleteEventTypeBody)
            }
            messages
            Button(SchedulingWriteCopy.cancel) {
                dismiss()
            }
            .buttonStyle(.districtGhost)
        }
        .accessibilityIdentifier(A11yID.SchedulingWrites.actionsRoot)
    }

    private var stateButtons: some View {
        HStack(spacing: DistrictSpacing.tight) {
            Button(model.toggleTitle) {
                Task { await model.toggleActive() }
            }
            .buttonStyle(.districtSecondary)
            .disabled(model.busy)
            .accessibilityIdentifier(A11yID.SchedulingWrites.actionsToggle)
            Button(model.archiveTitle) {
                Task { await model.toggleArchived() }
            }
            .buttonStyle(.districtSecondary)
            .disabled(model.busy)
            .accessibilityIdentifier(A11yID.SchedulingWrites.actionsArchive)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var testEmails: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            Text(SchedulingWriteCopy.sendTestEmail)
                .font(DistrictType.labelSmall)
                .foregroundStyle(colors.mutedForeground)
            ForEach(SchedulingWriteCopy.emailTemplates, id: \.type) { template in
                Button(template.label) {
                    Task { await model.sendTestEmail(type: template.type) }
                }
                .buttonStyle(.districtGhost)
                .disabled(model.busy)
                .accessibilityIdentifier(A11yID.SchedulingWrites.testEmail(template.type))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var messages: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            SchedulingWriteOutcome(state: model.state, onDismiss: model.dismissNotice)
        }
        .accessibilityIdentifier(A11yID.SchedulingWrites.actionsNotice)
    }

    /// ⚠️ THE SHEET CLOSES ONLY ON A DELETE THAT LANDED. A refused one leaves the
    /// sentence on screen beside the event type it is about.
    private func delete() {
        Task {
            await model.delete()
            if case .done = model.state {
                dismiss()
            }
        }
    }
}
