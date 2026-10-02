import DistrictData
import SwiftUI

/// Days off and different hours, listed ahead and added one at a time.
///
/// ⛔ A RANGE IS ONE ROW AND ONE DELETE. `availability.overrides.delete` removes a
/// single day, so a fortnight booked as a range would otherwise be fourteen rows
/// and fourteen ways to half-cancel a holiday. The rows are collapsed by
/// `group_id` in the model.
struct SchedulingAvailabilityOverridesSheet: View {
    let model: SchedulingAvailabilityOverridesModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DistrictSpacing.row) {
                header
                list
                messages
                Button(SchedulingWriteCopy.cancel) {
                    dismiss()
                }
                .buttonStyle(.districtGhost)
            }
            .padding(DistrictSpacing.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier(A11yID.SchedulingWrites.overridesRoot)
        .task {
            await model.load()
        }
        .sheet(isPresented: addPresented) {
            addSheet
        }
    }

    /// ⚠️ THE SENTENCE NAMES THE NUMBER OF DAYS on a range, because that is what
    /// somebody is agreeing to lose.
    private var deleteBody: String {
        guard let row = model.confirmingDelete else { return SchedulingWriteCopy.overrideDeleteSingleBody }
        return model.deleteBody(for: row)
    }

    private var addPresented: Binding<Bool> {
        Binding(get: { model.adding != nil }, set: { presented in
            if !presented {
                model.cancelAdd()
            }
        })
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            HStack {
                Text(SchedulingWriteCopy.overridesTitle)
                    .font(DistrictType.title)
                    .foregroundStyle(colors.foreground)
                Spacer(minLength: 0)
                Button(SchedulingWriteCopy.overrideAddButton) {
                    model.beginAdd()
                }
                .buttonStyle(.districtSecondary)
                .accessibilityIdentifier(A11yID.SchedulingWrites.overridesAdd)
            }
            Text(SchedulingWriteCopy.overridesHint)
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
        }
    }

    @ViewBuilder
    private var list: some View {
        if model.rows.isEmpty {
            Text(SchedulingWriteCopy.overridesEmpty)
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
        } else {
            ForEach(model.rows, id: \.key) { row in
                overrideRow(row)
            }
        }
    }

    private func overrideRow(_ row: SchedulingOverrideRow) -> some View {
        HStack(spacing: DistrictSpacing.tight) {
            VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
                Text(row.start == row.end ? row.start : "\(row.start) to \(row.end)")
                    .font(DistrictType.titleSmall)
                    .foregroundStyle(colors.foreground)
                Text(SchedulingHoursFormat.overrideHours(row))
                    .font(DistrictType.caption)
                    .foregroundStyle(colors.mutedForeground)
            }
            Spacer(minLength: 0)
            Button(SchedulingWriteCopy.delete) {
                model.beginDelete(row)
            }
            .buttonStyle(.districtGhost)
            // ⚠️ ONE DIALOG PER ROW, PRESENTED ONLY FOR THE ROW BEING DELETED, so the
            // popover a regular-width layout draws points at its button. See
            // ``SwiftUI/Binding/dialog(_:onDismiss:)``.
            .confirmationDialog(
                SchedulingWriteCopy.overrideDeleteTitle,
                isPresented: .dialog(model.confirmingDelete?.key == row.key, onDismiss: model.cancelDelete),
                titleVisibility: .visible
            ) {
                Button(SchedulingWriteCopy.overrideDeleteConfirm, role: .destructive) {
                    Task { await model.delete() }
                }
                Button(SchedulingWriteCopy.cancel, role: .cancel) {
                    model.cancelDelete()
                }
            } message: {
                Text(deleteBody)
            }
        }
        .padding(.vertical, DistrictSpacing.hairline)
        .accessibilityIdentifier(A11yID.SchedulingWrites.overrideRow(row.key))
    }

    private var messages: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            SchedulingWriteOutcome(state: model.loadState)
            SchedulingWriteOutcome(state: model.state, onDismiss: model.dismissNotice)
        }
    }

    // MARK: - Adding one

    @ViewBuilder
    private var addSheet: some View {
        if let form = model.adding {
            SchedulingWriteSheet(title: SchedulingWriteCopy.overrideAddTitle) {
                addFields(form)
                SchedulingWriteRejection(message: model.validation)
                SchedulingWriteButtons(
                    saveTitle: SchedulingWriteCopy.overrideAddButton,
                    saving: model.state.isWorking,
                    saveIdentifier: A11yID.SchedulingWrites.overridesSubmit,
                    onCancel: { model.cancelAdd() },
                    onSave: { Task { await model.submit() } }
                )
            }
        }
    }

    /// ⛔ THE KIND DECIDES WHICH FIELDS EXIST. A range of custom hours is refused by
    /// the fork, so the last-day field is not offered for it at all rather than
    /// offered and ignored.
    @ViewBuilder
    private func addFields(_ form: SchedulingOverrideForm) -> some View {
        SchedulingWriteField(label: SchedulingWriteCopy.overrideKindLabel) {
            Picker(
                SchedulingWriteCopy.overrideKindLabel,
                selection: Binding(
                    get: { form.reason },
                    set: { value in model.updateAdding { $0.reason = value } }
                )
            ) {
                ForEach(SchedulingWriteCopy.overrideKinds, id: \.reason) { kind in
                    Text(kind.label).tag(kind.reason)
                }
            }
            .pickerStyle(.menu)
        }
        SchedulingWriteField(
            label: form.isCustomHours
                ? SchedulingWriteCopy.overrideDateLabel
                : SchedulingWriteCopy.overrideFirstDayLabel
        ) {
            TextField(
                "2026-09-12",
                text: Binding(
                    get: { form.date },
                    set: { value in model.updateAdding { $0.date = value } }
                )
            )
            .districtField()
            .accessibilityIdentifier(A11yID.SchedulingWrites.overridesDate)
        }
        if form.isCustomHours {
            customHours(form)
        } else {
            SchedulingWriteField(
                label: SchedulingWriteCopy.overrideLastDayLabel,
                hint: SchedulingWriteCopy.overrideLastDayHint
            ) {
                TextField(
                    "2026-09-14",
                    text: Binding(
                        get: { form.endDate },
                        set: { value in model.updateAdding { $0.endDate = value } }
                    )
                )
                .districtField()
                .accessibilityIdentifier(A11yID.SchedulingWrites.overridesEndDate)
            }
        }
    }

    private func customHours(_ form: SchedulingOverrideForm) -> some View {
        SchedulingWriteField(label: SchedulingWriteCopy.overrideHoursLabel) {
            HStack(spacing: DistrictSpacing.tight) {
                TextField(
                    SchedulingWorkingHours.defaultStart,
                    text: Binding(
                        get: { form.start },
                        set: { value in model.updateAdding { $0.start = value } }
                    )
                )
                .districtField()
                Text("to")
                    .font(DistrictType.caption)
                    .foregroundStyle(colors.mutedForeground)
                TextField(
                    SchedulingWorkingHours.defaultEnd,
                    text: Binding(
                        get: { form.end },
                        set: { value in model.updateAdding { $0.end = value } }
                    )
                )
                .districtField()
            }
        }
    }
}
