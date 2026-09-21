import DistrictModel
import SwiftUI

/// Hand one booking to a different host.
///
/// ⚠️ THE CALLER OWNS THE ROLE GATE. The fork answers 403 "admin access required"
/// for a non-admin scheduler user, and the web offers this control only when the
/// signed-in scheduler profile says `is_admin` — not on District's own workspace
/// role, which is a different vocabulary entirely. This sheet renders whatever it
/// is given; it must not be presented to somebody who will be refused.
struct SchedulingBookingReassignSheet: View {
    @Bindable var model: SchedulingBookingReassignModel
    let onClose: () -> Void

    var body: some View {
        SchedulingWritesBSheet(
            title: SchedulingBookingWriteCopy.reassignTitle,
            subtitle: SchedulingBookingWriteCopy.reassignBody,
            cancelLabel: SchedulingBookingWriteCopy.reassignCancel,
            confirmLabel: SchedulingBookingWriteCopy.reassignConfirm,
            confirmEnabled: model.canSubmit,
            confirmIdentifier: A11yID.SchedulingWritesB.bookingReassignConfirm,
            state: model.state
        ) {
            hosts
        } onCancel: {
            onClose()
        } onConfirm: {
            Task { await model.submit() }
        }
        .accessibilityIdentifier(A11yID.SchedulingWritesB.bookingReassignSheet)
        .task { await model.loadHosts() }
    }

    @ViewBuilder
    private var hosts: some View {
        switch model.hosts {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .ready(rows):
            if rows.isEmpty {
                // ⚠️ NOT AN ERROR. Every other scheduler user is archived or is
                // already this booking's host, which is a fact about the tenancy
                // rather than a failure to look.
                SchedulingWritesBHint(text: SchedulingBookingWriteCopy.reassignNoHosts)
            } else {
                picker(rows)
            }
        case let .failed(failure):
            FailureView(failure: failure, onRetry: { Task { await model.loadHosts() } })
        }
    }

    /// ⛔ A ROW PER HOST RATHER THAN A `Picker`. The labels are people's names and
    /// fall back to email addresses, which a wheel or a menu truncates — and the
    /// house rule elsewhere on this app is the same for the same reason.
    private func picker(_ rows: [SchedulingUser]) -> some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.tight) {
            Text(SchedulingBookingWriteCopy.reassignHostLabel)
                .font(DistrictType.labelSmall)
            ForEach(rows, id: \.id) { user in
                Button(SchedulingBookingReassignModel.label(for: user)) {
                    model.select(user.id)
                }
                .buttonStyle(.districtSecondary)
                .disabled(model.busy)
                .accessibilityAddTraits(model.selectedHostId == user.id ? [.isSelected] : [])
                .accessibilityIdentifier(
                    A11yID.row(A11yID.SchedulingWritesB.bookingReassignHost, user.id)
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
