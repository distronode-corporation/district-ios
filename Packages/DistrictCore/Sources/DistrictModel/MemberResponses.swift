import Foundation

/// One membership row, as every membership route selects it.
///
/// ⛔ MEMBERSHIP IS THE THING EVERY OTHER GUARD IN THE PRODUCT IS DERIVED FROM.
/// `getWorkspaceRole` answers from these rows, so a client or viewer able to
/// write here could grant themselves any role and walk through every
/// `requireWorkspaceRole` in the API. The READ admits all three roles and
/// **every mutation is agency-only** — narrower than ``WorkspaceRole/canMutate``
/// mirrors, so gate the controls on `.agency` specifically.
///
/// ⛔ THE SAME TYPE DECODES THE LIST AND THE TWO WRITES THAT ECHO A ROW. `GET`
/// returns an array of these, `POST` and `PATCH` each return one under `member`,
/// and all three use the route's single `MEMBER_SELECT` — so the shapes are
/// genuinely identical rather than coincidentally similar.
///
/// ⚠️ NO IDS ON THE WIRE. `(workspaceId, email)` is the natural key every
/// membership path uses, and the route deliberately does not publish the row's
/// uuid — so ``email`` IS the identity, and it is what the PATCH body and the
/// DELETE query carry.
///
/// ⚠️ ``createdAt`` IS AN ISO-8601 STRING. This module owns no date parsing, for
/// the same reason the Kotlin client does not: a decoder strategy applied here
/// would have to be right for every timestamp on the surface, and they do not
/// all agree.
public struct WorkspaceMember: Codable, Sendable {
    public let email: String
    /// ⚠️ A PLAIN STRING, NOT AN ENUM. See ``WorkspaceRole`` for why, and parse
    /// it with ``WorkspaceRole/fromWire(_:)``, which fails closed.
    public let role: String
    public let createdAt: String

    /// The parsed role, or nil when it is not one this client knows.
    public var parsedRole: WorkspaceRole? {
        WorkspaceRole.fromWire(role)
    }
}

/// `GET /api/district/workspace/members?workspaceId=` — the roster, oldest
/// first.
///
/// ⚠️ ORDERED `createdAt asc`, WHICH IS THE OPPOSITE OF EVERY OTHER LIST ON THIS
/// SURFACE (calls, documents and conversations are all newest-first). It is the
/// route's own `orderBy` and it is the right one here: the first row is the
/// founding member, and a roster that reshuffled as people joined would be
/// harder to scan than one that grows at the bottom.
public struct MemberListResponse: Codable, Sendable {
    public let success: Bool
    /// ⚠️ NON-OPTIONAL because `findMany` always emits the array; an absent key
    /// is contract drift, and the gate is what catches it.
    public let members: [WorkspaceMember]
}

/// The answer to every membership WRITE.
///
/// ⛔ ONE TYPE FOR THREE ROUTES WITH TWO DIFFERENT KEY SETS, AND THAT IS WHY
/// ``member`` IS OPTIONAL. `POST` and `PATCH` answer `{success:true, member:{…}}`;
/// `DELETE` answers a bare `{success:true}` with no `member` key at all. A type
/// that required the row would throw on the response to a successful REMOVAL —
/// the one place a client must not fail, because the row really is gone and a
/// decode failure would present it as still there.
///
/// ⚠️ THE ECHOED ROW IS NOT A SUBSTITUTE FOR RE-READING THE LIST. It is one row
/// of a roster whose order the client does not control, and a removal echoes
/// nothing at all, so the screen re-reads after every write rather than patching
/// what is on screen.
public struct MemberMutationResponse: Codable, Sendable {
    public let success: Bool
    public let member: WorkspaceMember?
}

/// `PATCH /api/district/workspace/rename` — `{success, name}`.
///
/// ⛔ NAME ONLY, AND THE SLUG IS DELIBERATELY ABSENT: `slug` is unique in two
/// physically separate databases (the hub's `WorkspaceDirectory` and the
/// region's `Workspace` row) with no cross-database transaction to keep them in
/// step, so a slug change could commit in one and fail in the other. `name` is
/// display-only and lives on the regional row alone.
///
/// ⛔ AND ``name`` IS THE **TRIMMED** VALUE THE SERVER STORED, not the string
/// that was sent. The route trims before it measures (`" "` is an empty name,
/// not a one-character one) and echoes what it wrote — so this is the value a
/// later read will see, and adopting it is what makes a second read unnecessary.
/// Adopting the REQUESTED string instead would display a name nobody stored.
public struct RenameResponse: Codable, Sendable {
    public let success: Bool
    public let name: String
}

/// Membership constants that are the server's, not this client's.
public enum WorkspaceMembership {
    /// The role the server assigns when a request omits one.
    ///
    /// ⚠️ `client`, NOT `viewer`. Worth stating because the cautious guess is
    /// wrong: the ordinary tenant role is the default, so an operator who adds
    /// someone without touching the picker grants more than read-only.
    public static let defaultRole: WorkspaceRole = .client

    /// The roles the picker offers, in the server's own order (`MEMBER_ROLES`).
    ///
    /// ⚠️ DERIVED FROM THE ENUM rather than listed again, so a role added to
    /// ``WorkspaceRole`` cannot be silently missing from the picker.
    public static let assignableRoles: [WorkspaceRole] = WorkspaceRole.allCases

    /// The route's `MAX_NAME_LENGTH`, measured AFTER trimming. Applied
    /// client-side so an operator is not charged a round trip to be told.
    public static let maxWorkspaceNameLength = 120
}
