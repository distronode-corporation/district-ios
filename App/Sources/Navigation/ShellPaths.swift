import DistrictModel
import Foundation

/// Where every one of the shell's navigation stacks is, which one is selected, and which
/// tenant they belong to.
///
/// ⛔ ITS OWN TYPE IN ITS OWN FILE, AND THE SECOND HALF IS THE POINT. A bare
/// `[Tab: NavigationPath]` on ``ShellView`` cannot answer "whose screens are these",
/// so the answer would have to be re-derived at every site that changes a workspace,
/// and the site that matters is the one nobody thinks of. Pairing the paths with the
/// workspace id in one value makes the question askable, and a switch that forgets to
/// clear them impossible to write: the only way to change the tenant is
/// ``adopt(_:)``, which clears.
/// ⚠️ The file split is also `file_length`: `ShellView.swift` sits near the 500-line
/// ceiling that `swiftlint --strict` reports as an error, so anything added there has
/// to arrive as a type of its own. Same call `MarketplaceCopy.swift` and
/// `DialerCopy.swift` make.
///
/// ⛔ THE ONE NAVIGATION STATE BOTH LAYOUTS READ, AND A LAYOUT OWNS NONE OF ITS OWN.
/// Compact width draws a tab bar in which a hub section (Billing, Desk, the dialler) is
/// a screen pushed onto the Overview tab; regular width draws a sidebar in which each is
/// a row with its own stack. A rotation, a Split View resize or a Stage Manager drag can
/// flip between the two at any moment and tears down one set of stacks to build the
/// other. The outbound call's controls live on a pushed ``Route/dialer(workspaceId:role:)``
/// and a meeting's on ``Route/activeRoom(workspaceId:role:roomName:)``, so a flip that
/// lost a path would leave a live call or room running with no hang-up anywhere on
/// screen. Storing ONE set of stacks and projecting it both ways
/// (``compactPath(for:)``, ``regularPath(for:)``) makes a flip a change of which view
/// renders, never a translation that can drop something.
///
/// ⛔ ONE PATH PER ITEM, AND IT IS NOT A MICRO-OPTIMISATION. A single shared path would
/// make every tab show the same depth, so opening a call from Calls and then tapping
/// Contacts would land on the call again. ``ShellView``'s own ⛔ carries the full
/// reasoning and Android reaches it through `saveState`/`restoreState`.
///
/// ⚠️ `[Route]` RATHER THAN `NavigationPath`, WHICH IS WHAT MAKES THE PROJECTIONS
/// WRITABLE AT ALL. A `NavigationPath` is type-erased and cannot be read back, so moving
/// its first element into another stack is impossible; an array can be split and
/// joined. Nothing is lost by the narrowing: every pushed value in the app is a
/// ``Route`` and the only `navigationDestination` is ``ShellView``'s, for `Route.self`.
///
/// ⚠️ A VALUE TYPE HELD IN ONE `@State`, so a mutation here is a redraw there.
/// `@State`'s setter is nonmutating, which is what lets ``ShellView`` call the mutating
/// methods below from its own non-mutating helpers.
struct ShellPaths {
    /// ⚠️ ABSENT AND EMPTY ARE THE SAME THING, which is what lets an item's entry appear
    /// the first time something is pushed onto it rather than being seeded for every
    /// item up front. The subscript below is the only reader.
    ///
    /// ⛔ FOR A HUB SECTION THE STORED PATH IS WHAT IS PUSHED BEYOND ITS ROOT, never the
    /// root itself. The root is a sidebar row on regular width and the first push on the
    /// Overview tab on compact; storing it in the path would make it a screen on top of
    /// itself in one of the two.
    private var paths: [SidebarItem: [Route]] = [:]

    /// The item on screen.
    ///
    /// ⛔ A HUB SECTION IS A VALID SELECTION ON BOTH LAYOUTS. On regular width it is the
    /// highlighted sidebar row; on compact it means the Overview tab is showing with that
    /// hub open on it, which ``compactTab`` reads back as `.overview`. Keeping the finer
    /// answer is what lets a flip from compact to regular highlight Billing rather than
    /// the dashboard underneath it.
    ///
    /// ⚠️ WRITTEN ONLY THROUGH THE METHODS BELOW, which keep one invariant: a hub
    /// selection is always the hub in ``overviewHubRoot``, and an `.overview` selection
    /// always has none open.
    private(set) var selection: SidebarItem = .overview

    /// The hub root open on the compact Overview tab, if any.
    ///
    /// ⛔ THE ROUTE AS IT WAS PUSHED, NEVER ONE REBUILT FROM THE CURRENT ROLE. It carries
    /// the `workspaceId` and role it was opened with; recomputing it on read would let a
    /// role refresh change the first element of a live stack, and SwiftUI answers a
    /// changed element by rebuilding the screens above it.
    ///
    /// ⚠️ IT OUTLIVES A TAB SWITCH, exactly as a plain tab stack does: open Billing,
    /// tap Inbox, tap Overview, and Billing is still there.
    private(set) var overviewHubRoot: Route?

    /// The workspace these stacks were built for, or nil while none has resolved.
    ///
    /// ⛔ THE PATHS OUTLIVE THE TABS, WHICH IS WHY THIS EXISTS. Switching workspace
    /// re-reads the list, which puts ``WorkspaceSessionModel`` back on
    /// ``WorkspaceSessionState/loading``, and ``ShellView``'s gate renders `LoadingView`
    /// INSTEAD of the tabs, so every `NavigationStack` is destroyed and rebuilt. This
    /// value is `@State` on that view and survives it, so without this each stack would
    /// be rebuilt from a path still holding the PREVIOUS tenant's routes and re-push them
    /// under the new tenant's name.
    ///
    /// ⛔ NOTHING CROSS-TENANT WOULD BE READ, AND THAT IS NOT THE PROBLEM. Every route
    /// carries its own `workspaceId`, so a re-pushed screen fetches workspace A's data
    /// honestly. What breaks is the PAIRING: ``WorkspaceHeader`` would say B over a
    /// screen showing A, and its own ⛔ calls a name sitting over another tenant's
    /// figures "a silent, confident lie". This value enforces that invariant across the
    /// stack, not only inside the overview.
    ///
    /// ⚠️ AN ID RATHER THAN A FLAG, BECAUSE A RELOAD IS NOT A SWITCH. `workspaceId` goes
    /// A, nil, A for an ordinary retry and A, nil, B for a switch; comparing the
    /// identity is the only thing that tells them apart, and blanking a stack because
    /// somebody pressed Try again would throw away a screen they were reading.
    private var workspaceId: String?

    /// The stored path for one item, with an empty one as the default.
    private subscript(item: SidebarItem) -> [Route] {
        get { paths[item] ?? [] }
        set { paths[item] = newValue }
    }

    /// The hub section ``overviewHubRoot`` opens, if one is open.
    private var openHub: SidebarItem? {
        overviewHubRoot.flatMap { SidebarItem.hubItem(forRoot: $0) }
    }

    // ── Compact width: five tabs ─────────────────────────────────────────────

    /// The tab the tab bar shows.
    ///
    /// ⚠️ SETTING `.overview` REOPENS WHATEVER HUB WAS OPEN ON IT. That is the tab bar's
    /// own behaviour (each tab keeps its place) restated in terms of ``selection``: the
    /// hub was the Overview tab's place.
    var compactTab: Tab {
        get { selection.tab ?? .overview }
        set {
            if newValue == .overview {
                selection = openHub ?? .overview
            } else {
                selection = SidebarItem(tab: newValue)
            }
        }
    }

    /// The whole stack one tab shows.
    ///
    /// ⚠️ ONLY THE OVERVIEW IS A PROJECTION: its stack is the open hub's root followed by
    /// that hub's own path, or the dashboard's path when no hub is open. Every other tab
    /// is its item's stored path unchanged, so for those the two layouts share one stack
    /// with nothing to translate.
    func compactPath(for tab: Tab) -> [Route] {
        guard tab == .overview, let root = overviewHubRoot, let hub = openHub else {
            return self[SidebarItem(tab: tab)]
        }
        return [root] + self[hub]
    }

    /// Store what one tab's `NavigationStack` now holds.
    ///
    /// ⛔ A PATH THAT DOES NOT START WITH A HUB ROOT CLOSES THE OPEN HUB AND EMPTIES ITS
    /// STACK. On a phone, backing out of Billing to the dashboard discards Billing's
    /// screens, and opening it again from the Overview lands on its root; keeping the
    /// hub's path would be state nobody on compact width can see, waiting to surface on
    /// the next rotation to regular width as a screen they had already left.
    ///
    /// ⚠️ A PATH THAT DOES START WITH ONE OPENS THAT HUB, and moves the selection onto it
    /// only if the Overview tab is the one on screen. A write to a tab nobody is looking
    /// at must not change which tab that is. A different hub arriving in place of the
    /// open one is the open one leaving the stack, so its path is emptied as above.
    mutating func setCompactPath(_ path: [Route], for tab: Tab) {
        guard tab == .overview else {
            self[SidebarItem(tab: tab)] = path
            return
        }
        guard let root = path.first, let hub = SidebarItem.hubItem(forRoot: root) else {
            closeOverviewHub()
            self[.overview] = path
            return
        }
        let showing = compactTab == .overview
        if let previous = openHub, previous != hub {
            self[previous] = []
        }
        overviewHubRoot = root
        self[hub] = Array(path.dropFirst())
        // ⚠️ THE DASHBOARD'S OWN PATH IS LEFT ALONE, SO WRITING BACK WHAT WAS READ IS A
        // NO-OP. A stack built in the sidebar layout (a call pushed on the Overview row,
        // then Billing selected) is invisible here but still the Overview row's; clearing
        // it on every write would lose it to a rotation nobody interacted through.
        if showing {
            selection = hub
        }
    }

    private mutating func closeOverviewHub() {
        if let hub = openHub {
            self[hub] = []
            if selection == hub {
                selection = .overview
            }
        }
        overviewHubRoot = nil
    }

    // ── Regular width: one stack per sidebar row ─────────────────────────────

    /// The highlighted sidebar row.
    var regularSelection: SidebarItem {
        selection
    }

    /// Select a sidebar row.
    ///
    /// ⚠️ THE WORKSPACE AND ROLE ARE NEEDED ONLY TO BUILD A HUB'S ROOT, and only when that
    /// hub is not already the open one. Re-selecting the open hub keeps its root as it was
    /// pushed; see the ⛔ on ``overviewHubRoot``.
    ///
    /// ⚠️ SELECTING THE OVERVIEW ROW CLOSES THE OPEN HUB WITHOUT EMPTYING ITS STACK. On
    /// regular width every row keeps its place, like a tab; the hub merely stops being
    /// what a flip to compact would show on the Overview tab, which is the dashboard that
    /// is now on screen.
    mutating func setRegularSelection(_ item: SidebarItem, workspaceId: String, role: WorkspaceRole?) {
        if item == .overview {
            overviewHubRoot = nil
        } else if item.tab == nil, openHub != item {
            overviewHubRoot = item.rootRoute(workspaceId: workspaceId, role: role)
        }
        selection = item
    }

    /// One row's stack: for a hub section, the screens pushed beyond its root.
    func regularPath(for item: SidebarItem) -> [Route] {
        self[item]
    }

    mutating func setRegularPath(_ path: [Route], for item: SidebarItem) {
        self[item] = path
    }

    // ── Landing ──────────────────────────────────────────────────────────────

    /// Select what an action names and put its route on the right stack.
    ///
    /// ⛔ THE PURE HALF OF ``ShellView``'s own `apply`, AND ONLY THAT HALF. Ending a live
    /// room, starting the workspace switch and the ``reset(to:)`` that must precede this
    /// are side effects the view owns; what lives here is which item is selected and what
    /// is on its stack, which is the part a test can pin.
    ///
    /// ⛔ A HUB'S ROUTE LANDS IN THAT HUB, NOT ON THE ACTION'S TAB. A hub root opens its
    /// hub with nothing pushed; a route a hub owns (a desk ticket, a scheduling section,
    /// a room) opens its hub on a FRESH root with the route on top, so a back press lands
    /// on the hub it belongs to rather than on the dashboard. Anything else lands on the
    /// action's tab.
    ///
    /// ⚠️ EVERY LANDING RESETS THE STACK IT LANDS ON, AND THAT IS THE ⛔ ON
    /// ``PushRouteAction`` RESTATED. It is expressed in compact terms (a tab, and the
    /// whole stack it shows) because that is the layout that has to fit a hub and the
    /// dashboard into one stack; the regular projection follows from the same storage.
    mutating func apply(_ action: PushRouteAction) {
        let landing = Self.landing(for: action)
        compactTab = landing.tab
        setCompactPath(landing.path, for: landing.tab)
    }

    private static func landing(for action: PushRouteAction) -> (tab: Tab, path: [Route]) {
        guard let route = action.route else { return (action.tab, []) }
        if SidebarItem.hubItem(forRoot: route) != nil {
            return (.overview, [route])
        }
        if let root = SidebarItem.ownerRoot(of: route) {
            return (.overview, [root, route])
        }
        return (action.tab, [route])
    }

    // ── The tenant ───────────────────────────────────────────────────────────

    /// Take note that `next` is now the workspace on screen, clearing the stacks if it
    /// is a different one.
    ///
    /// ⛔ THE ONE PLACE A SWITCH IS DETECTED, BECAUSE THE SWITCH ITSELF HAPPENS
    /// SOMEWHERE ELSE. ``WorkspacePickerSheet`` dismisses and then calls
    /// ``WorkspaceSessionModel/select(_:)`` directly, so the shell is never told; it
    /// only sees the id change underneath it. Detecting it on the value that holds the
    /// paths, rather than at each call site, is what makes a switch from any future
    /// caller safe by default.
    ///
    /// ⚠️ nil IS THE MIDDLE OF EVERY SWITCH RATHER THAN A CASE OF ITS OWN. A re-read
    /// passes through ``WorkspaceSessionState/loading``, where nothing is selected and
    /// the tabs are not drawn at all, so there is nothing to do until an id resolves.
    ///
    /// ⚠️ AND THE FIRST RESOLUTION IS SEEDED, NOT TREATED AS A CHANGE. A cold start from
    /// a Universal Link appends its route before any workspace has resolved (a link to
    /// `devices` needs none at all), so counting the first id as a switch would wipe the
    /// very destination the launch existed for.
    mutating func adopt(_ next: String?) {
        guard let next else { return }
        guard let previous = workspaceId else {
            workspaceId = next
            return
        }
        guard next != previous else { return }
        reset(to: next)
    }

    /// Make `next` the tenant these stacks belong to, with nothing left on any of them.
    ///
    /// ⛔ EVERY ITEM, NOT THE SELECTED ONE AND NOT ONLY THE FIVE TABS. Each stack keeps
    /// its own place on purpose, so every unselected one is exactly where the previous
    /// tenant's screens would otherwise sit unseen until somebody tapped it, minutes
    /// later, with no switch in sight to explain what they were looking at. The hub
    /// sections are the easy ones to miss: on a phone they are hidden behind the
    /// Overview tab, and clearing only `Tab.allCases` would leave Billing's or the
    /// Desk's screens waiting for the next rotation to a sidebar.
    ///
    /// ⛔ AND THE OPEN HUB'S ROOT GOES TOO, WITH A HUB SELECTION MOVED TO THE OVERVIEW.
    /// The root is a route like any other and carries the previous tenant's
    /// `workspaceId`; leaving it would draw workspace A's billing under workspace B's
    /// name, which is the pairing this type exists to prevent. A tab selection is kept,
    /// because a tab root reads the new tenant on its own.
    ///
    /// ⚠️ BUILDING EACH PATH RATHER THAN EMPTYING THE DICTIONARY. An empty path and an
    /// absent one are the same to the subscript above, and an assignment says "start at
    /// the root" where a removal reads as bookkeeping.
    ///
    /// ⚠️ CALLED DIRECTLY BY ``ShellView/apply(_:)`` as well as by ``adopt(_:)``, and
    /// that is what stops a deep link's own route being cleared a moment after it is
    /// appended: the switch is stamped here, synchronously, so the `onChange` that fires
    /// when the new list resolves sees no change left to make.
    mutating func reset(to next: String) {
        workspaceId = next
        for item in SidebarItem.allCases {
            paths[item] = []
        }
        overviewHubRoot = nil
        if selection.tab == nil {
            selection = .overview
        }
    }
}
