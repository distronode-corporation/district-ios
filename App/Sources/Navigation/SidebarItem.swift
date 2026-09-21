import DistrictModel
import Foundation

/// Every top-level place the shell can select: the five tabs, plus the hub sections the
/// Overview lists as pushed destinations.
///
/// ⛔ ONE VOCABULARY FOR BOTH LAYOUTS, AND IT IS WHAT MAKES A SIZE-CLASS FLIP A CHANGE OF
/// VIEW RATHER THAN A CHANGE OF STATE. On compact width a hub section is a screen pushed
/// onto the Overview tab; on regular width it is a sidebar row with a stack of its own.
/// ``ShellPaths`` stores every stack under one of these and projects the same storage
/// both ways, so a rotation or a Split View resize never has to translate one layout's
/// navigation into the other's.
///
/// ⚠️ THE CASE ORDER IS THE SIDEBAR ORDER: the four workspace tabs, the hub sections in
/// ``OverviewEntry/all(workspaceId:role:)``'s order, and `account` last. That last
/// position is deliberate: `account` is the one tab that is not workspace-scoped (see
/// the ⛔ on ``Tab``), so it sits below everything that is.
enum SidebarItem: Hashable, CaseIterable {
    case overview
    case inbox
    case calls
    case contacts
    case hq
    case analytics
    case marketplace
    case billing
    case rooms
    case workflows
    case desk
    case dialer
    case scheduling
    case support
    case settings
    case account

    /// The tab this item IS, or nil for a hub section.
    ///
    /// ⚠️ A HUB SECTION HAS NO TAB OF ITS OWN, AND IT IS NOT "THE OVERVIEW TAB" EITHER.
    /// On compact width it is shown inside the Overview tab, but that is a projection
    /// ``ShellPaths/compactTab`` makes; answering `.overview` here would make every hub
    /// look like the dashboard to any caller asking which tab an item is.
    var tab: Tab? {
        switch self {
        case .overview: .overview
        case .inbox: .inbox
        case .calls: .calls
        case .contacts: .contacts
        case .account: .account
        case .hq, .analytics, .marketplace, .billing, .rooms, .workflows, .desk, .dialer,
             .scheduling, .support, .settings:
            nil
        }
    }

    init(tab: Tab) {
        switch tab {
        case .overview: self = .overview
        case .inbox: self = .inbox
        case .calls: self = .calls
        case .contacts: self = .contacts
        case .account: self = .account
        }
    }

    /// The route a hub section opens on, or nil for a tab.
    ///
    /// ⛔ THE SAME ROUTES ``OverviewEntry`` PUSHES, AND A TEST HOLDS THE TWO TOGETHER.
    /// Scheduling opens its hub and never a section, and Settings opens the settings hub;
    /// both reasons are recorded on the Overview's own rows. A root that differed from
    /// the row's would put two different screens at the bottom of the same section
    /// depending on which layout opened it.
    func rootRoute(workspaceId: String, role: WorkspaceRole?) -> Route? {
        switch self {
        case .overview, .inbox, .calls, .contacts, .account: nil
        case .hq: .hq(workspaceId: workspaceId, role: role)
        case .analytics: .analytics(workspaceId: workspaceId)
        case .marketplace: .marketplace(workspaceId: workspaceId, role: role)
        case .billing: .billing(workspaceId: workspaceId, role: role)
        case .rooms: .rooms(workspaceId: workspaceId, role: role)
        case .workflows: .workflows(workspaceId: workspaceId, role: role)
        case .desk: .desk(workspaceId: workspaceId, role: role)
        case .dialer: .dialer(workspaceId: workspaceId, role: role)
        case .scheduling: .scheduling(workspaceId: workspaceId, role: role, section: .hub)
        case .support: .support(workspaceId: workspaceId, role: role)
        case .settings: .workspaceSettings(workspaceId: workspaceId, role: role, section: .hub)
        }
    }

    /// The hub section whose ROOT this route is, or nil.
    ///
    /// ⛔ EXACTLY THE ROOTS, AND A SECTION OF A HUB IS NOT ONE. `.scheduling` with
    /// `section: .bookings` is a screen pushed ON the scheduling hub, so treating it as a
    /// root would open Scheduling with Bookings at the bottom of its stack, and a back
    /// press from there would skip the hub it belongs under.
    ///
    /// ⚠️ AN EXHAUSTIVE SWITCH WITH NO `default`, like every dispatch over ``Route``: a new
    /// case has to be placed here before the app compiles.
    static func hubItem(forRoot route: Route) -> SidebarItem? {
        switch route {
        case .hq: .hq
        case .analytics: .analytics
        case .marketplace: .marketplace
        case .billing: .billing
        case .rooms: .rooms
        case .workflows: .workflows
        case .desk: .desk
        case .dialer: .dialer
        case .support: .support
        case let .scheduling(_, _, section): section == .hub ? .scheduling : nil
        case let .workspaceSettings(_, _, section): section == .hub ? .settings : nil
        case .callDetail, .thread, .contactDetail, .activeRoom, .supportRequest, .deskTicket,
             .devices:
            nil
        }
    }

    /// The hub section a route belongs under, or nil when it belongs to a tab.
    ///
    /// ⚠️ ONLY A LANDING READS THIS. A screen pushed by a tap stays on whatever stack it
    /// was pushed onto (a room joined from a contact is on the Contacts stack, and
    /// belongs there); this answers where a push or a link that names the route
    /// directly should put it. See ``ShellPaths/apply(_:)``.
    static func owner(of route: Route) -> SidebarItem? {
        ownerRoot(of: route).flatMap { hubItem(forRoot: $0) }
    }

    /// The root of the hub section a route belongs under, built from the route's OWN
    /// workspace and role.
    ///
    /// ⛔ NEVER FROM THE SELECTED WORKSPACE. A link may name a tenant other than the one
    /// on screen, and its route already carries that tenant (with a role scoped to it; see
    /// ``AppLinkRouting``). A root built from the session would put workspace A's hub
    /// under workspace B's ticket.
    static func ownerRoot(of route: Route) -> Route? {
        switch route {
        case .hq, .analytics, .marketplace, .billing, .rooms, .workflows, .desk, .dialer, .support:
            route
        case let .activeRoom(workspaceId, role, _):
            .rooms(workspaceId: workspaceId, role: role)
        case let .deskTicket(workspaceId, role, _):
            .desk(workspaceId: workspaceId, role: role)
        case let .supportRequest(workspaceId, role, _):
            .support(workspaceId: workspaceId, role: role)
        case let .scheduling(workspaceId, role, _):
            .scheduling(workspaceId: workspaceId, role: role, section: .hub)
        case let .workspaceSettings(workspaceId, role, _):
            .workspaceSettings(workspaceId: workspaceId, role: role, section: .hub)
        case .callDetail, .thread, .contactDetail, .devices:
            nil
        }
    }
}

/// One row the regular-width sidebar draws, and how much of it the role may use.
struct SidebarEntry: Hashable, Identifiable {
    let item: SidebarItem
    let gate: RouteGate

    var id: SidebarItem {
        item
    }
}

extension SidebarItem {
    /// The rows the sidebar offers this role, in sidebar order.
    ///
    /// ⛔ DERIVED FROM ``OverviewEntry/all(workspaceId:role:)`` RATHER THAN GATED A
    /// SECOND TIME. The Overview's column already decides which hub sections a role is
    /// offered and drops `.hidden` ones; a sidebar with its own copy of that decision
    /// would be a second list for a role change to be applied to, and the one that gets
    /// missed is a row offering a viewer a screen whose every request 403s.
    ///
    /// ⚠️ THE OVERVIEW'S TAB SHORTCUTS ARE SKIPPED, NOT DUPLICATED. Call Logs and Contacts
    /// are tab rows there because the tab bar owns those screens; here the tabs are rows
    /// already. Their gate comes from ``OverviewEntryTarget/gate(role:)`` too, which is
    /// `.none` for every tab and says why.
    static func entries(workspaceId: String, role: WorkspaceRole?) -> [SidebarEntry] {
        let tabs: (Tab) -> SidebarEntry = { tab in
            SidebarEntry(item: SidebarItem(tab: tab), gate: OverviewEntryTarget.tab(tab).gate(role: role))
        }
        let hubs = OverviewEntry.all(workspaceId: workspaceId, role: role).compactMap { entry -> SidebarEntry? in
            guard case let .route(route) = entry.target, let item = hubItem(forRoot: route) else { return nil }
            return SidebarEntry(item: item, gate: entry.gate)
        }
        return [Tab.overview, .inbox, .calls, .contacts].map(tabs) + hubs + [tabs(.account)]
    }

    /// The items the sidebar offers this role, in sidebar order.
    static func visible(workspaceId: String, role: WorkspaceRole?) -> [SidebarItem] {
        entries(workspaceId: workspaceId, role: role).map(\.item)
    }
}
