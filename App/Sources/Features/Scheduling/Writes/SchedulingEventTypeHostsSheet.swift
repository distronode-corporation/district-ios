import DistrictModel
import SwiftUI

/// Who can be booked on this event type, and how the next booking reaches them.
///
/// ⚠️ THE ROWS ARE IN THE ORDER THE FORK SERVED THEM AND THERE IS NO DRAG. The
/// only ordering signal is `priority`, and the fork reads it only under the
/// `priority` rotation strategy.
struct SchedulingEventTypeHostsSheet: View {
    let model: SchedulingEventTypeHostsModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        SchedulingWriteSheet(title: SchedulingWriteCopy.hostsTitle) {
            routing
            rows
            addPicker
            messages
            SchedulingWriteButtons(
                saveTitle: SchedulingWriteCopy.save,
                saving: model.state.isWorking,
                saveIdentifier: A11yID.SchedulingWrites.hostsSave,
                onCancel: { dismiss() },
                onSave: { save() }
            )
        }
        .accessibilityIdentifier(A11yID.SchedulingWrites.hostsRoot)
        .task {
            await model.load()
        }
    }

    @ViewBuilder
    private var routing: some View {
        SchedulingWriteField(label: SchedulingWriteCopy.routingModeLabel) {
            Picker(
                SchedulingWriteCopy.routingModeLabel,
                selection: Binding(
                    get: { model.routingMode },
                    set: { model.routingMode = $0 }
                )
            ) {
                ForEach(SchedulingWriteCopy.routingModes, id: \.value) { mode in
                    Text(mode.label).tag(mode.value)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier(A11yID.SchedulingWrites.hostsMode)
        }
        if model.showsRotationStrategy {
            SchedulingWriteField(
                label: SchedulingWriteCopy.rotationLabel,
                hint: SchedulingWriteCopy.rotationHint
            ) {
                Picker(
                    SchedulingWriteCopy.rotationLabel,
                    selection: Binding(
                        get: { model.rotationStrategy },
                        set: { model.rotationStrategy = $0 }
                    )
                ) {
                    ForEach(SchedulingWriteCopy.rotationStrategies, id: \.value) { strategy in
                        Text(strategy.label).tag(strategy.value)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier(A11yID.SchedulingWrites.hostsStrategy)
            }
        }
    }

    @ViewBuilder
    private var rows: some View {
        if model.isEmpty {
            Text(SchedulingWriteCopy.hostsEmpty)
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
        } else {
            ForEach(model.rows) { row in
                hostRow(row)
            }
        }
    }

    private func hostRow(_ row: SchedulingHostRow) -> some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            Text(row.name)
                .font(DistrictType.titleSmall)
                .foregroundStyle(colors.foreground)
            Text(row.email)
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
            HStack(spacing: DistrictSpacing.tight) {
                Picker(
                    SchedulingWriteCopy.hostsTitle,
                    selection: Binding(
                        get: { row.role },
                        set: { model.setRole($0, for: row.userId) }
                    )
                ) {
                    ForEach(SchedulingWriteCopy.hostRoles, id: \.value) { role in
                        Text(role.label).tag(role.value)
                    }
                }
                .pickerStyle(.menu)
                TextField(
                    SchedulingWriteCopy.priorityLabel,
                    text: Binding(
                        get: { row.priority },
                        set: { model.setPriority($0, for: row.userId) }
                    )
                )
                .districtField()
                .keyboardType(.numberPad)
                Button(SchedulingWriteCopy.remove) {
                    model.remove(row.userId)
                }
                .buttonStyle(.districtGhost)
            }
        }
        .padding(.vertical, DistrictSpacing.hairline)
        .accessibilityIdentifier(A11yID.SchedulingWrites.host(row.userId))
    }

    /// ⚠️ HIDDEN WHEN THE DIRECTORY READ WAS REFUSED, not disabled. `users.list` is
    /// admin-only at the fork; a host who may edit this table and may not list the
    /// tenancy is shown the table and no add control, which is what the web does.
    @ViewBuilder
    private var addPicker: some View {
        if model.canAddHosts, !model.candidates.isEmpty {
            Menu(SchedulingWriteCopy.add) {
                ForEach(model.candidates, id: \.id) { user in
                    Button(user.name.isEmpty ? user.email : user.name) {
                        model.add(user)
                    }
                }
            }
        }
    }

    private var messages: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            SchedulingWriteOutcome(state: model.loadState)
            SchedulingWriteRejection(message: model.validation)
            SchedulingWriteOutcome(state: model.state, onDismiss: model.dismissNotice)
        }
    }

    private func save() {
        Task {
            await model.save()
            if case .done = model.state {
                dismiss()
            }
        }
    }
}
