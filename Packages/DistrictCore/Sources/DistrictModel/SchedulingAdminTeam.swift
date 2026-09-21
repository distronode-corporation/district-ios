import Foundation

// The row DTOs for the scheduling admin's `users.*` and `teams.*` namespaces.
//
// ⛔ THESE ARE THE TENANCY'S SCHEDULER USERS, NOT DISTRONODE'S WORKSPACE MEMBERS,
// and conflating the two is the mistake this comment exists to prevent. A
// scheduler user is a host inside the booking fork with its own id, its own role
// vocabulary and its own archive state; `Workspace.role` and ``WorkspaceRole``
// describe a different population with a different lifecycle. The one place they
// touch is that archiving a scheduler user is what closes out a member whose
// platform removal was refused.
//
// ⚠️ SNAKE_CASE ON THE WIRE. Same note as `SchedulingAdminBookings.swift`.

/// A team, as it appears on a user row.
///
/// ⚠️ TWO KEYS ONLY, AND IT IS NOT ``SchedulingTeam``. The user list embeds a
/// name badge rather than the team, so a client that shared the type would model
/// `slug`, `created_at`, `member_count` and `members` on an object that never
/// carries them — invisible at runtime and a four-key report the moment the
/// fixture is gated.
public struct SchedulingUserTeam: Codable, Sendable {
    public let id: String
    public let name: String
}

/// One scheduler user.
///
/// ⛔ `teams` IS `.nullish()` AND ARRIVES AS AN EXPLICIT `null`, NOT AS AN ABSENT
/// KEY. It is a Go slice the fork marshals without `omitempty`, so a user in no
/// team carries `"teams": null` — row 1 of `district-scheduling-users.json` is
/// that row, and its `$.data[1].teams` is one of this stream's three
/// `allowedExplicitNulls` entries. ⚠️ Null and `[]` mean the same thing HERE
/// (nobody's team membership is "unknown"), which is not true of every nullable
/// array on this surface; see ``SchedulingTeam/members``.
///
/// ⛔ `archived` IS NON-OPTIONAL AND THE THREE FIELDS BESIDE IT ARE NOT. An
/// active user carries `archived:false` and no `archived_at` and no
/// `archived_by_name` — they are absent rather than null — so the Optionals are
/// "this user is not archived" and must not be read as "we do not know who
/// archived them". `archived` is the field that decides.
///
/// ⚠️ `isAdmin` AND `isOwner` ARE THE SCHEDULER'S OWN FLAGS, and `role` is a
/// third statement of roughly the same thing. They are all carried because the
/// fork sends all three and the gate compares key sets; where they disagree the
/// booleans are what the fork's own handlers branch on.
public struct SchedulingUser: Codable, Sendable {
    public let id: String
    public let email: String
    public let name: String
    /// An IANA zone. ⚠️ Absent on a user who has never opened the scheduler, in
    /// which case the tenancy's default applies — which this response does not
    /// carry, so it cannot be substituted here.
    public let timezone: String?
    public let isAdmin: Bool
    public let isOwner: Bool
    public let role: String
    /// Whether this user signs in with a password rather than through SSO.
    public let emailLogin: Bool?
    /// The SSO provider, when there is one.
    public let provider: String?
    public let avatarUrl: String?
    public let createdAt: String?
    public let archived: Bool
    public let archivedAt: String?
    public let archivedByName: String?
    /// ⛔ EXPLICITLY NULL for a user in no team. See the type note.
    public let teams: [SchedulingUserTeam]?

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case name
        case timezone
        case isAdmin = "is_admin"
        case isOwner = "is_owner"
        case role
        case emailLogin = "email_login"
        case provider
        case avatarUrl = "avatar_url"
        case createdAt = "created_at"
        case archived
        case archivedAt = "archived_at"
        case archivedByName = "archived_by_name"
        case teams
    }
}

/// What `users.archive` answers.
///
/// ⛔ THE OP IT BELONGS TO REFUSES 409 WHILE THE USER STILL HOSTS UPCOMING
/// BOOKINGS, which is the whole reason ``SchedulingUpcomingBooking`` exists: the
/// fork's archive is a two-step by design — reassign or cancel, then archive —
/// and a screen that offers "archive" without first offering the list has nothing
/// to say when the 409 arrives. ⚠️ The fork's own refusal text never travels; the
/// RPC answers a code and a number, so the sentence is ours to write.
///
/// ⚠️ `archivedAt` IS OPTIONAL EVEN ON SUCCESS, so a UI must not key "it worked"
/// on having a timestamp. ``ok`` is the verdict.
public struct SchedulingUserArchived: Codable, Sendable {
    public let ok: Bool
    public let archivedAt: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case archivedAt = "archived_at"
    }
}

/// One booking blocking a user's archive, as `users.upcomingBookings` reports it.
///
/// ⛔ EVERY FIELD IS REQUIRED, WHICH IS THE OPPOSITE OF ``SchedulingBooking`` AND
/// IS NOT A CONTRADICTION. This is a purpose-built projection the fork assembles
/// for exactly one question — "what is in the way?" — so it joins the event type
/// and the attendee rather than reporting what a sparse booking index happens to
/// hold. It is also not addressable: there is no `status`, no `location_value`
/// and no host, because the host is the user being archived.
public struct SchedulingUpcomingBooking: Codable, Sendable {
    public let id: String
    public let startAt: String
    public let endAt: String
    public let eventTypeName: String
    public let eventTypeSlug: String
    public let attendeeName: String
    public let attendeeEmail: String

    enum CodingKeys: String, CodingKey {
        case id
        case startAt = "start_at"
        case endAt = "end_at"
        case eventTypeName = "event_type_name"
        case eventTypeSlug = "event_type_slug"
        case attendeeName = "attendee_name"
        case attendeeEmail = "attendee_email"
    }
}

/// One member of a team.
///
/// ⛔ `routingPriority` IS NON-OPTIONAL AND `0` IS A REAL VALUE, NOT AN ABSENCE.
/// It is what round-robin assignment orders by, so defaulting a missing one to
/// zero would silently promote a host to the front of every rotation. The schema
/// requires the key; if it ever stops arriving, this should throw rather than
/// guess.
///
/// ⚠️ `archived` IS CARRIED ON THE TEAM ROW TOO, so an archived host stays
/// visible in the team they were in. A roster that filtered them out would make
/// "why is this team still routing to them" unanswerable from the screen.
public struct SchedulingTeamMember: Codable, Sendable {
    public let id: String
    public let name: String
    public let email: String
    public let avatarUrl: String?
    public let routingPriority: Int
    public let archived: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case email
        case avatarUrl = "avatar_url"
        case routingPriority = "routing_priority"
        case archived
    }
}

/// A team, as every `teams.*` op that answers one reports it.
///
/// ⛔ `members` IS `.nullish()` AND AN EMPTY TEAM ANSWERS EXPLICIT `null`. Same
/// Go-slice-without-`omitempty` mechanism as ``SchedulingUser/teams``, and both
/// of this stream's team fixtures demonstrate it — `$.data.items[1].members` on
/// the list and `$.data.members` on the single read, which are the same team seen
/// twice. ⚠️ Unlike the user's `teams`, null here is NOT interchangeable with
/// `[]`: six of the eight `teams.*` ops answer a team, and only the two that read
/// one are guaranteed to have populated it. Treating null as "this team is empty"
/// after a `teams.members.add` would report the member you just added as absent.
/// ``memberCount`` is the field to trust, and it is `0` on the fixture that nulls
/// `members` precisely so the two can be seen agreeing.
///
/// ⚠️ `memberCount` IS ITSELF `.optional()` AND ABSENT IS NOT `0`. Nothing should
/// render a zero it was not sent.
public struct SchedulingTeam: Codable, Sendable {
    public let id: String
    public let name: String
    public let slug: String
    public let createdAt: String?
    public let memberCount: Int?
    /// ⛔ EXPLICITLY NULL on a team with no members. See the type note.
    public let members: [SchedulingTeamMember]?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case slug
        case createdAt = "created_at"
        case memberCount = "member_count"
        case members
    }
}
