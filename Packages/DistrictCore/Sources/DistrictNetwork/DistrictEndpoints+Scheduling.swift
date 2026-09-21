import Foundation

/// The workspace's booking pages: what state the tenancy is in, and the one
/// button that brings one into existence.
///
/// ⛔ `scheduling/sso` IS DELIBERATELY ABSENT AND IS **NOT** RETIRED.
/// `GET /api/district/scheduling/sso` answers a **302** whose `Location` is a
/// one-time sign-in URL into the tenant's own scheduler, and it is live: the
/// calendar-OAuth round trip still spends it with an explicit `next=/v1/calendar/connect…`, and
/// that the **410 `scheduler_console_retired`** fires only for a `next` that lands
/// on `/admin`. What it lacks is a DESCRIPTOR, for two reasons that still hold: it
/// is not a JSON body, and it does not belong on ``RedirectEndpoints`` either —
/// that list exists for `calls/{id}/recording` and now
/// ``EndpointID/schedulingAdminDownload``, whose targets are presigned OBJECT
/// URLs, and the failure modes are opposite. Following a recording redirect wastes
/// bandwidth; following an SSO redirect SPENDS a single-use credential on a
/// transport the user never sees. It is fetched in the App target with redirects
/// disabled and the `Location` handed to the browser.
/// `scheduling/webhook/{workspaceId}` is absent for the simpler reason that this
/// client is never its caller.
///
/// ⚠️ THE ADMIN SURFACE IS A SEPARATE FILE. The scheduler's admin surfaces reach
/// the app through the one RPC in
/// `DistrictEndpoints+SchedulingAdmin.swift`; this file stays the two routes about
/// the TENANCY itself — whether it exists, and bringing one into existence.
public extension DistrictEndpoints {
    /// What the Scheduling card renders: eligibility, whether this member may
    /// act, and the tenancy row if there is one.
    ///
    /// ⚠️ READABLE BY EVERY ROLE INCLUDING `viewer` — it reports whether the
    /// workspace has booking pages and where they are, which is the same class of
    /// fact as "this workspace has a phone number". The response's `canManage` is
    /// what decides which buttons to draw.
    ///
    /// ⛔ TAKES A NON-OPTIONAL `workspaceId`, UNLIKE ``overview(workspaceId:)``.
    /// The route would accept an absent one and let `requireWorkspaceRole` pick a
    /// default from the caller's own membership listing — but this client holds no
    /// selection cookie, so on a multi-workspace account that default silently
    /// reports on the wrong workspace, and here the wrong answer is a booking URL
    /// belonging to somebody else's tenancy. The overview keeps its Optional for
    /// compatibility with a server fallback that predates this client; a new route
    /// has no reason to inherit it.
    ///
    /// ⚠️ NO `success` ENVELOPE. The body is `{eligible, canManage, tenant}` and
    /// nothing more, so a repository must not run it through `ResponseEnvelope`.
    static func schedulingStatus(workspaceId: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .schedulingStatus,
            .get,
            DistrictPaths.schedulingStatus,
            query: [ApiQueryItem("workspaceId", workspaceId)]
        )
    }

    /// Provision this workspace's scheduling tenancy.
    ///
    /// ⛔ IT CREATES REAL THINGS AT TWO THIRD PARTIES — a tenancy at the scheduler
    /// and a DNS record at Cloudflare — so it is never fired on a timer, never
    /// retried and never looped. The server's own brake is 5 per hour PER
    /// WORKSPACE (three colleagues pressing the same button share one budget), and
    /// a sixth call answers **429**. That limiter fails open, so it is not a
    /// guarantee: the durable half is the provisioner reusing the existing row and
    /// the existing hostname rather than allocating a second one.
    ///
    /// ⛔ IT ANSWERS **202**, AND `ok: false` INSIDE THAT 202 IS STILL A SUCCESSFUL
    /// RESPONSE. Provisioning has already run by the time the body is written; the
    /// 202 describes the STATE it left. See ``SchedulingEnableResponse``.
    ///
    /// ⛔ OWNER AND ADMIN ONLY (`client` and `agency`), AND ALSO ALLOWLIST-GATED,
    /// which is a SECOND check rather than the same one worded differently. The
    /// role check asks whether this person may act for this workspace; the
    /// allowlist asks whether this workspace is one anybody has decided to
    /// provision at all. While the feature is dark the second answer is no for
    /// everybody, so even an owner gets **403** — which is why the card must read
    /// `eligible` from the status route instead of offering the button by role.
    ///
    /// ⚠️ THE WORKSPACE TRAVELS IN THE BODY. The route reads `req.json()` first
    /// and falls back to the query string, so both work; the body is what the web
    /// client sends and matching it keeps one capture readable as the other.
    static func schedulingEnable(workspaceId: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .schedulingEnable,
            .post,
            DistrictPaths.schedulingEnable,
            body: .json(.object([("workspaceId", .string(workspaceId))]))
        )
    }

    /// Mint a one-time hand-off URL into the tenant's scheduler.
    ///
    /// ⛔ IT DOES NOT REPLACE `scheduling/sso`. That route answers 410 for one
    /// `next` value — one that lands on `/admin` — and mints normally for the
    /// calendar-OAuth leg it still serves. The real difference is the TRANSPORT:
    /// `sso` is a 302 whose `Location` the client reads without following, and this
    /// one answers JSON, so it decodes like everything else. The URL it carries is
    /// still SINGLE-USE and short-lived, and it is still handed straight to the
    /// browser rather than fetched here.
    ///
    /// ⚠️ `next` IS OPTIONAL AND DROPPED WHEN nil, not sent as null: `JSONValue.object`
    /// discards a nil pair so the route's own default fires, and an explicit null is a
    /// value zod would not default over. Same decision as `registerPushToken`'s `kind`.
    static func schedulingHandoff(workspaceId: String, next: String? = nil) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .schedulingHandoff,
            .post,
            DistrictPaths.schedulingHandoff,
            body: .json(.object([
                ("workspaceId", .string(workspaceId)),
                ("next", .optional(next)),
            ]))
        )
    }
}
