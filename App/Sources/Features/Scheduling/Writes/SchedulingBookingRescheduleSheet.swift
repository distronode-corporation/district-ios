import DistrictModel
import SwiftUI

/// Pick a day, then a free time on it.
///
/// ⛔ THE SLOTS ARE RE-READ ON EVERY DAY CHANGE AND NOT FILTERED LOCALLY. The op
/// takes `from` and `to` as one date and the fork computes availability from rules
/// this client does not have; a cached week filtered on device would be showing a
/// diary that has moved.
///
/// ⚠️ THE TIMES ARE RENDERED IN THE ZONE THE SLOTS WERE ASKED FOR, not the
/// device's. Those are usually the same and are not always: an operator travelling
/// still publishes windows in their profile's zone, and a sheet that quietly
/// switched would move every booking by the offset.
struct SchedulingBookingRescheduleSheet: View {
    @Bindable var model: SchedulingBookingRescheduleModel
    let onClose: () -> Void

    var body: some View {
        SchedulingWritesBSheet(
            title: SchedulingBookingWriteCopy.rescheduleTitle,
            subtitle: SchedulingBookingWriteCopy.rescheduleBody,
            cancelLabel: SchedulingBookingWriteCopy.rescheduleCancel,
            confirmLabel: SchedulingBookingWriteCopy.rescheduleConfirm,
            confirmEnabled: model.selectedStart != nil,
            confirmIdentifier: A11yID.SchedulingWritesB.bookingRescheduleConfirm,
            state: model.state
        ) {
            VStack(alignment: .leading, spacing: DistrictSpacing.row) {
                day
                times
                SchedulingWritesBRejection(message: model.selectionRejected)
            }
        } onCancel: {
            onClose()
        } onConfirm: {
            Task { await model.submit() }
        }
        .accessibilityIdentifier(A11yID.SchedulingWritesB.bookingRescheduleSheet)
        .task { await model.loadSlots() }
    }

    /// ⚠️ `displayedComponents: .date` ONLY. The time half of the picker would
    /// suggest an operator may choose any minute, and the whole point of the tile
    /// list below is that they may not.
    private var day: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            DatePicker(
                SchedulingBookingWriteCopy.rescheduleDayLabel,
                selection: Binding(get: { model.day }, set: { model.editDay($0) }),
                displayedComponents: .date
            )
            .disabled(model.busy)
            .accessibilityIdentifier(A11yID.SchedulingWritesB.bookingRescheduleDay)
            // ⛔ THE RELOAD IS DRIVEN BY THE RESOLVED `dayKey`, NOT BY THE `Date`.
            // A `DatePicker` emits a new `Date` for a change of minute as well as
            // of day; keying on the formatted date is what stops one tap becoming
            // several identical requests.
            .onChange(of: model.dayKey) { _, _ in
                Task { await model.loadSlots() }
            }
        }
    }

    @ViewBuilder
    private var times: some View {
        switch model.slots {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .ready(rows):
            if rows.isEmpty {
                SchedulingWritesBHint(text: SchedulingBookingWriteCopy.rescheduleNoSlots)
            } else {
                tiles(rows)
            }
        case let .failed(failure):
            FailureView(failure: failure, onRetry: { Task { await model.loadSlots() } })
        }
    }

    private func tiles(_ rows: [SchedulingSlot]) -> some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.tight) {
            Text(SchedulingBookingWriteCopy.rescheduleTimeLabel)
                .font(DistrictType.labelSmall)
            ForEach(rows, id: \.start) { slot in
                Button(model.label(for: slot.start)) {
                    model.select(slot)
                }
                .buttonStyle(.districtSecondary)
                .disabled(model.busy)
                // ⚠️ THE SELECTION IS SPOKEN, NOT ONLY DRAWN. A tile that reads
                // identically whether or not it is chosen is a picker VoiceOver
                // cannot use.
                .accessibilityAddTraits(model.selectedStart == slot.start ? [.isSelected] : [])
                .accessibilityIdentifier(
                    A11yID.row(A11yID.SchedulingWritesB.bookingRescheduleSlot, slot.start)
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
