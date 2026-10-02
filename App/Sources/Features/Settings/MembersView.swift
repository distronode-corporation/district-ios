import DistrictModel
import SwiftUI

/// Who has access to this workspace, and its name. Ported from Android's
/// `MembersScreen.kt`.
///
/// ⛔ TWO GATES AT TWO WIDTHS ON ONE SCREEN. Every membership write is agency-only —
/// the narrowest allow-list in the API, because these rows are what every other guard
/// is derived from — while the rename admits a client too. So a client sees the roster
/// and the rename box and no add, role or remove control, and that is correct rather
/// than inconsistent.
///
/// ⛔ THE REMOVE IS CONFIRMED AND THE CONFIRMATION NAMES THE CONSEQUENCE. Removing
/// someone ends their access to every call, contact and conversation in this workspace
/// on their next request, and re-adding them is a new row rather than an undo.
///
/// ⛔ THE RENAME BOX STARTS EMPTY AND SAYS SO. Nothing this client can read returns the
/// workspace's current name, so a box seeded from what we know could only be blank —
/// which is the shape that saves a blank over a real value.
struct MembersView: View {
    @State private var model: MembersModel
    @State private var pendingRemoval: WorkspaceMember?
    @State private var confirmingRemoval = false

    @Environment(\.colorScheme) private var colorScheme

    init(container: AppContainer, workspaceId: String, role: WorkspaceRole?) {
        _model = State(initialValue: MembersModel(
            container: container,
            workspaceId: workspaceId,
            role: role
        ))
    }

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DistrictSpacing.section) {
                gateNote
                rosterNotices
                roster
                if model.canManage {
                    addCard
                }
                if model.canRename {
                    renameCard
                }
            }
            .padding(DistrictSpacing.gutter)
            .districtReadableWidth()
        }
        .navigationTitle(SettingsCopy.membersTitle)
        .task {
            await model.load()
        }
    }

    /// ⚠️ TWO DIFFERENT SENTENCES FOR TWO DIFFERENT GATES. A viewer is told they can
    /// read and not change; a client is told the membership controls specifically are
    /// for administrators, because they CAN rename and would otherwise read the viewer
    /// sentence as false.
    @ViewBuilder
    private var gateNote: some View {
        if !model.canRename {
            note(SettingsCopy.membersViewerNote)
        } else if !model.canManage {
            note(SettingsCopy.membersClientNote)
        }
    }

    // MARK: - The roster

    @ViewBuilder
    private var roster: some View {
        switch model.list {
        case .loading:
            SettingsSkeleton()
        case let .ready(rows):
            SettingsCard(eyebrow: SettingsCopy.membersRosterEyebrow) {
                ForEach(rows, id: \.email) { member in
                    memberRow(member)
                }
            }
        case let .failed(failure):
            SettingsLoadFailureView(failure: failure, onRetry: reload)
        }
    }

    /// ⛔ OUTSIDE THE ROSTER SWITCH, AND THAT IS LOAD-BEARING RATHER THAN LAYOUT. Every
    /// membership write re-reads the roster and a failed re-read sets `list` to
    /// `.failed`, so inside `case .ready` a role change or a removal that SUCCEEDED and
    /// could not be read back would show a load-failure view and no notice at all, and
    /// the operator's next move would be to make the change again. ``KnowledgeView`` and
    /// ``CapabilitiesView`` are built the same way.
    private var rosterNotices: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.tight) {
            SettingsSaveNotice(state: model.roleSave, onReread: reload, onDismiss: model.dismissNotices)
            SettingsSaveNotice(state: model.removeSave, onReread: reload, onDismiss: model.dismissNotices)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// ⚠️ THE EMAIL IS THE IDENTITY. The route publishes no row id — `(workspaceId,
    /// email)` is the natural key every membership path uses — so it is what the picker
    /// and the removal carry as well as what is displayed.
    private func memberRow(_ member: WorkspaceMember) -> some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            Text(member.email)
                .font(DistrictType.titleSmall)
                .foregroundStyle(colors.foreground)
            // ⚠️ THE RAW ROLE STRING WHEN IT DOES NOT PARSE, rather than a guess. The
            // column has no server-side enum, so a fourth value is a schema-level
            // possibility and showing it as itself is the honest answer.
            Text(Self.roleText(member))
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
            if model.canManage {
                memberControls(member)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func memberControls(_ member: WorkspaceMember) -> some View {
        HStack(spacing: DistrictSpacing.tight) {
            Picker(SettingsCopy.membersRoleLabel, selection: roleBinding(member)) {
                ForEach(model.roleOptions, id: \.rawValue) { option in
                    Text(option.displayLabel).tag(option)
                }
            }
            .pickerStyle(.menu)
            .disabled(model.busy)
            Button(SettingsCopy.membersRemove) { requestRemoval(member) }
                .buttonStyle(.districtDestructive)
                .disabled(model.busy)
                // ⚠️ ON EACH MEMBER'S BUTTON, PRESENTED ONLY FOR THE ONE BEING REMOVED. See
                // ``SwiftUI/Binding/dialog(_:onDismiss:)``.
                .confirmationDialog(
                    SettingsCopy.membersRemoveConfirm,
                    isPresented: .dialog(confirmingRemoval && pendingRemoval?.email == member.email) {
                        confirmingRemoval = false
                    },
                    titleVisibility: .visible
                ) {
                    Button(SettingsCopy.membersRemove, role: .destructive, action: confirmRemoval)
                    Button("Cancel", role: .cancel) { pendingRemoval = nil }
                }
        }
        .padding(.top, DistrictSpacing.hairline)
    }

    // MARK: - Adding one

    private var addCard: some View {
        SettingsCard(eyebrow: SettingsCopy.membersAddEyebrow) {
            SettingsField(
                label: SettingsCopy.membersEmailLabel,
                text: emailBinding,
                enabled: !model.busy
            )
            Picker(SettingsCopy.membersRoleLabel, selection: draftRoleBinding) {
                ForEach(model.roleOptions, id: \.rawValue) { option in
                    Text(option.displayLabel).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .disabled(model.busy)
            Text(SettingsCopy.membersRoleNote)
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
            Text(SettingsCopy.membersAddNote)
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
            if model.addRejected {
                Text(SettingsCopy.membersAddRejected)
                    .font(DistrictType.caption)
                    .foregroundStyle(colors.destructive)
            }
            SettingsSaveNotice(state: model.addSave, onReread: reload, onDismiss: model.dismissNotices)
            Button(SettingsCopy.membersAdd, action: submitAdd)
                .buttonStyle(.districtPrimary)
                .disabled(!model.canAdd)
        }
    }

    // MARK: - Renaming

    private var renameCard: some View {
        SettingsCard(eyebrow: SettingsCopy.membersRenameEyebrow) {
            if let stored = model.storedName {
                SettingsReadOnlyRow(label: "Saved as", value: stored)
            }
            Text(SettingsCopy.membersRenameNote)
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
            SettingsField(
                label: SettingsCopy.membersRenameLabel,
                text: nameBinding,
                enabled: !model.busy
            )
            // ⚠️ NO `onReread`. The rename does not re-read (it changes nothing about who
            // belongs here), so it can never be `savedButStale` and a roster reload would
            // say nothing about it.
            SettingsSaveNotice(state: model.renameSave, onDismiss: model.dismissNotices)
            Button(SettingsCopy.membersRename, action: submitRename)
                .buttonStyle(.districtPrimary)
                .disabled(!model.canRenameNow)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(DistrictType.bodySmall)
            .foregroundStyle(colors.mutedForeground)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Wiring

    private var emailBinding: Binding<String> {
        Binding(get: { model.draftEmail }, set: { model.editEmail($0) })
    }

    private var nameBinding: Binding<String> {
        Binding(get: { model.renameDraft }, set: { model.editName($0) })
    }

    private var draftRoleBinding: Binding<WorkspaceRole> {
        Binding(get: { model.draftRole }, set: { model.editRole($0) })
    }

    /// ⚠️ THE PICKER'S SET IS THE WRITE. There is no separate confirm, because a role
    /// change is reversible and the one refusal it can earn (the last administrator) is
    /// reported rather than prevented — this client cannot see who else holds `agency`
    /// without re-reading, and pre-judging it would hide a change the server would
    /// allow.
    private func roleBinding(_ member: WorkspaceMember) -> Binding<WorkspaceRole> {
        Binding(
            get: { member.parsedRole ?? WorkspaceMembership.defaultRole },
            set: { role in
                guard role != member.parsedRole else { return }
                Task { await model.changeRole(email: member.email, to: role) }
            }
        )
    }

    private func requestRemoval(_ member: WorkspaceMember) {
        pendingRemoval = member
        confirmingRemoval = true
    }

    private func confirmRemoval() {
        guard let member = pendingRemoval else { return }
        pendingRemoval = nil
        Task { await model.removeMember(email: member.email) }
    }

    private func submitAdd() {
        Task { await model.addMember() }
    }

    private func submitRename() {
        Task { await model.rename() }
    }

    private func reload() {
        Task { await model.load() }
    }

    /// ⚠️ THE RAW WIRE STRING WHEN THE ROLE DOES NOT PARSE, rather than a guess. The
    /// column has no server-side enum and no TypeScript union, so a fourth value is a
    /// schema-level possibility; ``WorkspaceRole/fromWire(_:)`` fails closed to nil and
    /// showing that as "Viewer" would be a claim about privileges nobody granted.
    private static func roleText(_ member: WorkspaceMember) -> String {
        guard let role = member.parsedRole else { return member.role }
        return role.displayLabel
    }
}
