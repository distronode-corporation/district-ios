import DistrictModel
import SwiftUI

/// Close one scheduler account, once nothing is standing in the way.
///
/// ⛔ IT SHOWS THE BLOCKING BOOKINGS RATHER THAN JUST REFUSING. The fork's 409 is
/// the design — reassign or cancel, then archive — so the sheet's job is to make
/// the first step possible: every upcoming booking is listed, with who it is with
/// and when, which is what an operator needs in order to go and move them.
struct SchedulingUserArchiveSheet: View {
    @Bindable var model: SchedulingUserArchiveModel
    let userName: String
    let onClose: () -> Void

    @State private var confirming = false

    var body: some View {
        SchedulingWriteSheet(
            title: SchedulingTeamWriteCopy.archiveTitle(userName),
            subtitle: SchedulingTeamWriteCopy.archiveBody,
            cancelLabel: SchedulingTeamWriteCopy.archiveKeep,
            confirmLabel: SchedulingTeamWriteCopy.archiveConfirm,
            destructive: true,
            confirmEnabled: model.canArchive,
            confirmIdentifier: A11yID.SchedulingWritesB.userArchiveConfirm,
            state: model.state
        ) {
            VStack(alignment: .leading, spacing: DistrictSpacing.row) {
                blocked
                upcoming
            }
        } onCancel: {
            onClose()
        } onConfirm: {
            confirming = true
        }
        .accessibilityIdentifier(A11yID.SchedulingWritesB.userArchiveSheet)
        .task { await model.loadUpcoming() }
        .confirmationDialog(
            SchedulingTeamWriteCopy.archiveTitle(userName),
            isPresented: $confirming,
            titleVisibility: .visible
        ) {
            Button(SchedulingTeamWriteCopy.archiveConfirm, role: .destructive) {
                Task { await model.archive() }
            }
            Button(SchedulingTeamWriteCopy.archiveKeep, role: .cancel) {}
        } message: {
            Text(SchedulingTeamWriteCopy.archiveBody)
        }
    }

    /// ⚠️ SAYS WHY A DISABLED BUTTON IS DISABLED. A control that is simply inert
    /// reads as broken, and here it is inert for a reason the operator can act on.
    @ViewBuilder
    private var blocked: some View {
        if let reason = model.blockedReason {
            SchedulingWriteHint(text: reason)
        }
    }

    @ViewBuilder
    private var upcoming: some View {
        switch model.upcoming {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .ready(rows):
            // ⚠️ AN EMPTY LIST DRAWS NOTHING, DELIBERATELY. "No upcoming bookings"
            // beside a live Archive button is a sentence nobody needs; the enabled
            // button already says it.
            VStack(alignment: .leading, spacing: DistrictSpacing.tight) {
                ForEach(rows, id: \.id) { booking in
                    row(booking)
                }
            }
        case let .failed(failure):
            // ⛔ A FAILED READ IS NOT AN EMPTY DIARY, AND ``canArchive`` ALREADY
            // REFUSES ON IT. Drawing the failure is what stops "we could not look"
            // reading as "there is nothing".
            FailureView(failure: failure, onRetry: { Task { await model.loadUpcoming() } })
        }
    }

    private func row(_ booking: SchedulingUpcomingBooking) -> some View {
        SettingsReadOnlyRow(
            label: booking.eventTypeName,
            value: "\(booking.attendeeName) · \(booking.startAt)"
        )
    }
}
