import DistrictModel
import Foundation

/// Where one entry goes: a pushed ``Route``, or one of the five tabs.
///
/// ⛔ TWO KINDS, BECAUSE THE CLIENTS DISAGREE ABOUT WHAT A DESTINATION IS. Android
/// has no tab bar, so its call log and its contacts list are ordinary destinations;
/// here they are tab roots, and the entry selects the tab rather than pushing a
/// second live copy of a screen the tab bar already owns.
enum OverviewEntryTarget {
    case route(Route)
    case tab(Tab)

    /// ⚠️ A TAB IS NEVER GATED HERE, and that is not an oversight: the tab itself is
    /// present for every role already, so hiding its shortcut would hide nothing, and
    /// both tab roots take the role and gate their own controls with it.
    func gate(role: WorkspaceRole?) -> RouteGate {
        switch self {
        case let .route(route): RouteGate.gate(for: route, role: role)
        case .tab: .none
        }
    }
}

/// One row of the entry-point column on ``OverviewView``.
///
/// ⚠️ ITS OWN FILE RATHER THAN TWO PRIVATE TYPES AT THE BOTTOM OF `OverviewView.swift`,
/// AND THAT IS A LINT CEILING RATHER THAN A DESIGN STATEMENT. `swiftlint --strict`
/// promotes the `file_length` WARNING at 500 lines to an error, and that file passes it
/// with these two types in it. Nothing outside the Overview feature uses them.
struct OverviewEntry: Identifiable {
    let title: String
    let target: OverviewEntryTarget
    let gate: RouteGate

    /// ⚠️ Every title below is a distinct compile-time constant, so a separate id
    /// would be a second value that can only drift from this one.
    var id: String {
        title
    }

    /// ⚠️ THE `.partial` CAPTION, WHICH ANDROID DOES NOT DRAW. It offers a viewer the
    /// workflows row with no hint that the switch behind it is inert, so the disabled
    /// control is discovered by tapping. One word here is cheaper than that.
    var caption: String? {
        switch gate {
        case .partial: "Read-only"
        case .hidden, .none: nil
        }
    }
}

extension OverviewEntry {
    /// Android's `OverviewScreen.kt` column, in its order and with its labels.
    ///
    /// ⛔ `.hidden` IS DROPPED RATHER THAN RENDERED DISABLED. A greyed row still tells
    /// a viewer the dialler and the workspace configuration exist and that they are
    /// shut out of both, which is a disclosure the row need not make, and every route
    /// behind either refuses them server-side anyway. ⚠️ A UX affordance and never a
    /// security boundary: see the ⛔ at the top of ``RouteGate``.
    ///
    /// ⚠️ WORKSPACE SETTINGS IS UNCONDITIONAL FOR EVERY ROLE, MATCHING ANDROID, so a
    /// viewer can reach the knowledge base and the messaging accounts.
    /// `RouteGate.settingsGate(for:)` answers `.partial` for the hub and the SECTIONS carry
    /// the gate. So a viewer gets this row with the `.partial` caption below, opens the
    /// hub, and finds knowledge and messaging read-only; the four config-backed sections
    /// are absent, because their read excludes them server-side. ⚠️ The decision lives in
    /// `RouteGate`, and there is no special case here.
    ///
    /// ⚠️ `Scheduling` HAS NO ANDROID COUNTERPART, so its position is chosen here
    /// rather than ported: last of the workspace surfaces and immediately before the
    /// settings hub, because it is a workspace-level configuration rather than an
    /// operating screen.
    ///
    /// ⚠️ ITS GATE RESOLVES TO ``RouteGate/partial`` FOR A VIEWER. The hub leads to nine
    /// sections, one of which (recordings) carries a download a viewer may not spend — so
    /// the row carries the "Read-only" caption below, which is the honest summary. ⛔ It
    /// is still not `.hidden`: every read on all nine sections is `viewer`-level, so a viewer can fill every screen.
    static func all(workspaceId: String, role: WorkspaceRole?) -> [OverviewEntry] {
        let targets: [(String, OverviewEntryTarget)] = [
            ("Call Logs", .tab(.calls)),
            ("Contacts", .tab(.contacts)),
            ("Open District HQ", .route(.hq(workspaceId: workspaceId, role: role))),
            ("Analytics", .route(.analytics(workspaceId: workspaceId))),
            ("Phone numbers", .route(.marketplace(workspaceId: workspaceId, role: role))),
            ("Billing", .route(.billing(workspaceId: workspaceId, role: role))),
            ("Rooms", .route(.rooms(workspaceId: workspaceId, role: role))),
            ("Workflows", .route(.workflows(workspaceId: workspaceId, role: role))),
            // ⛔ "Desk", NEVER "Tickets" AND NEVER "Inbox". This is the tenant's OWN
            // customers' queue; raising something with Distronode is a different
            // surface, and Operate → Inbox is a third. The web console keeps the same
            // rule that these labels never converge, because a two-word nav
            // entry cannot carry the distinction on its own — the screen's own subtitle
            // is what does that, and it only gets the chance if the label is not
            // already ambiguous.
            //
            // ⚠️ ITS GATE RESOLVES TO `.hidden` FOR A VIEWER, so the row is DROPPED for
            // one rather than captioned read-only. That is not the usual call on this
            // list and it is the server's: every route behind the screen excludes
            // `viewer`, the reads included.
            ("Desk", .route(.desk(workspaceId: workspaceId, role: role))),
            // ⛔ THE KEYPAD, AND NOTHING THAT DIALS. `Route.dialer` is one destination
            // for both the keypad and the live call precisely so a restored back stack
            // cannot redial; a shortcut that placed a call from here would hand that
            // property straight back. Same for Rooms above it.
            ("Dial", .route(.dialer(workspaceId: workspaceId, role: role))),
            // ⚠️ THE ROW OPENS THE HUB, NOT A SECTION. The hub is where the tenancy card
            // and Enable live, and a workspace with no booking page has nothing to show
            // in any of the nine sections — so landing anywhere else would be a screen
            // whose every read answers `scheduling_not_ready`.
            ("Scheduling", .route(.scheduling(workspaceId: workspaceId, role: role, section: .hub))),
            // ⛔ "Support" IS HELP **FROM DISTRONODE** AND MUST NOT BE RENAMED TO
            // ANYTHING THAT COULD ALSO DESCRIBE THE TENANT'S OWN DESK. The web
            // sidebar carries the same instruction beside its two entries: both
            // surfaces have requests and threads, and a bare "Tickets" on either one
            // collapses the distinction a nav label is the only thing carrying.
            //
            // ⚠️ HERE RATHER THAN BESIDE BILLING, on the web's own reasoning: it is an
            // account-level surface like Billing and Workspaces rather than a daily
            // operating tool. ⛔ Its gate resolves to `.hidden` for a viewer, so this
            // row simply does not appear for one — every route behind it excludes
            // them, the reads included.
            ("Support", .route(.support(workspaceId: workspaceId, role: role))),
            ("Workspace settings", .route(.workspaceSettings(workspaceId: workspaceId, role: role, section: .hub))),
        ]
        return targets.compactMap { title, target in
            let gate = target.gate(role: role)
            if case .hidden = gate {
                return nil
            }
            return OverviewEntry(title: title, target: target, gate: gate)
        }
    }
}
