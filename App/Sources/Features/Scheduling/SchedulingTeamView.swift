import DistrictData
import DistrictModel
import Observation
import SwiftUI

/// The hosts who can be booked, and the teams they route through.
///
/// ⛔ THE MEMBER LIST IS A JOIN ACROSS TWO SYSTEMS AND THE ADDRESS IS THE ONLY KEY. District
/// membership and the scheduler's user table have separate ids; ``SchedulingTeamFormat``
/// joins them case-insensitively on the email. ⚠️ The second pass — scheduler users with no
/// District row — is what surfaces somebody who has LEFT the workspace and still holds
/// bookings, which is the single most actionable thing this screen says.
@MainActor
@Observable
final class SchedulingTeamModel {
    private(set) var members: SchedulingSectionState<[SchedulingMemberRow]> = .loading
    private(set) var teams: SchedulingSectionState<[SchedulingTeam]> = .loading

    private let repository: SchedulingAdminRepository
    private let workspaces: WorkspaceRepository
    private let workspaceId: String

    /// ⛔ THE DESIGNATED INITIALISER TAKES THE REPOSITORIES AND THE CONTAINER ONE
    /// DELEGATES TO IT, WHICH IS THE ONLY TEST SEAM ON THIS SURFACE. ``AppContainer``
    /// builds its own ``URLSessionHTTPTransport`` in `init`, so a test cannot hand it a
    /// fake; taking the collaborators directly lets `DistrictAITests` drive a real
    /// repository over a stub transport, which exercises the envelope walk rather than
    /// skipping it. ⚠️ Production still constructs through the container, so both
    /// collaborators remain the one shared ``ApiClient``.
    init(
        repository: SchedulingAdminRepository,
        workspaces: WorkspaceRepository,
        workspaceId: String
    ) {
        self.repository = repository
        self.workspaces = workspaces
        self.workspaceId = workspaceId
    }

    convenience init(container: AppContainer, workspaceId: String) {
        self.init(
            repository: container.schedulingAdmin,
            workspaces: container.workspaces,
            workspaceId: workspaceId
        )
    }

    func load() async {
        members = .loading
        teams = .loading
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.loadMembers() }
            group.addTask { await self.loadTeams() }
        }
    }

    /// ⛔ `includeArchived: true`, WHICH IS THE OPPOSITE OF THE OBVIOUS CHOICE AND IS THE
    /// WEB'S. An archived scheduler account is exactly what an operator needs to SEE on
    /// this screen — it is the evidence that somebody was dealt with — and hiding it would
    /// make a resolved departure look like an unresolved one.
    private func loadMembers() async {
        do {
            let scheduler = try await repository.schedulerUsers(
                workspaceId: workspaceId,
                includeArchived: true
            )
            members = await .ready(SchedulingTeamFormat.joinMembers(
                district: districtMembers(),
                scheduler: scheduler
            ))
        } catch {
            members = .failed(SchedulingFailureCopy.text(forAny: error))
        }
    }

    /// ⚠️ A FAILED MEMBERSHIP READ DEGRADES TO AN EMPTY LIST RATHER THAN FAILING THE ROW,
    /// and the join still runs. Every scheduler user then appears with no District role,
    /// which reads as "removed from the workspace" — ⛔ that is WRONG and is why the view
    /// draws ``membersDegraded`` instead of the stranded-host warning when this happens.
    /// Accusing every host of having left is worse than saying the roles could not be read.
    private(set) var districtMembersFailed = false

    private func districtMembers() async -> [SchedulingDistrictMember] {
        switch await workspaces.members(workspaceId: workspaceId) {
        case let .success(response):
            districtMembersFailed = false
            // ⚠️ THE RAW `role` STRING, NOT `parsedRole`. ``SchedulingTeamFormat`` echoes
            // an unknown role as it came so an operator can quote it; going through
            // ``WorkspaceRole/fromWire(_:)`` here would fail closed to nil, which this
            // screen renders as "Removed from the workspace" — a much stronger claim than
            // "we did not recognise that role".
            return response.members.map { SchedulingDistrictMember(email: $0.email, role: $0.role) }
        case .failure:
            districtMembersFailed = true
            return []
        }
    }

    private func loadTeams() async {
        do {
            teams = try await .ready(repository.teams(workspaceId: workspaceId))
        } catch {
            teams = .failed(SchedulingFailureCopy.text(forAny: error))
        }
    }

    /// ⛔ SUPPRESSED WHEN THE DISTRICT MEMBERSHIP COULD NOT BE READ. Without it every host
    /// looks stranded; see the ⚠️ on ``districtMembersFailed``.
    var strandedNotice: String? {
        guard !districtMembersFailed, let rows = members.value else { return nil }
        let stranded = SchedulingTeamFormat.strandedHosts(rows)
        return stranded.isEmpty ? nil : SchedulingTeamFormat.strandedNotice(stranded)
    }

    // MARK: - Writes

    // ⛔ `users.archive` IS THE WRITE THIS SCREEN WANTS AND IT HAS FOUR REFUSALS THAT ARE
    // NOT FAULTS. ``SchedulingTeamFormat/archiveRefusalSentence(status:fallback:)`` is
    // already ported and already tested for them: 409 means the person still has upcoming
    // bookings, 403 that only the owner may archive another administrator, 400 that the
    // owner has to be transferred first, 404 that the account is already gone. ⚠️ The web
    // additionally DISABLES the control until `users.upcomingBookings` has answered zero,
    // which is a read this screen does not yet make.
    //
    // ⛔ AND THE TEAM MUTATIONS ARE A WHOLESALE-REPLACE FAMILY IN DISGUISE:
    // `teams.members.add`, `.patch` and `.remove` each rewrite a routing order, so an
    // editor built from a FAILED read would reorder a rota it never saw. ``teams`` is a
    // `SchedulingSectionState` for that reason.
}

struct SchedulingTeamView: View {
    @State private var model: SchedulingTeamModel

    /// ⚠️ HELD BESIDE THE MODEL RATHER THAN REACHED THROUGH IT. Every write sheet on
    /// this screen builds its own model at the moment its control is pressed and
    /// takes the repository directly; the read model keeps its own copy private,
    /// which is the right default for a type whose job is the read.
    private let admin: SchedulingAdminRepository
    private let workspaceId: String
    private let role: WorkspaceRole?

    @Environment(\.colorScheme) private var colorScheme

    init(container: AppContainer, workspaceId: String, role: WorkspaceRole?) {
        self.workspaceId = workspaceId
        self.role = role
        admin = container.schedulingAdmin
        _model = State(initialValue: SchedulingTeamModel(
            container: container,
            workspaceId: workspaceId
        ))
    }

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    /// ⛔ `teams.*`, `teams.members.*` AND `users.archive` ARE ALL `client`-LEVEL, so
    /// every control this screen adds is absent rather than disabled for a viewer —
    /// the rule ``SchedulingEventTypesView`` states for its own create.
    private var canManage: Bool {
        WorkspaceRole.allowsMutation(role)
    }

    var body: some View {
        SchedulingSectionScroll(
            title: SchedulingCopy.sectionTitle(.team),
            identifier: A11yID.Scheduling.teamRoot,
            onRefresh: { await model.load() },
            content: {
                stranded
                membersCard
                teamsCard
            }
        )
        .task { await model.load() }
    }

    @ViewBuilder
    private var stranded: some View {
        if let notice = model.strandedNotice {
            VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
                DistrictEyebrow(text: SchedulingCopy.strandedEyebrow)
                Text(notice)
                    .font(DistrictType.bodySmall)
                    .foregroundStyle(colors.destructive)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var membersCard: some View {
        SchedulingCard(eyebrow: SchedulingCopy.membersEyebrow) {
            if model.districtMembersFailed {
                Text(SchedulingCopy.membersDegraded)
                    .font(DistrictType.bodySmall)
                    .foregroundStyle(colors.destructive)
            }
            switch model.members {
            case .loading:
                SettingsSkeleton()
            case let .failed(failure):
                FailureView(failure: failure, onRetry: reload)
            case let .ready(rows):
                if rows.isEmpty {
                    Text(SchedulingCopy.membersEmpty)
                        .font(DistrictType.bodySmall)
                        .foregroundStyle(colors.mutedForeground)
                } else {
                    ForEach(rows, id: \.key) { row in
                        memberRow(row)
                    }
                }
            }
        }
    }

    private func memberRow(_ row: SchedulingMemberRow) -> some View {
        let state = SchedulingTeamFormat.memberStateLabel(row.state)
        return VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            DistrictListRow(
                title: row.name,
                subtitle: SchedulingCopy.memberSubtitle(
                    email: row.email,
                    // ⛔ SUPPRESSED WHEN THE MEMBERSHIP READ FAILED. "Removed from the
                    // workspace" beside every host would be a false accusation drawn from an
                    // absent read; see the ⚠️ on `districtMembersFailed`.
                    role: model.districtMembersFailed
                        ? nil
                        : SchedulingTeamFormat.districtRoleLabel(row.districtRole)
                ),
                trailing: { DistrictBadge(text: state.label, tone: state.kind.tone) }
            )
            archive(row)
        }
    }

    /// ⛔ OFFERED ONLY FOR A LIVE SCHEDULER ACCOUNT. Somebody with no scheduler row
    /// (`.absent`) has nothing to archive, and an already-archived one answers a 404
    /// the sheet would then have to explain — so the control is absent for both,
    /// which is what ``SchedulingMemberRow/state`` is read for here.
    @ViewBuilder
    private func archive(_ row: SchedulingMemberRow) -> some View {
        if canManage, row.state == .host, let userId = row.schedulerUserId {
            SchedulingUserArchiveButton(
                admin: admin,
                workspaceId: workspaceId,
                userId: userId,
                userName: row.name,
                onChanged: reload
            )
        }
    }

    private var teamsCard: some View {
        SchedulingCard(eyebrow: SchedulingCopy.teamsEyebrow) {
            Text(SchedulingCopy.teamsSubtitle)
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
            switch model.teams {
            case .loading:
                SkeletonBlock(height: 44)
            case let .failed(failure):
                Text(failure.message)
                    .font(DistrictType.bodySmall)
                    .foregroundStyle(colors.destructive)
            case let .ready(rows):
                if rows.isEmpty {
                    Text(SchedulingCopy.teamsEmpty)
                        .font(DistrictType.bodySmall)
                        .foregroundStyle(colors.mutedForeground)
                } else {
                    ForEach(rows, id: \.id) { team in
                        teamRow(team)
                    }
                }
                create
            }
        }
    }

    /// ⛔ DRAWN ONLY FROM `.ready`, AND THE MEMBER EDITOR IS WHY. `teams.members.add`,
    /// `.patch` and `.remove` each rewrite a ROUTING ORDER, so an editor built over a
    /// failed read would reorder a rota it never saw.
    private func teamRow(_ team: SchedulingTeam) -> some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            SchedulingReadOnlyRow(
                label: team.name,
                value: SchedulingCopy.memberCount(
                    SchedulingTeamFormat.teamMemberCount(team)
                )
            )
            if canManage {
                SchedulingTeamRowActions(
                    admin: admin,
                    workspaceId: workspaceId,
                    team: team,
                    onChanged: reload
                )
            }
        }
    }

    @ViewBuilder
    private var create: some View {
        if canManage {
            SchedulingTeamCreateButton(
                admin: admin,
                workspaceId: workspaceId,
                onChanged: reload
            )
        }
    }

    private func reload() {
        Task { await model.load() }
    }
}
