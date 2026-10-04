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
