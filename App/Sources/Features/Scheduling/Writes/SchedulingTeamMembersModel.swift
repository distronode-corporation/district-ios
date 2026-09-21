import DistrictData
import DistrictModel
import Foundation
import Observation

/// One team's roster: who is in it, in what routing order.
///
/// ⛔ THREE OPS WITH THREE DIFFERENT ANSWER SHAPES, AND THAT IS WHY THE ROSTER IS
/// REPLACED RATHER THAN PATCHED LOCALLY. `teams.members.add` and
/// `teams.members.patch` answer the WHOLE team; `teams.members.remove` answers a
/// bare `{ok}` and nothing else, so a caller holding a roster has to re-read. This
/// model does exactly that — replace from the response where there is one, re-read
/// where there is not — and never edits its own copy, because a locally-sorted
/// rotation is a rotation the fork does not agree with.
///
/// ⛔ AND `teams.members.add` SENDS NO PRIORITY. The catalog allows one; omitting
/// it lets the fork choose, and a literal `0` would put every new member at the
/// FRONT of every rotation. The web team page omits it for the same reason.
///
/// ⚠️ THE TWO IDS ARE SPELLED DIFFERENTLY ON THE TWO OPS — `user_id` on the add,
/// `userId` on the patch and the remove. That is the catalog's spelling for a path
/// key and it is not ours to normalise; the repository holds both spellings and
/// this model passes arguments, so the asymmetry is invisible here. It is written
/// down anyway because it is the kind of thing a "tidy-up" removes.
@MainActor
@Observable
final class SchedulingTeamMembersModel {
    private(set) var state: SchedulingWritesBState = .idle
    private(set) var team: SchedulingTeam
    private(set) var users: SchedulingReassignHostsState = .loading
    private(set) var pickedUserId: String?
    /// Keyed by scheduler user id. ⚠️ Text, not Int: the field has to be able to
    /// hold "" and "2.5" long enough to refuse them.
    private(set) var priorityDrafts: [String: String] = [:]
    private(set) var priorityRejected: [String: String] = [:]

    private let admin: SchedulingAdminRepository
    private let workspaceId: String
    private let onSaved: (SchedulingTeam) -> Void

    init(
        admin: SchedulingAdminRepository,
        workspaceId: String,
        team: SchedulingTeam,
        onSaved: @escaping (SchedulingTeam) -> Void
    ) {
        self.admin = admin
        self.workspaceId = workspaceId
        self.team = team
        self.onSaved = onSaved
        priorityDrafts = Self.drafts(from: team)
    }

    var busy: Bool {
        state.isWorking
    }

    /// ⚠️ A TEAM WITH NO MEMBERS CARRIES `members: null`, NOT `[]`, and
    /// `teams.members.add` may answer before the fork has populated it — so an
    /// empty roster here is "none we were told about", and
    /// ``SchedulingTeam/memberCount`` is the field to trust for a count.
    var members: [SchedulingTeamMember] {
        team.members ?? []
    }

    /// Live hosts who are not already in this team.
    var addable: [SchedulingUser] {
        guard case let .ready(rows) = users else { return [] }
        let present = Set(members.map(\.id))
        return rows.filter { !$0.archived && !present.contains($0.id) }
    }

    func loadUsers() async {
        users = .loading
        do {
            users = try await .ready(admin.schedulerUsers(workspaceId: workspaceId))
        } catch {
            users = .failed(SchedulingWritesBFailure.text(for: error))
        }
    }

    func pick(_ userId: String) {
        pickedUserId = userId
        if case .failed = state {
            state = .idle
        }
    }

    func editPriority(_ value: String, for userId: String) {
        priorityDrafts[userId] = value
        priorityRejected[userId] = nil
        if case .failed = state {
            state = .idle
        }
    }

    func addMember() async {
        guard !busy else { return }
        guard let userId = pickedUserId else {
            state = .failed(FailureText(message: SchedulingTeamWriteCopy.addRequired, action: .none))
            return
        }
        await run(SchedulingTeamWriteCopy.addDone) {
            try await self.admin.addTeamMember(workspaceId: self.workspaceId, teamId: self.team.id, userId: userId)
        }
        pickedUserId = nil
    }

    /// ⛔ REFUSES AN EMPTY FIELD AND A DECIMAL RATHER THAN COERCING EITHER, which is
    /// `parsePriority`'s rule. ⚠️ Swift needs no separate empty check where
    /// JavaScript does — `Int("")` is nil and `Number("")` is 0 — but the SENTENCE
    /// has to match, because the two clients are describing one rule.
    func savePriority(for userId: String) async {
        guard !busy else { return }
        let raw = (priorityDrafts[userId] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let priority = Int(raw), priority >= 0 else {
            priorityRejected[userId] = SchedulingTeamWriteCopy.priorityInvalid
            return
        }
        await run(SchedulingTeamWriteCopy.priorityDone) {
            try await self.admin.setTeamMemberPriority(
                workspaceId: self.workspaceId,
                teamId: self.team.id,
                userId: userId,
                routingPriority: priority
            )
        }
    }

    /// ⛔ RE-READS RATHER THAN REPLACING, BECAUSE THE REMOVE ANSWERS A BARE `{ok}`.
    /// ⚠️ A re-read that fails after a removal that LANDED leaves the roster alone
    /// and reports the read's failure: the membership change IS stored, and
    /// replacing the list with a load failure would throw away both a usable roster
    /// and the only record that the write succeeded.
    func removeMember(_ userId: String) async {
        guard !busy else { return }
        state = .working
        do {
            _ = try await admin.removeTeamMember(workspaceId: workspaceId, teamId: team.id, userId: userId)
        } catch {
            state = .failed(SchedulingWritesBFailure.text(for: error))
            return
        }
        do {
            try await adopt(admin.team(workspaceId: workspaceId, teamId: team.id))
            state = .done(SchedulingTeamWriteCopy.removeDone)
        } catch {
            state = .failed(SchedulingWritesBFailure.text(for: error))
        }
    }

    private func run(_ done: String, _ write: @escaping () async throws -> SchedulingTeam) async {
        state = .working
        do {
            try await adopt(write())
            state = .done(done)
        } catch {
            state = .failed(SchedulingWritesBFailure.text(for: error))
        }
    }

    /// ⚠️ THE DRAFTS ARE RESEEDED FROM THE SERVER'S ROSTER on every adoption. A
    /// field still holding what the operator typed, beside a value the fork
    /// normalised, is two answers to one question.
    private func adopt(_ team: SchedulingTeam) {
        self.team = team
        priorityDrafts = Self.drafts(from: team)
        priorityRejected = [:]
        onSaved(team)
    }

    private static func drafts(from team: SchedulingTeam) -> [String: String] {
        var drafts: [String: String] = [:]
        for member in team.members ?? [] {
            drafts[member.id] = String(member.routingPriority)
        }
        return drafts
    }
}
