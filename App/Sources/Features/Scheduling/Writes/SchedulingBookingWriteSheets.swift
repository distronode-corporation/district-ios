import SwiftUI

/// Cancel one booking, with the optional reason.
///
/// ⚠️ THE BODY SAYS WHAT THE ATTENDEE RECEIVES. "Are you sure" tells nobody what
/// they are weighing; the thing an operator cannot see afterwards is the email
/// that went out, so the sheet names it.
struct SchedulingBookingCancelSheet: View {
    @Bindable var model: SchedulingBookingCancelModel
    let onClose: () -> Void

    var body: some View {
        SchedulingWriteSheet(
            title: SchedulingBookingWriteCopy.cancelTitle,
            subtitle: SchedulingBookingWriteCopy.cancelBody,
            cancelLabel: SchedulingBookingWriteCopy.cancelKeep,
            confirmLabel: SchedulingBookingWriteCopy.cancelConfirm,
            destructive: true,
            confirmIdentifier: A11yID.SchedulingWritesB.bookingCancelConfirm,
            state: model.state
        ) {
            VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
                SettingsField(
                    label: SchedulingBookingWriteCopy.cancelReasonLabel,
                    text: Binding(get: { model.reason }, set: { model.editReason($0) }),
                    enabled: !model.busy,
                    multiline: true
                )
                .accessibilityIdentifier(A11yID.SchedulingWritesB.bookingCancelReason)
                SchedulingWriteHint(text: SchedulingBookingWriteCopy.cancelReasonHint)
                SchedulingWriteRejection(message: model.reasonRejected)
            }
        } onCancel: {
            onClose()
        } onConfirm: {
            Task { await model.submit() }
        }
        .accessibilityIdentifier(A11yID.SchedulingWritesB.bookingCancelSheet)
    }
}

/// Ask for a booking's meeting notes to be written again.
///
/// ⛔ A BUTTON, NOT A DIALOG, WHICH IS THE WEB'S SHAPE AND IS CORRECT: nothing is
/// destroyed. ⚠️ And the sentence it leaves behind says the work was QUEUED rather
/// than done — the op returns while `status` is still `pending`, so a screen
/// claiming new notes exist would be wrong for as long as the job takes.
struct SchedulingBookingRegenerateNotesButton: View {
    @Bindable var model: SchedulingBookingNotesModel

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            Button(SchedulingBookingWriteCopy.regenerate) {
                Task { await model.regenerate() }
            }
            .buttonStyle(.districtSecondary)
            .disabled(model.busy)
            .accessibilityIdentifier(A11yID.SchedulingWritesB.bookingRegenerateNotes)
            SchedulingWriteOutcome(state: model.state)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
