import DistrictModel
import DistrictNetwork
import Foundation

/// The `users.*` and `teams.*` namespaces, typed.
///
/// ⛔ THREE ENVELOPE CONVENTIONS ACROSS ELEVEN OPS, AND THE RETURN TYPES ARE WHERE
/// THAT IS ABSORBED. `users.list` answers a BARE ARRAY, `users.upcomingBookings`
/// and `teams.list` answer `{items:[…]}`, and the six remaining `teams.*` ops
/// answer a team or a bare `{ok}`. Unwrapping here is what keeps the difference
/// from reaching a screen; pinning it in the DTOs is what keeps it from being
/// forgotten.
///
/// ⛔ `users.archive` IS THE OFFBOARDING PATH AND IT REFUSES 409 WHILE THE USER
/// STILL HOSTS UPCOMING BOOKINGS. That refusal is the fork's own design rather
/// than a race: reassign or cancel, then archive. ``upcomingBookings(workspaceId:userId:)``
/// is the read that makes the first step possible, which is why it lives beside
/// the archive and not with the bookings namespace.
///
/// ⚠️ A SCHEDULER USER IS NOT A DISTRONODE MEMBER. Different ids, different role
/// vocabulary, different lifecycle; the two only touch when a platform removal is
/// refused and the archive is what closes the member out. See the note at the top
/// of `SchedulingAdminTeam.swift`.
public extension SchedulingAdminRepository {
    /// `users.list` — every scheduler user in the tenancy.
    ///
    /// ⚠️ A BARE ARRAY ON THE WIRE, not `{items}`. The `data` of the envelope IS
    /// the array, which is why the response type here is `[SchedulingUser]` and
    /// not a container.
    ///
    /// - Parameter includeArchived: the far end compares against the literal
    ///   string `"true"`, and the catalog renders a Swift `Bool` as exactly that.
    ///   ⚠️ Omitted when `false` rather than sent, so the default is the server's.
    func schedulerUsers(
        workspaceId: String,
        includeArchived: Bool = false
    ) async throws -> [SchedulingUser] {
        try await perform(
            .usersList,
            workspaceId: workspaceId,
            params: .object([("include_archived", includeArchived ? .bool(true) : nil)]),
            as: [SchedulingUser].self
        )
    }

    /// `users.archive` — soft-delete a scheduler user.
    ///
    /// ⛔ SOFT, AND THAT IS WHAT MAKES IT SAFE TO OFFER. The row and its links
    /// survive, the member cannot sign in, they are skipped in routing and their
    /// event types are deactivated. ⚠️ Its other refusals are all 4xx with a reason
    /// an operator can act on (403 admin-only, 400 own account / already archived /
    /// is the workspace owner, 404 gone) — but the fork's own text never travels,
    /// so the sentence for each is ours to write from the code and the status.
    func archiveSchedulerUser(workspaceId: String, userId: String) async throws -> SchedulingUserArchived {
        try await perform(
            .usersArchive,
            workspaceId: workspaceId,
            params: .object([("id", .string(userId))]),
            as: SchedulingUserArchived.self
        )
    }

    /// `users.upcomingBookings` — what is standing between this user and an
    /// archive.
    func upcomingBookings(workspaceId: String, userId: String) async throws -> [SchedulingUpcomingBooking] {
        try await perform(
            .usersUpcomingBookings,
            workspaceId: workspaceId,
            params: .object([("id", .string(userId))]),
            as: SchedulingItems<SchedulingUpcomingBooking>.self
        ).items
    }

    /// `teams.list` — every team, each with its members inlined.
    ///
    /// ⚠️ A TEAM WITH NO MEMBERS CARRIES `members: null`, not `[]`. See
    /// ``SchedulingTeam/members``.
    func teams(workspaceId: String) async throws -> [SchedulingTeam] {
        try await perform(
            .teamsList,
            workspaceId: workspaceId,
            params: .object([]),
            as: SchedulingItems<SchedulingTeam>.self
        ).items
    }

    /// `teams.get` — one team.
    func team(workspaceId: String, teamId: String) async throws -> SchedulingTeam {
        try await perform(
            .teamsGet,
            workspaceId: workspaceId,
            params: .object([("id", .string(teamId))]),
            as: SchedulingTeam.self
        )
    }

    /// `teams.create` — a new team.
    ///
    /// ⚠️ `slug` IS OPTIONAL AND THE FORK DERIVES ONE FROM THE NAME WHEN IT IS
    /// ABSENT, so sending a guessed slug is a way to disagree with the server
    /// about an identifier it was about to choose correctly.
    func createTeam(
        workspaceId: String,
        name: String,
        slug: String? = nil
    ) async throws -> SchedulingTeam {
        try await perform(
            .teamsCreate,
            workspaceId: workspaceId,
            params: .object([
                ("name", .string(name)),
                ("slug", .optional(slug)),
            ]),
            as: SchedulingTeam.self
        )
    }

    /// `teams.patch` — rename a team, or re-slug it.
    ///
    /// ⛔ CHANGING THE SLUG CHANGES PUBLIC BOOKING URLS. The fork routes team
    /// booking pages by slug, so a rename that also re-slugs breaks every link
    /// already handed out. Both fields are optional here precisely so a rename can
    /// be sent without one.
    func patchTeam(
        workspaceId: String,
        teamId: String,
        name: String? = nil,
        slug: String? = nil
    ) async throws -> SchedulingTeam {
        try await perform(
            .teamsPatch,
            workspaceId: workspaceId,
            params: .object([
                ("id", .string(teamId)),
                ("name", .optional(name)),
                ("slug", .optional(slug)),
            ]),
            as: SchedulingTeam.self
        )
    }

    /// `teams.delete` — remove a team.
    ///
    /// ⚠️ A 200 `{ok:true}`, NOT A 204, unlike almost every other delete in this
    /// catalog — which is why it decodes as ``SchedulingNoContent`` rather than
    /// through the `NO_CONTENT` rewrite. The two shapes are identical on the wire
    /// and arrive by different routes.
    func deleteTeam(workspaceId: String, teamId: String) async throws -> SchedulingNoContent {
        try await perform(
            .teamsDelete,
            workspaceId: workspaceId,
            params: .object([("id", .string(teamId))]),
            as: SchedulingNoContent.self
        )
    }

    /// `teams.members.add` — put a scheduler user into a team.
    ///
    /// ⚠️ THE ANSWER IS THE WHOLE TEAM, so the caller should replace its row from
    /// the response. ⛔ Its `members` may still be null if the fork answers before
    /// populating; ``SchedulingTeam/memberCount`` is the field to trust.
    ///
    /// - Parameter routingPriority: omitted rather than defaulted to `0`, because
    ///   `0` is a real priority that puts the new member at the front of every
    ///   rotation. Let the fork choose unless the caller means it.
    func addTeamMember(
        workspaceId: String,
        teamId: String,
        userId: String,
        routingPriority: Int? = nil
    ) async throws -> SchedulingTeam {
        try await perform(
            .teamsMembersAdd,
            workspaceId: workspaceId,
            params: .object([
                ("id", .string(teamId)),
                ("user_id", .string(userId)),
                ("routing_priority", routingPriority.map(JSONValue.integer)),
            ]),
            as: SchedulingTeam.self
        )
    }

    /// `teams.members.patch` — change a member's place in the rotation.
    ///
    /// ⚠️ `routingPriority` IS REQUIRED HERE and optional on the add, which is the
    /// schema's own asymmetry: there is nothing else to patch.
    /// ⛔ BOTH IDS ARE PATH KEYS AND BOTH STAY IN THE BODY. The server's schema
    /// requires `id` and `userId` before it strips them for the path, so a client
    /// that removed either gets a 400 naming the field it was being helpful about.
    func setTeamMemberPriority(
        workspaceId: String,
        teamId: String,
        userId: String,
        routingPriority: Int
    ) async throws -> SchedulingTeam {
        try await perform(
            .teamsMembersPatch,
            workspaceId: workspaceId,
            params: .object([
                ("id", .string(teamId)),
                ("userId", .string(userId)),
                ("routing_priority", .integer(routingPriority)),
            ]),
            as: SchedulingTeam.self
        )
    }

    /// `teams.members.remove` — take a scheduler user out of a team.
    ///
    /// ⚠️ A BARE `{ok}` RATHER THAN THE TEAM, unlike the add and the priority
    /// patch, so a caller holding a roster has to re-read rather than replace.
    /// ⛔ `userId` IS CAMELCASE ON THE WIRE HERE while the add's is `user_id`.
    /// That is the catalog's spelling for a path key, and it is not ours to
    /// normalise: a snake_case `user_id` on this op is an `invalid_params`.
    func removeTeamMember(
        workspaceId: String,
        teamId: String,
        userId: String
    ) async throws -> SchedulingNoContent {
        try await perform(
            .teamsMembersRemove,
            workspaceId: workspaceId,
            params: .object([
                ("id", .string(teamId)),
                ("userId", .string(userId)),
            ]),
            as: SchedulingNoContent.self
        )
    }
}
