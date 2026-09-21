import DistrictData
import DistrictModel
import SwiftUI

/// "New team", on the teams card.
struct SchedulingTeamCreateButton: View {
    let admin: SchedulingAdminRepository
    let workspaceId: String
    let onChanged: () -> Void

    @State private var editing: SchedulingWritePresentation<SchedulingTeamEditorModel>?

    var body: some View {
        Button(SchedulingTeamWriteCopy.create) {
            editing = SchedulingWritePresentation(model: makeModel())
        }
        .buttonStyle(.districtPrimary)
        .accessibilityIdentifier(A11yID.SchedulingWriteEntry.teamCreate)
        .sheet(item: $editing) { entry in
            // ⚠️ NO NAME, BECAUSE THERE IS NO TEAM YET. The sheet titles itself
            // "New team" while the model is creating and only reads this for the
            // delete dialog, which a create never draws.
            SchedulingTeamEditorSheet(model: entry.model, teamName: "") {
                editing = nil
            }
        }
    }

    /// ⚠️ `team: nil` IS WHAT PUTS THE MODEL IN CREATE MODE. The same model renames
    /// and deletes an existing one; see ``SchedulingTeamEditorModel/isCreating``.
    private func makeModel() -> SchedulingTeamEditorModel {
        SchedulingTeamEditorModel(
            admin: admin,
            workspaceId: workspaceId,
            team: nil,
            onSaved: { _ in onChanged() },
            onDeleted: { _ in onChanged() }
        )
    }
}

/// Rename or delete one team, and edit who is in it.
///
/// ⛔ THE MEMBER EDITOR TAKES THE TEAM THIS SCREEN LOADED. `teams.members.add`,
/// `.patch` and `.remove` each rewrite a ROUTING ORDER, so an editor built over a
/// failed read would reorder a rota it never saw — which is why the team card
/// renders this only from `.ready`.
struct SchedulingTeamRowActions: View {
    let admin: SchedulingAdminRepository
    let workspaceId: String
    let team: SchedulingTeam
    let onChanged: () -> Void

    @State private var editing: SchedulingWritePresentation<SchedulingTeamEditorModel>?
    @State private var members: SchedulingWritePresentation<SchedulingTeamMembersModel>?

    var body: some View {
        HStack(spacing: DistrictSpacing.tight) {
            Button(SchedulingWriteCopy.edit) {
                editing = SchedulingWritePresentation(model: editorModel())
            }
            .buttonStyle(.districtGhost)
            .accessibilityIdentifier(A11yID.SchedulingWriteEntry.teamEdit)
            Button(SchedulingTeamWriteCopy.membersButton) {
                members = SchedulingWritePresentation(model: membersModel())
            }
            .buttonStyle(.districtGhost)
            .accessibilityIdentifier(A11yID.SchedulingWriteEntry.teamMembers)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $editing) { entry in
            SchedulingTeamEditorSheet(model: entry.model, teamName: team.name) {
                editing = nil
            }
        }
        .sheet(item: $members) { entry in
            SchedulingTeamMembersSheet(model: entry.model) { members = nil }
        }
    }

    private func editorModel() -> SchedulingTeamEditorModel {
        SchedulingTeamEditorModel(
            admin: admin,
            workspaceId: workspaceId,
            team: team,
            onSaved: { _ in onChanged() },
            onDeleted: { _ in onChanged() }
        )
    }

    private func membersModel() -> SchedulingTeamMembersModel {
        SchedulingTeamMembersModel(
            admin: admin,
            workspaceId: workspaceId,
            team: team,
            onSaved: { _ in onChanged() }
        )
    }
}

/// Close one scheduler account.
///
/// ⛔ OFFERED ONLY FOR A LIVE SCHEDULER ACCOUNT, and the caller decides that from
/// ``SchedulingMemberRow/state``: somebody with no scheduler row has nothing to
/// archive, and an already-archived one answers a 404 the sheet would have to
/// explain. ⚠️ The sheet reads their upcoming bookings before it enables the
/// button — the web's own guard, and the reason `users.archive`'s 409 is rare
/// rather than routine.
struct SchedulingUserArchiveButton: View {
    let admin: SchedulingAdminRepository
    let workspaceId: String
    let userId: String
    let userName: String
    let onChanged: () -> Void

    @State private var archiving: SchedulingWritePresentation<SchedulingUserArchiveModel>?

    var body: some View {
        Button(SchedulingTeamWriteCopy.archive) {
            archiving = SchedulingWritePresentation(model: makeModel())
        }
        .buttonStyle(.districtGhost)
        .accessibilityIdentifier(A11yID.SchedulingWriteEntry.userArchive)
        .sheet(item: $archiving) { entry in
            SchedulingUserArchiveSheet(model: entry.model, userName: userName) {
                archiving = nil
            }
        }
    }

    private func makeModel() -> SchedulingUserArchiveModel {
        SchedulingUserArchiveModel(
            admin: admin,
            workspaceId: workspaceId,
            userId: userId,
            userName: userName,
            onArchived: { _ in onChanged() }
        )
    }
}
