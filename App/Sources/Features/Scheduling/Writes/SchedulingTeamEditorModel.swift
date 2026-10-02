import DistrictData
import DistrictModel
import Foundation
import Observation

/// Creating a team, or renaming and deleting one that exists.
///
/// ⛔ ONE MODEL FOR BOTH BECAUSE THE FORM IS THE SAME ONE FIELD, and the only
/// difference is which op the same typed name goes to. Splitting it would
/// duplicate the validation, which is the part that has to agree.
///
/// ⛔ THE SLUG IS NEVER SENT, ON EITHER OP, AND THAT IS A DECISION RATHER THAN A
/// MISSING FIELD. `teams.create` derives one from the name when it is absent, so
/// sending a guessed slug is a way to disagree with the server about an identifier
/// it was about to choose correctly; and `teams.patch` accepts a slug that
/// re-points every public team booking URL already handed out. The web team page
/// sends `{id, name}` and nothing else. ⚠️ If a slug editor is ever wanted, it
/// needs its own confirmation naming the links it breaks, not a second text field
/// on this sheet.
///
/// ⚠️ `teams.delete` ANSWERS A 200 `{ok:true}`, NOT A 204, unlike almost every
/// other delete in the catalog. It is decoded and discarded here; what the caller
/// gets is ``onDeleted`` carrying the id, because the row it has to drop is keyed
/// by that and by nothing in the response.
@MainActor
@Observable
final class SchedulingTeamEditorModel {
    private(set) var state: SchedulingWriteState = .idle
    private(set) var name: String
    private(set) var nameRejected: String?

    private let admin: SchedulingAdminRepository
    private let workspaceId: String
    /// nil in create mode.
    private let teamId: String?
    private let onSaved: (SchedulingTeam) -> Void
    private let onDeleted: (String) -> Void

    /// - Parameter team: nil creates, non-nil renames and may delete.
    init(
        admin: SchedulingAdminRepository,
        workspaceId: String,
        team: SchedulingTeam?,
        onSaved: @escaping (SchedulingTeam) -> Void,
        onDeleted: @escaping (String) -> Void
    ) {
        self.admin = admin
        self.workspaceId = workspaceId
        teamId = team?.id
        name = team?.name ?? ""
        self.onSaved = onSaved
        self.onDeleted = onDeleted
    }

    var busy: Bool {
        state.isWorking
    }

    var isCreating: Bool {
        teamId == nil
    }

    /// ⚠️ The existing name, so a delete dialog can say WHICH team. Empty in create
    /// mode, where there is nothing to delete.
    var canDelete: Bool {
        teamId != nil && !busy
    }

    var submitLabel: String {
        isCreating ? SchedulingTeamWriteCopy.create : SchedulingTeamWriteCopy.rename
    }

    func editName(_ value: String) {
        name = value
        nameRejected = nil
        if case .failed = state {
            state = .idle
        }
    }

    /// ⛔ TRIMMED, THEN MEASURED, IN THAT ORDER. A single space is what an operator
    /// gets by tapping the spacebar in an empty field, and the difference between
    /// the two orders is whether that counts as a name.
    func submit() async {
        guard !busy else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            nameRejected = SchedulingTeamWriteCopy.nameRequired
            return
        }
        guard trimmed.count <= Self.nameLimit else {
            nameRejected = SchedulingTeamWriteCopy.nameTooLong
            return
        }
        state = .working
        do {
            let team = try await write(trimmed)
            state = .done(isCreating ? SchedulingTeamWriteCopy.createDone : SchedulingTeamWriteCopy.renameDone)
            onSaved(team)
        } catch {
            state = .failed(SchedulingFailureCopy.text(forAny: error))
        }
    }

    func delete() async {
        guard let teamId, !busy else { return }
        state = .working
        do {
            _ = try await admin.deleteTeam(workspaceId: workspaceId, teamId: teamId)
            state = .done(SchedulingTeamWriteCopy.deleteDone)
            onDeleted(teamId)
        } catch {
            state = .failed(SchedulingFailureCopy.text(forAny: error))
        }
    }

    private func write(_ trimmed: String) async throws -> SchedulingTeam {
        guard let teamId else {
            return try await admin.createTeam(workspaceId: workspaceId, name: trimmed)
        }
        return try await admin.patchTeam(workspaceId: workspaceId, teamId: teamId, name: trimmed)
    }

    /// The catalog's `z.string().min(1).max(200)`.
    static let nameLimit = 200
}
