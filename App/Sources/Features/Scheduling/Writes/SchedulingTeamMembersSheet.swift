import DistrictModel
import SwiftUI

/// One team's roster: add a host, reorder the rotation, take somebody out.
///
/// ⚠️ EVERY CONTROL HERE SAVES ON ITS OWN BUTTON, so the sheet's dismissal is
/// "Done" rather than "Cancel" — see ``SchedulingTeamWriteCopy/close``.
struct SchedulingTeamMembersSheet: View {
    @Bindable var model: SchedulingTeamMembersModel
    let onClose: () -> Void

    @State private var removing: SchedulingTeamMember?

    var body: some View {
        SchedulingWriteSheet(
            title: model.team.name,
            subtitle: SchedulingTeamWriteCopy.membersHint,
            cancelLabel: SchedulingTeamWriteCopy.close,
            confirmLabel: SchedulingTeamWriteCopy.add,
            confirmEnabled: model.pickedUserId != nil,
            confirmIdentifier: A11yID.SchedulingWritesB.teamMemberAdd,
            state: model.state
        ) {
            VStack(alignment: .leading, spacing: DistrictSpacing.section) {
                roster
                addPicker
            }
        } onCancel: {
            onClose()
        } onConfirm: {
            Task { await model.addMember() }
        }
        .accessibilityIdentifier(A11yID.SchedulingWritesB.teamMembersSheet)
        .task { await model.loadUsers() }
    }

    @ViewBuilder
    private var roster: some View {
        if model.members.isEmpty {
            SchedulingWriteHint(text: SchedulingTeamWriteCopy.membersEmpty)
        } else {
            VStack(alignment: .leading, spacing: DistrictSpacing.row) {
                ForEach(model.members, id: \.id) { member in
                    row(member)
                }
            }
        }
    }

    private func row(_ member: SchedulingTeamMember) -> some View {
        SettingsCard(eyebrow: member.name.isEmpty ? member.email : member.name) {
            VStack(alignment: .leading, spacing: DistrictSpacing.tight) {
                SettingsField(
                    label: SchedulingTeamWriteCopy.priorityLabel,
                    text: Binding(
                        get: { model.priorityDrafts[member.id] ?? "" },
                        set: { model.editPriority($0, for: member.id) }
                    ),
                    enabled: !model.busy
                )
                // ⚠️ NUMERIC KEYBOARD, NOT A `Stepper`. The field has to be able to
                // hold "" and "2.5" long enough to refuse them by name, which is
                // what `parsePriority` does on the web; a stepper cannot express an
                // invalid value and so cannot teach the rule.
                .keyboardType(.numberPad)
                .accessibilityIdentifier(
                    A11yID.row(A11yID.SchedulingWritesB.teamMemberPriority, member.id)
                )
                SchedulingWriteRejection(message: model.priorityRejected[member.id])
                HStack(spacing: DistrictSpacing.tight) {
                    Button(SchedulingTeamWriteCopy.savePriority) {
                        Task { await model.savePriority(for: member.id) }
                    }
                    .buttonStyle(.districtSecondary)
                    .disabled(model.busy)
                    Button(SchedulingTeamWriteCopy.remove) { removing = member }
                        .buttonStyle(.districtDestructive)
                        .disabled(model.busy)
                        .accessibilityIdentifier(
                            A11yID.row(A11yID.SchedulingWritesB.teamMemberRemove, member.id)
                        )
                        .confirmationDialog(
                            SchedulingTeamWriteCopy.removeTitle,
                            isPresented: .dialog(removing?.id == member.id) { removing = nil },
                            titleVisibility: .visible
                        ) {
                            Button(SchedulingTeamWriteCopy.remove, role: .destructive) {
                                Task { await model.removeMember(member.id) }
                                removing = nil
                            }
                            Button(SchedulingTeamWriteCopy.removeKeep, role: .cancel) { removing = nil }
                        } message: {
                            Text(SchedulingTeamWriteCopy.removeBody)
                        }
                }
            }
        }
    }

    @ViewBuilder
    private var addPicker: some View {
        switch model.users {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, alignment: .leading)
        case .ready:
            if model.addable.isEmpty {
                SchedulingWriteHint(text: SchedulingTeamWriteCopy.addNone)
            } else {
                candidates
            }
        case let .failed(failure):
            FailureView(failure: failure, onRetry: { Task { await model.loadUsers() } })
        }
    }

    private var candidates: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.tight) {
            Text(SchedulingTeamWriteCopy.addLabel)
                .font(DistrictType.labelSmall)
            ForEach(model.addable, id: \.id) { user in
                Button(SchedulingBookingReassignModel.label(for: user)) {
                    model.pick(user.id)
                }
                .buttonStyle(.districtSecondary)
                .disabled(model.busy)
                .accessibilityAddTraits(model.pickedUserId == user.id ? [.isSelected] : [])
                .accessibilityIdentifier(
                    A11yID.row(A11yID.SchedulingWritesB.teamMemberPicker, user.id)
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
