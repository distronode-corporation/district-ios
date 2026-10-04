import DistrictData
import DistrictModel
import SwiftUI

/// The three writes a booking row carries: cancel, reschedule, reassign.
///
/// ⛔ IT LIVES ON THE LIST BECAUSE THE LIST IS WHERE THE BOOKING IS. Two of the
/// three need fields no other read answers — the reschedule needs the event type's
/// SLUG to ask for slots, the reassign needs the current host so it can be left out
/// of the candidates — and `bookings.list` is the only op that carries them. The
/// detail screen addresses a booking by id alone, which is why it offers only the
/// write that needs nothing else (see ``SchedulingBookingCancelButton``).
///
/// ⛔ AND THE GATE IS TWO TESTS, NOT ONE. `client` clears the server's bar; after
/// that ``SchedulingBookingFormat/isActionable(_:now:)`` decides, on `end_at`, which
/// is why a meeting that started ten minutes ago is still cancellable and one that
/// ended ten minutes ago is not. A cancelled booking is not actionable either.
///
/// ⚠️ REASSIGN IS NARROWER AGAIN, AND ON A DIFFERENT AUTHORITY. The web offers it
/// only where the SCHEDULER reports `is_admin`, which is not the District role; the
/// list model reads it from `me.get` and hands it down here.
struct SchedulingBookingWriteBar: View {
    let admin: SchedulingAdminRepository
    let workspaceId: String
    let booking: SchedulingBooking
    let timezone: String
    let mayReassign: Bool
    let onChanged: () -> Void

    @State private var cancelling: SchedulingWritePresentation<SchedulingBookingCancelModel>?
    @State private var rescheduling: SchedulingWritePresentation<SchedulingBookingRescheduleModel>?
    @State private var reassigning: SchedulingWritePresentation<SchedulingBookingReassignModel>?

    var body: some View {
        HStack(spacing: DistrictSpacing.tight) {
            Button(SchedulingBookingWriteCopy.cancelConfirm) {
                cancelling = SchedulingWritePresentation(model: cancelModel())
            }
            .buttonStyle(.districtGhost)
            .accessibilityIdentifier(A11yID.SchedulingWriteEntry.bookingCancel)
            reschedule
            if mayReassign {
                Button(SchedulingBookingWriteCopy.reassignConfirm) {
                    reassigning = SchedulingWritePresentation(model: reassignModel())
                }
                .buttonStyle(.districtGhost)
                .accessibilityIdentifier(A11yID.SchedulingWriteEntry.bookingReassign)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $cancelling) { entry in
            SchedulingBookingCancelSheet(model: entry.model) { cancelling = nil }
        }
        .sheet(item: $rescheduling) { entry in
            SchedulingBookingRescheduleSheet(model: entry.model) { rescheduling = nil }
        }
        .sheet(item: $reassigning) { entry in
            SchedulingBookingReassignSheet(model: entry.model) { reassigning = nil }
        }
    }

    /// ⛔ ABSENT WITHOUT A SLUG. `eventTypes.slots` is addressed by slug and the
    /// field is optional on the booking, so a row whose event type the fork did not
    /// name cannot be offered a time to move to — and a button that could only fail
    /// is worse than none.
    @ViewBuilder
    private var reschedule: some View {
        if booking.eventTypeSlug != nil {
            Button(SchedulingBookingWriteCopy.rescheduleConfirm) {
                rescheduling = SchedulingWritePresentation(model: rescheduleModel())
            }
            .buttonStyle(.districtGhost)
            .accessibilityIdentifier(A11yID.SchedulingWriteEntry.bookingReschedule)
        }
    }

    private func cancelModel() -> SchedulingBookingCancelModel {
        SchedulingBookingCancelModel(
            admin: admin,
            workspaceId: workspaceId,
            bookingId: booking.id,
            onSaved: { _ in onChanged() }
        )
    }

    private func rescheduleModel() -> SchedulingBookingRescheduleModel {
        SchedulingBookingRescheduleModel(
            admin: admin,
            workspaceId: workspaceId,
            bookingId: booking.id,
            eventTypeSlug: booking.eventTypeSlug ?? "",
            timezone: timezone,
            onSaved: { _ in onChanged() }
        )
    }

    private func reassignModel() -> SchedulingBookingReassignModel {
        SchedulingBookingReassignModel(
            admin: admin,
            workspaceId: workspaceId,
            bookingId: booking.id,
            currentHostId: booking.hostId,
            onSaved: { _ in onChanged() }
        )
    }
}

/// Cancel, from a screen that holds the booking's id and nothing else.
///
/// ⚠️ THE SAME MODEL AND THE SAME SHEET AS THE LIST'S. `bookings.cancel` takes the
/// id and an optional reason, so the detail screen can offer it in full without the
/// row — which the reschedule and the reassign cannot.
struct SchedulingBookingCancelButton: View {
    let admin: SchedulingAdminRepository
    let workspaceId: String
    let bookingId: String
    let onChanged: () -> Void

    @State private var cancelling: SchedulingWritePresentation<SchedulingBookingCancelModel>?

    var body: some View {
        Button(SchedulingBookingWriteCopy.cancelConfirm) {
            cancelling = SchedulingWritePresentation(model: makeModel())
        }
        .buttonStyle(.districtGhost)
        .accessibilityIdentifier(A11yID.SchedulingWriteEntry.bookingCancel)
        .sheet(item: $cancelling) { entry in
            SchedulingBookingCancelSheet(model: entry.model) { cancelling = nil }
        }
    }

    private func makeModel() -> SchedulingBookingCancelModel {
        SchedulingBookingCancelModel(
            admin: admin,
            workspaceId: workspaceId,
            bookingId: bookingId,
            onSaved: { _ in onChanged() }
        )
    }
}
