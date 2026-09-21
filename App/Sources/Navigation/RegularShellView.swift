import DistrictModel
import SwiftUI

/// The signed-in shell on regular width: a sidebar of every section, and the section
/// beside it.
///
/// ⛔ IT OWNS NO NAVIGATION STATE. The selection and every stack live in ``ShellPaths``,
/// which ``ShellView`` holds as `@State` above both layouts; this view reads that value
/// and writes it back through bindings. A rotation or a Split View resize that flips the
/// size class destroys this view and builds the tab bar from the same value (and the
/// reverse), so the flip changes what is drawn and never where anybody is. ``ShellPaths``
/// argues why that has to be exact: a live call's controls are a pushed screen.
///
/// ⛔ TWO SPLIT VIEWS, ONE PER COLUMN COUNT, SHARING ONE SIDEBAR AND ONE STATE. A list
/// section (Calls, Inbox, Contacts, Desk, Support) is three columns: the sidebar, its list,
/// and the open row beside it. Everything else is a screen of its own and gets the whole
/// detail column. A `NavigationSplitView`'s column count is fixed when it is built, and the
/// alternatives to building two were worse than the cost: a three-column view always would
/// leave a dashboard, a form or the dialler either squeezed into a list-width column or
/// sitting beside an empty one, and hiding the middle column has no public API (the
/// visibility states hide the sidebar, not the content column). The cost is that moving
/// between a list section and any other rebuilds the split view, sidebar included; the
/// sidebar is short enough that its scroll position rarely matters, and its selection is
/// the shared state, so it is redrawn highlighted where it was.
///
/// ⛔ `navigationDestination(for: Route.self)` IS REGISTERED ONCE PER STACK, ON THE DETAIL
/// COLUMN'S STACK, AND NEVER IN THE SIDEBAR OR THE CONTENT COLUMN. Neither of those has a
/// stack: the sidebar selects a section and a list's rows select a route, and a second
/// registration for `Route.self` is the runtime coin toss ``ShellView`` warns about.
///
/// ⚠️ THE SIDEBAR IS GATED BY THE WORKSPACE LIST'S ROLE, WHICH IS THE ONLY ROLE THE SHELL
/// HAS. The Overview's own entry column gates on the role its read reports, which can be
/// wider (see the ⛔ on `OverviewView.entryPoints`); the sidebar cannot wait for that read.
/// A selection the sidebar does not offer is drawn as the Overview rather than written
/// over, so a flip back to the tab bar finds the stack it left.
struct RegularShellView: View {
    let container: AppContainer
    let session: SessionModel
    let workspaceSession: WorkspaceSessionModel
    let push: PushRegistrar
    let workspaceId: String
    @Binding var paths: ShellPaths
    let inboxPushSignal: Int
    let onSignIn: () -> Void

    /// ⚠️ ONE VALUE FOR BOTH SPLIT VIEWS, RESET WHENEVER THE COLUMN COUNT CHANGES. The two
    /// read the same case differently (`.doubleColumn` is the sidebar and detail in one and
    /// the list and detail in the other), so carrying a value across would open the new
    /// view in a state nobody chose. `.automatic` is the system's answer for the width:
    /// every column that fits in landscape, the sidebar behind its button in portrait.
    @State private var columns: NavigationSplitViewVisibility = .automatic

    private var role: WorkspaceRole? {
        workspaceSession.role
    }

    private var entries: [SidebarEntry] {
        SidebarItem.entries(workspaceId: workspaceId, role: role)
    }

    /// The section on screen: the stored selection when the sidebar offers it, and the
    /// Overview when it does not. See the ⚠️ on the type.
    private var shown: SidebarItem {
        let selected = paths.regularSelection
        return entries.contains { $0.item == selected } ? selected : .overview
    }

    var body: some View {
        let item = shown
        let rows = entries
        Group {
            if item.isListSection {
                NavigationSplitView(columnVisibility: $columns) {
                    sidebar(rows, showing: item)
                } content: {
                    listColumn(item)
                } detail: {
                    listDetail(item)
                }
            } else {
                NavigationSplitView(columnVisibility: $columns) {
                    sidebar(rows, showing: item)
                } detail: {
                    sectionDetail(item)
                }
            }
        }
        // ⚠️ THE SIDEBAR'S OWN SETTER RESETS FIRST, IN THE SAME UPDATE; this catches the
        // moves that do not come from the sidebar (a push, a link, the Overview's tab rows).
        .onChange(of: item.isListSection) { columns = .automatic }
    }

    // ── The sidebar ──────────────────────────────────────────────────────────

    private func sidebar(_ rows: [SidebarEntry], showing item: SidebarItem) -> some View {
        List(selection: sidebarSelection(showing: item)) {
            ForEach(rows) { entry in
                SidebarRow(entry: entry)
                    .tag(entry.item)
            }
        }
        .listStyle(.sidebar)
        // ⚠️ THE WORKSPACE'S NAME, SO THE SIDEBAR SAYS WHOSE SECTIONS THESE ARE. Every row
        // below opens this tenant's data, and on a phone the Overview's header is where the
        // name is; here the Overview is only one of the rows.
        .navigationTitle(workspaceSession.selectedEntry?.name ?? Tab.overview.label)
    }

    /// ⚠️ A nil WRITE IS IGNORED: nothing a person does deselects a sidebar row, and the
    /// section on screen has to be one of them.
    private func sidebarSelection(showing item: SidebarItem) -> Binding<SidebarItem?> {
        Binding(
            get: { item },
            set: { next in
                guard let next else { return }
                if next.isListSection != shown.isListSection {
                    columns = .automatic
                }
                paths.setRegularSelection(next, workspaceId: workspaceId, role: role)
            }
        )
    }

    // ── List sections: the list, and the open row beside it ──────────────────

    /// The content column.
    ///
    /// ⚠️ DESK AND SUPPORT ARE BUILT FROM THE HUB ROOT AS IT WAS PUSHED, NOT FROM THE
    /// SESSION, exactly as ``RouteDestinations`` builds them on the phone; see the ⛔ on
    /// ``ShellPaths/overviewHubRoot``. `.id` on the root is what gives a different root a
    /// fresh screen, since both views seed their model once per identity.
    @ViewBuilder
    private func listColumn(_ item: SidebarItem) -> some View {
        let selection = listSelection(item)
        Group {
            switch hubRoot(item) {
            case let .desk(hubWorkspace, hubRole):
                DeskView(container: container, workspaceId: hubWorkspace, role: hubRole, selection: selection)
                    .id(hubRoot(item))
            case let .support(hubWorkspace, hubRole):
                SupportView(container: container, workspaceId: hubWorkspace, role: hubRole, selection: selection)
                    .id(hubRoot(item))
            default:
                tabList(item, selection: selection)
            }
        }
        .districtBackground()
    }

    @ViewBuilder
    private func tabList(_ item: SidebarItem, selection: Binding<Route?>) -> some View {
        switch item {
        case .inbox:
            // ⛔ THE WHOLE PATH, AS ON THE PHONE. The compose sheet selects the thread its
            // send created by writing through `selection`, and the list re-reads when a
            // row it had open is left; both read the path, not the tail.
            InboxView(
                container: container,
                workspaceId: workspaceId,
                role: role,
                path: path(for: .inbox),
                pushSignal: inboxPushSignal,
                selection: selection
            )
        case .calls:
            CallLogView(container: container, workspaceId: workspaceId, selection: selection)
        case .contacts:
            ContactsView(container: container, workspaceId: workspaceId, role: role, selection: selection)
        default:
            // ⚠️ UNREACHABLE: ``listColumn(_:)`` is drawn only for the five list sections,
            // and the two that are hubs are handled above.
            EmptyView()
        }
    }

    /// The detail column: the open row as the root of its own stack, or the placeholder.
    ///
    /// ⛔ `.id(first)` GIVES EACH SELECTED ROW A FRESH STACK. The root screens seed their
    /// models once per view identity (``CallDetailView`` holds one call's model), so
    /// without it choosing a second call would redraw the first one's screen under the
    /// second one's route.
    @ViewBuilder
    private func listDetail(_ item: SidebarItem) -> some View {
        if let first = ListDetailPath.selection(in: paths.regularPath(for: item)) {
            NavigationStack(path: tail(for: item)) {
                destination(first)
                    .navigationDestination(for: Route.self) { destination($0) }
            }
            .id(first)
        } else if let placeholder = item.detailPlaceholder {
            DetailPlaceholder(title: placeholder.title, symbol: placeholder.symbol)
                .districtBackground()
        }
    }

    private func listSelection(_ item: SidebarItem) -> Binding<Route?> {
        Binding(
            get: { ListDetailPath.selection(in: paths.regularPath(for: item)) },
            set: { route in
                let next = ListDetailPath.selecting(route, in: paths.regularPath(for: item))
                paths.setRegularPath(next, for: item)
            }
        )
    }

    /// ⚠️ THE SETTER RE-READS THE PATH RATHER THAN CAPTURING IT, so a write from a stack
    /// that is being torn down lands on whatever the section holds now.
    private func tail(for item: SidebarItem) -> Binding<[Route]> {
        Binding(
            get: { ListDetailPath.tail(of: paths.regularPath(for: item)) },
            set: { tail in
                let next = ListDetailPath.replacingTail(tail, in: paths.regularPath(for: item))
                paths.setRegularPath(next, for: item)
            }
        )
    }

    // ── Every other section: the whole detail column ─────────────────────────

    /// ⛔ `.id(item)`, SO EACH SECTION IS ITS OWN STACK. One stack re-pointed at another
    /// section's path would animate the switch as a push or a pop, and would keep the
    /// previous section's root screen alive under the next one's route.
    private func sectionDetail(_ item: SidebarItem) -> some View {
        NavigationStack(path: path(for: item)) {
            sectionRoot(item)
                .districtBackground()
                .navigationDestination(for: Route.self) { destination($0) }
        }
        .id(item)
    }

    @ViewBuilder
    private func sectionRoot(_ item: SidebarItem) -> some View {
        if item == .overview {
            OverviewView(
                container: container,
                session: session,
                workspaceSession: workspaceSession,
                onSignIn: onSignIn,
                // ⚠️ KEPT FOR PARITY WITH THE PHONE, though the rows that call it are
                // not drawn here: the selection it writes is the shared one.
                onSelectTab: { paths.compactTab = $0 }
            )
            .hidingEntryPoints()
        } else if item == .account {
            AccountView(container: container, session: session, push: push)
        } else if let root = hubRoot(item) {
            RouteDestinations.view(
                for: root,
                container: container,
                session: workspaceSession,
                accountSession: session
            )
            .id(root)
        }
    }

    // ── Shared ───────────────────────────────────────────────────────────────

    /// One pushed screen, exactly as ``ShellView`` draws it on the phone.
    private func destination(_ route: Route) -> some View {
        RouteDestinations.view(
            for: route,
            container: container,
            session: workspaceSession,
            accountSession: session
        )
        .districtBackground()
    }

    /// The root a hub section opens on: the one that was pushed, or a fresh one for this
    /// tenant and role if none is open.
    ///
    /// ⚠️ THE FALLBACK SHOULD NOT BE REACHED. ``ShellPaths`` keeps a selected hub and its
    /// open root together; building one here is what keeps a broken invariant a stale
    /// role rather than an empty column.
    private func hubRoot(_ item: SidebarItem) -> Route? {
        if let open = paths.overviewHubRoot, SidebarItem.hubItem(forRoot: open) == item {
            return open
        }
        return item.rootRoute(workspaceId: workspaceId, role: role)
    }

    private func path(for item: SidebarItem) -> Binding<[Route]> {
        Binding(
            get: { paths.regularPath(for: item) },
            set: { paths.setRegularPath($0, for: item) }
        )
    }
}

/// One sidebar row.
///
/// ⚠️ THE `.partial` CAPTION IS A BADGE, which is where a sidebar puts a row's secondary
/// text; it says what the Overview's caption says, in the same word.
private struct SidebarRow: View {
    let entry: SidebarEntry

    var body: some View {
        Label(entry.item.sidebarTitle, systemImage: entry.item.sidebarSymbol)
            .badge(caption.map { Text($0) })
            .accessibilityIdentifier(entry.item.accessibilityID)
    }

    private var caption: String? {
        switch entry.gate {
        case .partial: "Read-only"
        case .hidden, .none: nil
        }
    }
}

private extension OverviewView {
    /// ⚠️ A COPY WITH ITS ENTRY COLUMN OFF, because every row in it is a sidebar row here.
    func hidingEntryPoints() -> OverviewView {
        var copy = self
        copy.showsEntryPoints = false
        return copy
    }
}
