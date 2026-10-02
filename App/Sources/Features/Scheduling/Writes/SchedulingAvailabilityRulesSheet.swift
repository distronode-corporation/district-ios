import SwiftUI

/// The weekly working hours: seven rows, Monday first, each holding as many
/// windows as the member wants.
///
/// ⛔ MONDAY FIRST ON SCREEN, SUNDAY FIRST ON THE WIRE. The conversion lives in
/// ``SchedulingWorkingHours`` and nowhere else; a row index used as a
/// `day_of_week` publishes somebody's Monday hours on Sunday.
///
/// ⚠️ THE TIMES ARE PLAIN TEXT FIELDS AND NOT A `DatePicker`. They are zero-padded
/// `HH:MM` wall-clock strings in the MEMBER'S scheduler timezone — not instants,
/// and not the device's zone — so a picker bound to a `Date` would have to invent
/// a day and a zone to hold one, and would then render a travelling member's
/// published hours shifted with nothing on screen saying so.
struct SchedulingAvailabilityRulesSheet: View {
    let model: SchedulingAvailabilityRulesModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        SchedulingWriteSheet(title: SchedulingWriteCopy.hoursTitle) {
            ForEach(Array(SchedulingWriteCopy.weekDayNames.enumerated()), id: \.offset) { index, name in
                dayRow(index, name)
            }
            messages
            SchedulingWriteButtons(
                saveTitle: SchedulingWriteCopy.save,
                saving: model.state.isWorking,
                enabled: model.canSave,
                saveIdentifier: A11yID.SchedulingWrites.hoursSave,
                onCancel: { dismiss() },
                onSave: { Task { await model.save() } }
            )
        }
        .accessibilityIdentifier(A11yID.SchedulingWrites.hoursRoot)
        .task {
            await model.load()
        }
    }

    private func dayRow(_ index: Int, _ name: String) -> some View {
        let ranges = model.week.indices.contains(index) ? model.week[index] : []
        let errors = model.errors(forRow: index)
        return VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            Text(name)
                .font(DistrictType.titleSmall)
                .foregroundStyle(colors.foreground)
            if ranges.isEmpty {
                Text(SchedulingWriteCopy.hoursNotBookable)
                    .font(DistrictType.caption)
                    .foregroundStyle(colors.mutedForeground)
            }
            ForEach(Array(ranges.enumerated()), id: \.element.id) { position, range in
                rangeRow(range, row: index, error: errors.indices.contains(position) ? errors[position] : nil)
            }
            HStack(spacing: DistrictSpacing.tight) {
                Button(SchedulingWriteCopy.hoursAddRange) {
                    model.addRange(toRow: index)
                }
                .buttonStyle(.districtGhost)
                if SchedulingWorkingHours.weekdayRows.contains(index), !ranges.isEmpty {
                    Button(SchedulingWriteCopy.hoursCopyToWeekdays) {
                        model.copyToWeekdays(from: index)
                    }
                    .buttonStyle(.districtGhost)
                }
            }
        }
        .padding(.vertical, DistrictSpacing.hairline)
        .accessibilityIdentifier(A11yID.SchedulingWrites.day(index))
    }

    private func rangeRow(_ range: SchedulingHoursDraftRange, row: Int, error: String?) -> some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            HStack(spacing: DistrictSpacing.tight) {
                TextField(
                    SchedulingWorkingHours.defaultStart,
                    text: Binding(
                        get: { range.start },
                        set: { value in model.setStart(value, for: range.id, inRow: row) }
                    )
                )
                .districtField()
                Text("to")
                    .font(DistrictType.caption)
                    .foregroundStyle(colors.mutedForeground)
                TextField(
                    SchedulingWorkingHours.defaultEnd,
                    text: Binding(
                        get: { range.end },
                        set: { value in model.setEnd(value, for: range.id, inRow: row) }
                    )
                )
                .districtField()
                Button(SchedulingWriteCopy.remove) {
                    model.removeRange(range.id, fromRow: row)
                }
                .buttonStyle(.districtGhost)
            }
            SchedulingWriteRejection(message: error)
        }
    }

    private var messages: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            SchedulingWriteOutcome(state: model.loadState)
            SchedulingWriteOutcome(state: model.state, onDismiss: model.dismissNotice)
        }
    }
}
