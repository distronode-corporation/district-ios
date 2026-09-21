import DistrictModel
import Foundation

/// How much of a destination a role may use.
///
/// ⛔ THIS IS A UX AFFORDANCE, NOT A SECURITY BOUNDARY, and the distinction has to
/// survive every edit. Authorisation happens on the server, in `requireWorkspaceRole`,
/// on every request. Nothing here protects data: hiding a control stops the app
/// OFFERING an action that would come back 403, which is a better experience than a
/// failure dialog, and that is its entire job. Never skip a server call on the
/// strength of this, and never treat a 403 as impossible because the UI was gated.
///
/// ⛔ AND IT FAILS CLOSED. A nil role means "the role could not be established",
/// never "assume client" — see ``WorkspaceRole/fromWire(_:)``. Every predicate here
/// goes through ``WorkspaceRole/allowsMutation(_:)`` for that reason: `role?.canMutate
/// == true` is correct but invites being rewritten as `!= false`, which is `true` for
/// nil, and that inversion is the one this whole file exists to make unwritable.
enum RouteGate {
    /// Do not offer the destination at all: every route behind it refuses this role.
    case hidden
    /// Offer the destination; disable the controls it names in its own screen.
    case partial
    /// Nothing on this destination is gated for this role.
    case none
}

extension RouteGate {
    /// The gate for one destination and one role.
    static func gate(for route: Route, role: WorkspaceRole?) -> RouteGate {
        guard WorkspaceRole.allowsMutation(role) else { return readOnlyGate(for: route) }
        // Agency and client from here. The only thing still narrower than
        // `canMutate` is membership; see below.
        guard case let .workspaceSettings(_, _, section) = route else { return .none }
        guard section == .members else { return .none }
        return allowsMembershipWrites(role) ? .none : .partial
    }

    /// ⛔ THE ONE PREDICATE THAT IS NOT `canMutate`. Every mutation on
    /// `workspace/members` is AGENCY-ONLY, the narrowest guard in the API, because
    /// those rows are what `getWorkspaceRole` answers from. `canMutate` mirrors the
    /// wider `["agency","client"]` allow-list every other district route uses and is
    /// the WRONG gate here: it would offer a client the add, the role change and the
    /// remove, all three of which 403.
    ///
    /// ⚠️ The workspace RENAME on the same screen does admit client, so the screen
    /// gates two things at two widths. That is why this is a separate predicate
    /// rather than a different return value.
    static func allowsMembershipWrites(_ role: WorkspaceRole?) -> Bool {
        role == .agency
    }

    /// What a viewer, or a role that did not parse, may reach.
    private static func readOnlyGate(for route: Route) -> RouteGate {
        switch route {
        case let .workspaceSettings(_, _, section):
            settingsGate(for: section)
        // ⛔ `POST /api/district/calls/dial` excludes `viewer`, so a viewer reaching
        // this destination would meet a 403 on the one thing it does.
        //
        // ⛔ AND EVERY ONE OF DISTRICT DESK'S NINE ROUTES EXCLUDES `viewer` TOO, THE
        // READS INCLUDED — which is why both desk destinations are hidden outright
        // rather than offered read-only. That is unusual on this surface and it is the
        // server's own decision, recorded in the route: these payloads carry a
        // customer's name, email address and phone number in the clear plus the
        // correspondence about them, and a viewer seat exists to watch operations,
        // which is different in kind. The server's comment says that if a viewer ever
        // needs to know a queue exists, the answer is a COUNT endpoint rather than
        // widening these — so `.partial` here would be a screen whose every call 403s,
        // which is worse than no row.
        case .dialer, .desk, .deskTicket:
            .hidden
        // ⛔ HIDDEN OUTRIGHT, AND THE REASON IS UNUSUAL ON THIS SURFACE: the SUPPORT
        // READS exclude `viewer` too, not only the writes. The route's own header
        // gives the argument — these payloads are support CORRESPONDENCE rather than
        // operational status, and a read-only seat exists to watch operations — so
        // `.partial` would offer a screen whose very first request answers 403.
        // ⚠️ That is the opposite split from knowledge and messaging, whose GETs admit
        // a viewer, which is why this is a case of its own rather than folded in with
        // them.
        case .support, .supportRequest:
            .hidden
        // ⚠️ Reachable, with controls off. Workflows disables only the per-workflow
        // toggle (the list, the runs and the campaign status all admit viewers); a
        // thread lists fine but `messages/mark-read` and `messages/send` exclude
        // viewer, so an ungated thread is a permanent unread badge plus an error on
        // every tap; a contact detail reads fine and its rename, delete, enrich and
        // clear-intel do not.
        case .workflows, .thread, .contactDetail:
            .partial
        // ⛔ `.partial` SINCE THE NATIVE SCHEDULING SECTION LANDED, AND IT WAS `.none`
        // BEFORE. That was correct while the destination was one status card whose only
        // control the SERVER gated (`canManage` off the status read), so there was
        // nothing here for a role to decide. The hub now leads to nine sections, and the
        // recordings one carries a DOWNLOAD whose bar is `agency`/`client` while the list
        // beside it admits a viewer — so there is a control to disable and `.partial` is
        // what says so. ⚠️ Every READ on all nine sections is `viewer`-level
        // (`SchedulingAdminOp.minRole`), which is why this is `.partial` and not
        // `.hidden`: a viewer can fill every screen and is refused exactly one affordance.
        case .scheduling:
            .partial
        // Everything else admits all three roles: the call log and one call, HQ,
        // analytics, the marketplace, billing, the rooms lobby and one room, and
        // this account's devices.
        default:
            .none
        }
    }

    /// ⛔ THE HUB IS OPEN TO A VIEWER AND EVERY SECTION IS NOT, WHICH IS THE WHOLE
    /// SHAPE OF THIS FUNCTION. Persona, capabilities, the transfer directory and the
    /// routing rules all hydrate from `workspace/config`, whose READ excludes `viewer`
    /// server-side: the payload carries staff transfer numbers and the operator's own
    /// prompt. `workspace/knowledge`, `workspace/knowledge-mode` and
    /// `workspace/messaging` are different: their GETs admit a viewer by design. So the hub is `.partial` and the ROWS
    /// carry the gate: a viewer reaches exactly the two sections whose reads they may
    /// make, read-only, and the four config-backed rows stay hidden rather than
    /// leading to a 403. The Android client makes the same call; this is a port of
    /// it, not a widening beyond it.
    ///
    /// ⛔ `members` IS HIDDEN FROM A VIEWER EVEN THOUGH ITS READ WOULD SERVE ONE. The
    /// roster genuinely admits all three roles, but it is a screen whose own affordance
    /// gating would need auditing before a viewer reaches it. The Android client stops
    /// at the identical point.
    ///
    /// ⛔ `scheduling` IS `.partial`, AND THAT WAS READ OFF THE SERVER SURFACE RATHER
    /// THAN ASSUMED: `scheduling/admin`
    /// classifies all seventy-five operations by minimum role in
    /// `SchedulingAdminOp+Access.swift`, and **every read is `viewer`** — the rule is
    /// "reads are viewer, writes are client". So a viewer may fill all nine sections, and
    /// hiding the row would withhold a surface the server would serve them. ⚠️ The
    /// scheduling row is also the one whose destination is not a settings section at all;
    /// see ``SettingsHubView/destination(_:)``.
    ///
    /// ⛔ `calls` IS `.partial` AND IT IS THE FIRST CONFIG-SHAPED SECTION THAT IS NOT
    /// HIDDEN FROM A VIEWER. It does not hydrate from `workspace/config`:
    /// `GET workspace/call-handling` admits all three roles by design (nothing in that
    /// payload is a staff phone number — it is a mode and a number of seconds), while
    /// the PATCH excludes a viewer. So the row is drawn and the SCREEN gates its own
    /// controls, exactly as knowledge and messaging do. ⚠️ The availability toggle on
    /// the Account screen is a separate surface and is not gated here at all: that route
    /// answers a viewer a **200** carrying `reason: "role"` rather than a 403, so the
    /// honest UI is an explanatory line rather than a missing row.
    private static func settingsGate(for section: SettingsSection) -> RouteGate {
        switch section {
        case .persona, .capabilities, .directory, .routing, .members:
            .hidden
        case .hub, .calls, .knowledge, .messaging, .scheduling:
            .partial
        }
    }
}
