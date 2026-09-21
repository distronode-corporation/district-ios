import Foundation

/// `GET /api/district/workspace/list` — the workspaces this account may operate
/// on.
///
/// ⛔ THIS ROUTE EXISTS FOR THE NATIVE CLIENTS. On the web the list never crosses
/// the network: it is rendered into the page as Server Component props and the
/// switcher only POSTs the user's choice back. There was nothing to GET.
///
/// ⛔ AND THE ACTIVE WORKSPACE IS THIS CLIENT'S OWN STATE, NOT THE SERVER'S. The
/// browser's active workspace is the httpOnly `distronode_workspace_id` cookie,
/// which the lister promotes to index 0 and every server-side
/// `requireWorkspaceRole` fallback then reads. A bearer-token client holds no
/// cookies, so it sends `workspaceId` explicitly on every request instead.
///
/// ⚠️ INDEX 0 IS MEANINGFUL. The server has already applied owned-first
/// ordering, so the first element is the workspace the browser would consider
/// active. Use it as the default when the user has expressed no preference; do
/// NOT re-sort and then treat the new first element as the default, or the app
/// and the browser disagree about which tenant is in view.
///
/// ⛔ THE 503 IS A DIFFERENT TYPE, ON PURPOSE. When nothing resolved AND a region
/// is down the route answers `REGIONS_DEGRADED` rather than an empty 200 —
/// ``WorkspaceListDegradedError`` — because "we could not look" and "there is
/// nothing" read to a paying customer as account loss when confused. This type
/// is the 200, and it carries the PARTIAL case; see ``degradedRegions``.
public struct WorkspaceListResponse: Codable, Sendable {
    public let success: Bool
    public let workspaces: [WorkspaceEntry]
    /// Regions whose databases did not answer while the list was being built.
    ///
    /// ⛔ A NON-EMPTY VALUE ON A **200** MEANS THIS LIST IS INCOMPLETE, AND THAT
    /// IS THE HALF EVERY CLIENT MISSES. The total-failure case is a 503 the
    /// server refuses to let a client mistake; a PARTIAL failure arrives here,
    /// green, with a short list and this array populated.
    /// `district-workspace-list-partial.json` is the fixture that pins it.
    public let degradedRegions: [String]
    /// How many workspaces were withheld because their subscription is not
    /// active.
    ///
    /// ⚠️ WHEN ``workspaces`` IS EMPTY AND THIS IS NON-ZERO, the account exists
    /// and its billing lapsed — a different screen from "no workspaces", and the
    /// only way to tell them apart. ⛔ Billing is READ-ONLY in this app (App
    /// Store Review Guideline 3.1.3(b)): report the state, offer no way to pay.
    public let inactiveCount: Int
    /// The user's stored "remember my choice".
    ///
    /// ⚠️ NOT GUARANTEED TO APPEAR IN ``workspaces``. The stored preference can
    /// name a workspace whose subscription has since lapsed, or one the user was
    /// removed from — the server echoes it verbatim without cross-checking.
    /// Treat it as an id to LOOK UP, and fall back to index 0 when it is absent.
    /// Sending it blind earns a 403.
    public let defaultWorkspaceId: String?
    /// How many ACTIVE workspaces exist for this user, independent of how many
    /// this page carried.
    ///
    /// ⛔ THE COUNT OF THE THING BEING PAGED, SO IT EXCLUDES INACTIVE ONES. It is
    /// not `workspaces.count + inactiveCount`. ⚠️ And it is not a substitute for
    /// ``degradedRegions``: a region that failed to answer is missing from BOTH
    /// this number and the list, so `workspaces.count == total` can hold while
    /// the answer is still incomplete.
    public let total: Int
    /// The page size the server actually applied, which is not necessarily the
    /// one requested — the route clamps a missing, zero, negative or NaN limit
    /// to the default and caps anything above the ceiling.
    public let limit: Int
    public let offset: Int
}

/// One selectable workspace.
public struct WorkspaceEntry: Codable, Sendable {
    public let id: String
    public let name: String
    /// Data residency of this workspace's rows: `us`, `ca`, `eu` or `apac`.
    public let region: String
    /// `agency`, `client` or `viewer`, lowercased by the server.
    ///
    /// ⚠️ A RAW STRING, NOT AN ENUM, for the reason ``WorkspaceRole`` documents:
    /// the column is plain text with no Prisma enum and no TypeScript union, so
    /// decoding straight into an enum would throw on an unmodelled role and take
    /// out the whole list. Parse through ``WorkspaceRole/fromWire(_:)``.
    public let role: String
    /// Raw billing tier, straight off the column — nil when never set, and an
    /// explicit null on the wire (which is why both list fixtures need an
    /// `allowedExplicitNulls` entry).
    ///
    /// ⛔ CASE IS WHATEVER THE DATABASE HOLDS, AND IT IS NOT LOWERCASE. Verified
    /// against a real database: the values are `VoicePro` and `VoiceStarter`,
    /// MIXED CASE. Nothing normalises this column on write and the route does
    /// not normalise on read, so `subscriptionTier == "voicepro"` silently never
    /// matches. Lowercase before comparing — the server's own tier check in
    /// `/api/auth/me` does exactly that, which is why it works.
    ///
    /// ⚠️ NOT A DISPLAY STRING EITHER. `GET /api/settings` substitutes a
    /// capitalised "Free" for an empty tier and this route deliberately does
    /// not, so the same underlying value reads differently depending on which
    /// endpoint produced it. Format it in the client.
    public let subscriptionTier: String?
}
