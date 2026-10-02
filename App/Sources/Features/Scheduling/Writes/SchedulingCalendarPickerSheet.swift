import DistrictModel
import SwiftUI

/// "Calendars in <account>" — which are checked for conflicts, and which receives
/// new bookings.
///
/// ⛔ THE WHOLE LIST IS SENT BACK ON SAVE. The PUT is a replace, so a calendar left
/// out is a calendar turned off; the model holds every row it read and edits them
/// in place, and this sheet never builds an array from the one row somebody tapped.
///
/// ⚠️ ONLY WRITABLE CALENDARS ARE OFFERED AS A DESTINATION, and `writable == nil`
/// counts as writable: the flag is ABSENT on a row the fork did not describe, and
/// reading absence as "read only" would hide a primary calendar.
struct SchedulingCalendarPickerSheet: View {
    let model: SchedulingCalendarPickerModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        SchedulingWriteSheet(title: SchedulingWriteCopyC.calendarsTitle(model.connection.accountEmail)) {
            content
        }
        .task { await model.load() }
    }

    @ViewBuilder
    private var content: some View {
        if let rows = model.rows {
            conflicts(rows)
            destinations
            messages
            buttons
        } else if let failure = model.failure {
            SchedulingWriteFailureLine(failure: failure, onRetry: reload)
        } else {
            LoadingView(message: SchedulingWriteCopyC.calendarsLoading)
        }
    }

    // MARK: - Sections

    private func conflicts(_ rows: [SchedulingCalendarSelection]) -> some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            Text(SchedulingWriteCopyC.calendarsConflictsLabel)
                .font(DistrictType.labelSmall)
                .foregroundStyle(colors.mutedForeground)
            Text(SchedulingWriteCopyC.calendarsConflictsHint)
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
            ForEach(rows, id: \.id) { row in
                SchedulingWriteToggleRow(
                    label: row.name,
                    isOn: conflictBinding(row.id),
                    enabled: !model.busy
                )
                .accessibilityIdentifier(A11yID.SchedulingCalendarWrites.conflict(row.id))
            }
        }
    }

    /// ⛔ A CHOICE WITH NO "none" OPTION, BECAUSE THERE IS NO CALL THAT CLEARS A
    /// DESTINATION. Exactly one connection holds it and the write is a move; a
    /// control offering to deselect would offer something the API cannot do.
    private var destinations: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            Text(SchedulingWriteCopyC.calendarsDestinationLabel)
                .font(DistrictType.labelSmall)
                .foregroundStyle(colors.mutedForeground)
            Text(SchedulingWriteCopyC.calendarsDestinationHint)
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
            ForEach(model.destinationChoices, id: \.id) { row in
                destinationRow(row)
            }
        }
    }

    private func destinationRow(_ row: SchedulingCalendarSelection) -> some View {
        let chosen = model.destinationId == row.id
        return Button {
            model.chooseDestination(row.id)
        } label: {
            HStack(spacing: DistrictSpacing.tight) {
                Image(systemName: chosen ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(chosen ? colors.district : colors.mutedForeground)
                    // ⚠️ HIDDEN BECAUSE THE ROW ALREADY SAYS IT. The button carries
                    // `.isSelected` when it is the destination, which is what VoiceOver
                    // announces; the glyph on top of that is "largecircle fill circle"
                    // read before the calendar's name.
                    .accessibilityHidden(true)
                Text(row.name)
                    .font(DistrictType.bodySmall)
                    .foregroundStyle(colors.foreground)
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
        .disabled(model.busy)
        .accessibilityAddTraits(chosen ? [.isSelected, .isButton] : .isButton)
        .accessibilityIdentifier(A11yID.SchedulingCalendarWrites.destination(row.id))
    }

    @ViewBuilder
    private var messages: some View {
        if let failure = model.failure {
            SchedulingWriteFailureLine(
                failure: failure,
                onRetry: save,
                onDismiss: model.dismissFailure
            )
        }
        if model.saved {
            SchedulingWriteNoticeLine(message: SchedulingWriteCopyC.calendarsSaved)
        }
    }

    private var buttons: some View {
        HStack(spacing: DistrictSpacing.tight) {
            Button(SchedulingWriteCopyC.cancel) { dismiss() }
                .buttonStyle(.districtGhost)
                .disabled(model.busy)
            Button(
                model.busy ? SchedulingWriteCopyC.calendarsSaving : SchedulingWriteCopyC.calendarsSaveAction,
                action: save
            )
            .buttonStyle(.districtPrimary)
            .disabled(!model.canSave)
            .accessibilityIdentifier(A11yID.SchedulingCalendarWrites.calendarsSave)
        }
    }

    // MARK: - Wiring

    private func conflictBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { model.rows?.first { $0.id == id }?.checkConflicts == true },
            set: { model.setCheckConflicts(id, on: $0) }
        )
    }

    private func reload() {
        Task { await model.load() }
    }

    private func save() {
        Task { await model.save() }
    }
}
