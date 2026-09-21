import DistrictData
import DistrictModel
import Foundation
import Observation

/// The roster's own load state.
///
/// ⚠️ SEPARATE FROM ``SettingsConfigState`` BECAUSE IT IS A DIFFERENT READ WITH A
/// DIFFERENT PAYLOAD, and because nothing behind it is a wholesale-replace save.
/// Reusing the config state would imply this screen hydrates from `workspace/config`,
/// which excludes a viewer and does not carry a roster.
enum MembersListState {
    case loading
    /// ⚠️ Oldest first, which is the server's `createdAt asc` and the opposite of every
    /// other list on this surface. It is not this client's choice and is not re-sorted:
    /// the first row is the founding member, and a roster that reshuffled as people
    /// joined would be harder to scan than one that grows at the bottom.
    case ready([WorkspaceMember])
    case failed(FailureText)
}

/// The members screen's state machine. Ported from Android's `MembersViewModel`.
///
/// ⛔ TWO DIFFERENT ROLE GATES ON ONE SCREEN, AND COLLAPSING THEM WOULD BE WRONG IN
/// BOTH DIRECTIONS. Every mutation on `workspace/members` is **agency-only** — the
/// narrowest allow-list in the API, because these rows are what `getWorkspaceRole`
/// answers from — while `workspace/rename` admits `agency` and `client` like an
/// ordinary write. So ``canManage`` is `role == .agency` and ``canRename`` is
/// ``WorkspaceRole/allowsMutation(_:)``; using the second for both would offer a client
/// three buttons that 403, and the first for both would hide a rename they are entitled
/// to.
///
/// ⛔ EVERY MEMBERSHIP WRITE RE-READS THE ROSTER, INCLUDING A FAILED ONE. The list is
/// ordered server-side and a removal echoes no row at all, so there is nothing to patch
/// locally that would be reliably right. Re-reading after a FAILURE matters too: a
/// last-administrator refusal usually means the operator's copy of who holds `agency`
/// is out of date, and leaving the stale list up invites the same refusal again.
///
/// ⛔ AND THE WRITE HOLDS ITS SAVE STATE AT `saving` UNTIL THAT RE-READ HAS FINISHED.
/// Settling the state first would leave ``busy`` false for the whole GET, with every
/// picker and Remove button live against a roster still showing pre-write rows, beside
/// "Saved.": a removed member would stay drawn with a working Remove for the length of
/// the read. ⚠️ That window is also this type's only sequencing: every write
/// is gated on ``busy``, so two of them cannot be in flight and two roster reads cannot
/// land out of order. No generation counter is needed and none is here.
///
/// ⛔ A RE-READ THAT FAILS AFTER A WRITE THAT LANDED IS
/// ``SettingsSaveState/savedButStale(_:)`` AND LEAVES THE ROSTER ALONE. The membership
/// change IS stored; the list is merely out of date. Replacing it with a load-failure
/// view would throw away both a usable roster and the only record that the write
/// succeeded, and on this screen that invites the operator to make the change again.
///
/// ⛔ THE RENAME FIELD DOES NOT PREFILL, AND THAT IS THE LOAD-FIRST RULE APPLIED
/// HONESTLY RATHER THAN A MISSING FEATURE. Nothing this client can call returns the
/// workspace's current name: the roster does not carry it, `workspace/config` excludes
/// it, and the only read that has it fans out across every region. A field seeded from
/// nothing is exactly the shape that turns "the load failed" into "the operator saved a
/// blank".
@MainActor
@Observable
final class MembersModel {
    private(set) var list: MembersListState = .loading
    private(set) var addSave: SettingsSaveState = .idle
    private(set) var roleSave: SettingsSaveState = .idle
    private(set) var removeSave: SettingsSaveState = .idle
    private(set) var renameSave: SettingsSaveState = .idle
    private(set) var addRejected = false

    private(set) var draftEmail = ""
    /// ⛔ THE SERVER'S DEFAULT IS `client`, NOT `viewer`. The cautious guess is wrong:
    /// someone added without touching the picker gets the ordinary tenant role.
    private(set) var draftRole = WorkspaceMembership.defaultRole
    private(set) var renameDraft = ""

    /// The name the server last confirmed it stored, or nil.
    ///
    /// ⛔ ONLY EVER SET FROM A RENAME RESPONSE — the TRIMMED value the route wrote,
    /// never the string that was typed. Nil means "this client has not read this
    /// workspace's name", which is the truth on entry and must not render as an empty
    /// name.
    private(set) var storedName: String?

    /// ⛔ `agency` ONLY. See the ⛔ on the type.
    let canManage: Bool
    /// ⚠️ `agency` OR `client` — a wider gate than ``canManage``, on purpose.
    let canRename: Bool

    private let workspaces: WorkspaceRepository
    private let workspaceId: String

    init(container: AppContainer, workspaceId: String, role: WorkspaceRole?) {
        workspaces = container.workspaces
        self.workspaceId = workspaceId
        canManage = RouteGate.allowsMembershipWrites(role)
        canRename = WorkspaceRole.allowsMutation(role)
    }

    var members: [WorkspaceMember] {
        guard case let .ready(rows) = list else { return [] }
        return rows
    }

    var busy: Bool {
        addSave.isSaving || roleSave.isSaving || removeSave.isSaving || renameSave.isSaving
    }

    /// ⚠️ True once the roster has been read, whatever it contained. Gates the rename
    /// control, because "we could not read who is in this workspace" is not a state in
    /// which to offer to rename it.
    var loaded: Bool {
        if case .ready = list {
            return true
        }
        return false
    }

    /// ⛔ THE ROUTE'S OWN EMAIL RULE, MIRRORED SO THE BUTTON IS HONEST. It is
    /// deliberately loose — the point is that a stored address is MATCHABLE by the
    /// membership lookups, not that it is deliverable — and an address that fails it is
    /// a 400. Checking here saves an operator a round trip to be told.
    var canAdd: Bool {
        canManage && !busy && Self.looksLikeEmail(normalisedEmail)
    }

    /// ⛔ TRIMMED, THEN MEASURED — the route's own order, and it is the difference
    /// between `" "` being an empty name and a one-character one. A space is what an
    /// operator gets by tapping the spacebar in an empty field.
    var canRenameNow: Bool {
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return canRename && loaded && !busy && !trimmed.isEmpty
            && trimmed.count <= WorkspaceMembership.maxWorkspaceNameLength
    }

    var roleOptions: [WorkspaceRole] {
        WorkspaceMembership.assignableRoles
    }

    /// ⚠️ AN IDEMPOTENT GET, so replaying it is unconditionally safe.
    ///
    /// ⛔ IT RETIRES THE BANNERS, AND ONLY ON A SUCCESSFUL READ. Without that, a red
    /// "that would leave no administrator" would survive a full reload and sit beside
    /// whatever the next write said. The success guard is the same one the persona and
    /// capability forms put on their drafts: on a failed read the banner may be the only
    /// record of what the last write did, and replacing it with "we could not read the
    /// roster" would destroy that record.
    func load() async {
        list = .loading
        await readRoster()
        guard case .ready = list else { return }
        addSave = .idle
        roleSave = .idle
        removeSave = .idle
        renameSave = .idle
        addRejected = false
    }

    func editEmail(_ value: String) {
        draftEmail = value
        addRejected = false
    }

    func editRole(_ role: WorkspaceRole) {
        draftRole = role
    }

    func editName(_ value: String) {
        renameDraft = value
        renameSave = .idle
    }

    /// Add one member.
    ///
    /// ⚠️ NO INVITATION IS SENT AND NO ACCOUNT IS CREATED. Success means a row exists;
    /// if that address has never signed up, the row simply waits for it.
    ///
    /// ⚠️ THE DRAFT IS CLEARED ONLY ON SUCCESS — including on a duplicate, where keeping
    /// the address on screen is what lets the operator see WHICH one was already there.
    func addMember() async {
        guard canManage, !busy else { return }
        guard canAdd else {
            addRejected = true
            return
        }
        addSave = .saving
        let result = await workspaces.addMember(
            workspaceId: workspaceId,
            email: normalisedEmail,
            role: draftRole
        )
        if case .success = result {
            draftEmail = ""
        }
        addSave = await commit(result, conflictFallback: SettingsCopy.membersDuplicate)
    }

    /// Change one member's role.
    ///
    /// ⛔ MAY BE REFUSED WITH A **409** WHEN IT WOULD DEMOTE THE LAST AGENCY MEMBER, and
    /// that is not a mistake the operator made: "this workspace would have no
    /// administrator" is a different sentence from "you did something wrong", and
    /// neither is retryable because nothing about the request was unlucky.
    func changeRole(email: String, to role: WorkspaceRole) async {
        guard canManage, !busy else { return }
        roleSave = .saving
        let result = await workspaces.changeMemberRole(
            workspaceId: workspaceId,
            email: email,
            role: role
        )
        roleSave = await commit(result, conflictFallback: SettingsCopy.membersLastAgency)
    }

    /// Remove one member.
    ///
    /// ⛔ THE CONFIRMATION IS THE SCREEN'S AND HAS ALREADY HAPPENED. Removing someone
    /// ends their access to every call, contact and conversation in this workspace
    /// immediately — the next request they make resolves no role — and re-adding them is
    /// a new row rather than an undo. ⛔ Not retried.
    func removeMember(email: String) async {
        guard canManage, !busy else { return }
        removeSave = .saving
        let result = await workspaces.removeMember(workspaceId: workspaceId, email: email)
        removeSave = await commit(result, conflictFallback: SettingsCopy.membersLastAgency)
    }

    /// Rename the workspace.
    ///
    /// ⛔ THE SERVER'S ECHO IS ADOPTED, NEVER THE TYPED STRING. The route TRIMS before
    /// it measures and returns what it stored, so displaying the typed value would show
    /// a name nobody saved and would hide the trim from an operator who typed trailing
    /// spaces.
    ///
    /// ⚠️ NO ROSTER RE-READ. Renaming changes nothing about who belongs here, and
    /// re-reading would only give a failed list read a chance to replace a successful
    /// rename notice.
    func rename() async {
        guard canRenameNow else { return }
        renameSave = .saving
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        switch await workspaces.rename(workspaceId: workspaceId, name: trimmed) {
        case let .success(response):
            storedName = response.name
            renameDraft = ""
            renameSave = .saved
        case let .failure(error):
            // ⚠️ THE DRAFT SURVIVES A FAILURE. Losing a typed name because the save
            // failed would be two losses for one fault.
            renameSave = .failed(FailureText.from(error))
        }
    }

    /// ⚠️ Retires every banner without a re-read.
    func dismissNotices() {
        guard !busy else { return }
        addSave = .idle
        roleSave = .idle
        removeSave = .idle
        renameSave = .idle
        addRejected = false
    }

    // MARK: - Internals

    private var normalisedEmail: String {
        // ⚠️ Normalised the same way the route does before it stores or compares.
        draftEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// ⛔ A FAILED RE-READ DOES NOT OVERWRITE THE WRITE'S OWN NOTICE. The two are
    /// separate fields precisely so "the change landed" and "we could not re-read the
    /// list" can both be true and both be said; the mistake in the other direction is
    /// telling an operator their change failed when only the read did, which invites
    /// them to make it again.
    private func readRoster() async {
        switch await workspaces.members(workspaceId: workspaceId) {
        case let .success(response):
            list = .ready(response.members)
        case let .failure(error):
            list = .failed(FailureText.from(error))
        }
    }

    /// The roster re-read that follows a write that LANDED.
    ///
    /// ⛔ IT NEVER REPORTS A FAILURE, AND IT LEAVES THE ROSTER ON SCREEN ALONE WHEN THE
    /// READ FAILS. See the ⛔ on the type.
    private func rereadAfterWrite() async -> SettingsSaveState {
        switch await workspaces.members(workspaceId: workspaceId) {
        case let .success(response):
            list = .ready(response.members)
            return .saved
        case let .failure(error):
            return .savedButStale(FailureText.from(error))
        }
    }

    /// One membership write plus its mandatory re-read, held inside a single `saving`
    /// window.
    ///
    /// ⚠️ THE FALLBACK IS CHOSEN PER CALL SITE and only ever used for a **409** with an
    /// empty body. See ``conflict(_:fallback:)``.
    private func commit(
        _ result: Result<some Any, ApiError>,
        conflictFallback: String
    ) async -> SettingsSaveState {
        guard case let .failure(error) = result else {
            return await rereadAfterWrite()
        }
        // ⛔ A REFUSED WRITE RE-READS TOO, unlike every other write on this surface. See
        // the ⛔ on the type: the commonest refusal here means the operator's copy of who
        // holds `agency` is out of date, and the stale list is what produced the refusal.
        await readRoster()
        return .failed(Self.conflict(error, fallback: conflictFallback))
    }

    /// ⛔ THE **409** IS A REFUSAL WITH A REASON AND IS NEVER RETRYABLE. This client
    /// cannot see the machine-readable `code` — ``ApiError`` keeps the status and the
    /// sentence and nothing else — so the fallback is chosen PER CALL SITE, which is
    /// determinate: the only 409 an add can earn is "already a member", and the only one
    /// a role change or a removal can earn is "that would leave no administrator".
    ///
    /// ⚠️ THE SERVER'S OWN SENTENCE WINS WHEN THERE IS ONE, which is the rule
    /// ``FailureText`` already applies to every 4xx. The fallback exists for a blank
    /// body, not to replace wording the server authored.
    private static func conflict(_ error: ApiError, fallback: String) -> FailureText {
        guard error.httpStatus == 409 else { return FailureText.from(error) }
        let message = error.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return FailureText(message: message.isEmpty ? fallback : message, action: .none)
    }

    /// The route's own `EMAIL_REGEX`, expressed without one: a single `@` with
    /// something either side, and a dot after it. ⚠️ Deliberately loose, for the reason
    /// on ``canAdd``.
    private static func looksLikeEmail(_ value: String) -> Bool {
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        let domain = parts[1]
        guard let dot = domain.firstIndex(of: "."), dot != domain.startIndex else { return false }
        guard domain.index(after: dot) != domain.endIndex else { return false }
        return !value.contains(where: \.isWhitespace)
    }
}
