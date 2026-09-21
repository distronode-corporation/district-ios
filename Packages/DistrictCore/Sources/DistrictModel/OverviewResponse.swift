import Foundation

/// `GET /api/district/overview?workspaceId=` — the dashboard landing screen in
/// one round trip.
///
/// ⛔ IT EXISTS FOR THIS CLIENT AND FOR NO OTHER. The web dashboard's overview
/// page is an async Server Component that queries the database directly, so
/// none of its four tiles are reachable over HTTP without this route.
///
/// ⛔ DO NOT REBUILD IT FROM `/api/district/analytics`. That route looks
/// equivalent and is not: it is WINDOW-SCOPED (7d default, 90d ceiling) while
/// three of these four metrics are ALL-TIME. Its `totalCalls` counts the window,
/// its `avgDuration` averages only the calls inside it, and it has no contacts
/// count at all. Only ``OverviewMetrics/callsThisWeek`` coincides with
/// `analytics?range=7d`. A client that substituted it would show numbers that
/// quietly disagree with the browser, which is worse than showing none.
///
/// ⚠️ ``workspaceId`` AND ``role`` ARE NON-OPTIONAL, WHICH DIVERGES FROM THE
/// KOTLIN DTO. Both are written into an unconditional response literal on the
/// route's only success path, after `requireWorkspaceRole` has resolved them —
/// the handler dereferences both with `!`. Kotlin defaults them to null as a
/// kotlinx idiom rather than on evidence; requiring them here is what makes a
/// 200 that omitted either one a loud contract failure instead of a screen with
/// no role to gate on.
public struct OverviewResponse: Codable, Sendable {
    public let success: Bool
    /// The workspace that actually answered.
    ///
    /// ⚠️ ECHOED, AND WORTH CHECKING. A request that omitted `workspaceId` gets
    /// the server's own resolution, so comparing this against the workspace the
    /// UI believes is active is what catches a local selection that has drifted.
    public let workspaceId: String
    /// The caller's EFFECTIVE role, which is not always a membership row: the
    /// server can resolve a caller to `agency` for support access with no
    /// membership at all.
    ///
    /// ⛔ GATE THE UI ON THIS, NOT ON THE ROLE CACHED FROM THE WORKSPACE LIST.
    /// Parse it through ``WorkspaceRole/fromWire(_:)``, which fails closed.
    public let role: String
    public let metrics: OverviewMetrics
    /// ``OverviewMetrics/avgDuration`` pre-formatted, e.g. "3m 12s" or "45s".
    ///
    /// ⛔ USE THIS RATHER THAN FORMATTING THE SECONDS LOCALLY. Two duration
    /// formats already ship in this product and they disagree on the same input:
    /// this tile omits a zero minutes component ("45s") while a call row always
    /// emits one ("0m 45s" — see ``CallSummary/duration``). The server sends the
    /// tile's own label so this client cannot pick the wrong one of the two.
    public let avgDurationLabel: String
    /// The 8 most recent calls, byte-identical to a row of
    /// `GET /api/district/calls`.
    ///
    /// ⚠️ ONE DTO SERVES BOTH SURFACES because one server-side mapping does. The
    /// count is fixed server-side and is deliberately NOT a query parameter; the
    /// feed is where page size varies.
    public let recentCalls: [CallSummary]
}

/// The four KPI tiles, in the order the browser renders them.
///
/// ⛔ ZERO IS A LEGITIMATE VALUE AND IS NOT EVIDENCE THE REQUEST WORKED, and the
/// server has its own version of this trap: these metrics read FORCE-RLS tables,
/// and outside a workspace transaction they come back as four confident zeros
/// with HTTP 200 rather than an error. Branch on the request's result, never on
/// whether these look populated.
public struct OverviewMetrics: Codable, Sendable {
    /// Cumulative, all time.
    public let totalCalls: Int
    /// Calls created in the last 7 days. ⚠️ The only one of the four with an
    /// analytics equivalent.
    public let callsThisWeek: Int
    public let totalContacts: Int
    /// SECONDS, averaged over COMPLETED calls, all time. See
    /// ``OverviewResponse/avgDurationLabel`` before formatting it.
    public let avgDuration: Int
}
