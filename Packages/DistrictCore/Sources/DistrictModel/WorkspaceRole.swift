import Foundation

/// A workspace membership role, parsed from the wire.
///
/// ⛔ THIS IS A UX AFFORDANCE, NOT A SECURITY BOUNDARY. Authorisation happens on
/// the server, in `requireWorkspaceRole`, on every request — reads admit all
/// three roles, mutations admit `["agency","client"]` only. Nothing here
/// protects data: hiding a button stops the app OFFERING an action that would
/// come back 403, which is a better experience than a failure dialog, and that
/// is its entire job. Never skip a server call on the strength of this, and
/// never treat a 403 as impossible because the UI was gated.
///
/// ⚠️ NOT A `Codable` ENUM, AND EVERY DTO KEEPS `role` AS A RAW `String` ON
/// PURPOSE. Server-side the column is `role String @default("client")` with no
/// Prisma enum and no TypeScript union anywhere, so a fourth value is a
/// schema-level possibility rather than a hypothesis. A `Codable` enum would
/// throw on an unmodelled value and take out the entire response it arrived in —
/// the whole member list, for one unrecognised row. Parsing through
/// ``WorkspaceRole/fromWire(_:)`` contains the blast radius to "this membership
/// has no privileges".
public enum WorkspaceRole: String, Sendable, CaseIterable {
    /// Agency operator. Full access, and what the server resolves support access
    /// to.
    case agency
    /// The ordinary tenant role, and the server's default for a member with no
    /// explicit row.
    case client
    /// Read-only. The server excludes this role from every mutating route.
    case viewer

    /// Whether the server would admit this role to a mutating district route.
    ///
    /// Mirrors the `["agency","client"]` allow-list those routes pass to
    /// `requireWorkspaceRole`. ⚠️ TOO COARSE FOR MEMBERSHIP. Every mutation on
    /// `workspace/members` is **agency-only**, a narrower list than this — gate
    /// those controls on `.agency` specifically rather than on this property.
    public var canMutate: Bool {
        self != .viewer
    }

    /// The wire spelling. Lowercase, because that is what the routes validate
    /// against: they normalise with `trim().toLowerCase()` and answer 400 for
    /// anything outside `agency|client|viewer`, so sending `AGENCY` is a 400
    /// rather than a coerced value.
    public var wireValue: String {
        rawValue
    }

    /// Parse a wire value, or `nil` if it is absent or not one this client
    /// knows.
    ///
    /// ⛔ FAILS CLOSED BY RETURNING nil, AND EVERY CONSUMER MUST TREAT nil AS
    /// "NO PRIVILEGES" rather than falling back to a default. The tempting
    /// default is `.client`, because that is what the SERVER falls back to for a
    /// member with no explicit row — but the server reaches that conclusion
    /// having confirmed the membership exists. Here, nil means the opposite: the
    /// role could not be established. Assuming `.client` would show mutation
    /// controls to a viewer whose role string arrived misspelled, and every one
    /// of those actions would 403.
    ///
    /// ⚠️ CASE-INSENSITIVE ON PURPOSE. This surface only ever writes lowercase,
    /// but a server-side whole-set replace (`setWorkspaceMembers`) stores
    /// whatever it was handed, and the server's own agency count is deliberately
    /// case-insensitive because of it. An `"Agency"` row really does grant
    /// agency.
    public static func fromWire(_ raw: String?) -> WorkspaceRole? {
        guard let raw else { return nil }
        let normalised = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return WorkspaceRole(rawValue: normalised)
    }

    /// Whether to offer mutating controls for a role that may not have parsed.
    ///
    /// ⚠️ TAKES AN OPTIONAL DELIBERATELY. `role?.canMutate == true` is correct
    /// but invites being rewritten as `!= false`, which is `true` for nil — the
    /// exact inversion this helper exists to make unwritable.
    public static func allowsMutation(_ role: WorkspaceRole?) -> Bool {
        role?.canMutate == true
    }
}
