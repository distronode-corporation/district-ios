import DistrictModel
import SwiftUI

/// The Contacts tab root.
///
/// ⛔ `.id(workspaceId)` IS LOAD-BEARING AND IS THE WHOLE REASON THIS WRAPPER
/// EXISTS. ``ContactsModel`` owns one ``OffsetPager`` built for one tenant, and
/// the pager's offsets and dedup set are meaningless across a switch. Seeding
/// `@State` in an initialiser only takes effect for a NEW view identity, so
/// without this the model would survive a workspace change and mix two
/// workspaces' rows.
///
/// ⛔ NO `NavigationStack` HERE. ``ShellView`` provides one per tab and registers
/// `navigationDestination(for: Route.self)` on it exactly once; SwiftUI resolves
/// that by TYPE, so a second registration inside a tab root is a runtime coin
/// toss.
struct ContactsView: View {
    let container: AppContainer
    let workspaceId: String

    /// ⚠️ CARRIED SO IT CAN TRAVEL ON THE ROUTE. ``Route/contactDetail`` holds the
    /// role because a destination restored from a `NavigationPath` after process
    /// death cannot go asking the session for one.
    let role: WorkspaceRole?

    /// The open row, on regular width only; nil on the phone. See ``RouteList``.
    var selection: Binding<Route?>?

    var body: some View {
        ContactsScreen(container: container, workspaceId: workspaceId, role: role, selection: selection)
            .id(workspaceId)
    }
}

/// The contact list for one workspace.
private struct ContactsScreen: View {
    let workspaceId: String
    let role: WorkspaceRole?
    let selection: Binding<Route?>?

    @State private var model: ContactsModel
    @State private var creating = false

    /// ⛔ THE CONTAINER'S ONE STORE. The badge on a row has to appear the moment a
    /// caller is blocked from an inbox thread in another tab; see the ⛔ on
    /// ``BlockedContactsStore``.
    private let blocked: BlockedContactsStore

    init(container: AppContainer, workspaceId: String, role: WorkspaceRole?, selection: Binding<Route?>?) {
        self.workspaceId = workspaceId
        self.role = role
        self.selection = selection
        blocked = container.blockedContacts
        _model = State(
            initialValue: ContactsModel(container: container, workspaceId: workspaceId, role: role)
        )
    }

    var body: some View {
        content
            .navigationTitle("Contacts")
            // ⛔ `.contain` FIRST, or this identifier is inherited by every row and
            // `A11yID.Contacts.row(id)` stops resolving. See SignInView's note.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(A11yID.Contacts.root)
            .toolbar { addContactItem }
            .sheet(isPresented: $creating) {
                CreateContactSheet(model: model)
            }
            .task {
                // ⚠️ Once per appearance of this view identity, not per redraw.
                await model.feed.loadFirst()
            }
            // ⛔ ITS OWN `.task`, SO NEITHER READ CAN SKIP THE OTHER. The blocked
            // set is a separate route and a separate failure; the store's read is
            // silent by design (see ``BlockedContactsStore/refresh(workspaceId:)``)
            // because nobody asked for it.
            .task { await blocked.refresh(workspaceId: workspaceId) }
    }

    // MARK: - Toolbar

    /// ⚠️ OFFERED ONLY TO A ROLE THE SERVER WOULD ADMIT. `contacts/create`
    /// excludes `viewer`, so a viewer tapping this could only ever earn a 403
    /// they cannot act on.
    ///
    /// ⚠️ THE `if` IS INSIDE THE ITEM, NOT AROUND IT, AND THAT IS DELIBERATE. A
    /// conditional at `ToolbarContent` level leans on `ToolbarContentBuilder`
    /// supporting an `if` with no `else`, which is a question only the Mac
    /// compiler can settle; `ToolbarItem`'s content is a plain `@ViewBuilder`,
    /// where it certainly is supported. An empty item renders nothing.
    private var addContactItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if model.canMutate {
                Button("Add contact") { creating = true }
            }
        }
    }

    // MARK: - States

    @ViewBuilder
    private var content: some View {
        switch model.feed.state {
        case .loading:
            skeleton
        case let .content(rows, _, appending, appendFailure):
            list(rows: rows, appending: appending, appendFailure: appendFailure)
        case .empty:
            empty
        case let .failed(failure):
            FailureView(failure: failure, onRetry: reload)
        }
    }

    /// ⚠️ SKELETON ROWS, NOT A CENTRED SPINNER. The list that is arriving has a
    /// known shape, so drawing that shape says what is loading and stops the
    /// layout jumping when it lands.
    private var skeleton: some View {
        VStack(spacing: DistrictSpacing.row) {
            ForEach(0 ..< 6, id: \.self) { _ in
                SkeletonBlock(height: 56)
            }
            Spacer(minLength: 0)
        }
        .padding(DistrictSpacing.gutter)
    }

    /// ⚠️ REACHABLE ONLY AFTER A SUCCESSFUL FIRST PAGE, so it genuinely means "no
    /// contacts". The create action lives INSIDE the empty state rather than only
    /// in the toolbar, because an empty CRM is exactly where the first contact
    /// gets made and pointing at a control elsewhere is a dead end.
    @ViewBuilder
    private var empty: some View {
        if model.canMutate {
            EmptyStateView(
                systemImage: "person.2",
                title: "No contacts yet",
                message: "Callers are added automatically as they come in."
            ) {
                Button("Add a contact") { creating = true }
                    .buttonStyle(.districtPrimary)
            }
        } else {
            EmptyStateView(
                systemImage: "person.2",
                title: "No contacts yet",
                message: "Callers are added automatically as they come in."
            )
        }
    }

    private func list(
        rows: [Contact],
        appending: Bool,
        appendFailure: FailureText?
    ) -> some View {
        RouteList(selection: selection) {
            if !model.canMutate {
                readOnlyCaption
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
            }
            ForEach(rows, id: \.id) { contact in
                // ⛔ THE ROW IS KEYED ON THE CONTACT ID, AND THE PAGER
                // DEDUPLICATES BECAUSE OF IT. `bulk-create` inserts an entire
                // import in one statement, so the boundary row really does get
                // served twice — and a duplicate id in a `ForEach` is a rendering
                // fault, not a cosmetic repeat.
                NavigationLink(
                    value: Route.contactDetail(workspaceId: workspaceId, role: role, contactId: contact.id)
                ) {
                    row(for: contact)
                }
                // ⚠️ SUFFIXED WITH THE SERVER'S OWN ID, so a test addresses
                // `ct-review-01` rather than "the third row" — re-ordering the list
                // must not turn into a failure somewhere unrelated.
                .accessibilityIdentifier(A11yID.Contacts.row(contact.id))
                .rowContextMenu(RowContextActions.contact(phone: contact.phoneNumber, email: contact.email))
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .onAppear { reachedEnd(of: rows, at: contact) }
            }
            PagedFeedFooter(appending: appending, appendFailure: appendFailure, onRetry: loadMore)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        // ⚠️ BOTH READS ON THE ONE PULL, SEQUENTIALLY. A second `.refreshable` on
        // an ancestor would not run alongside this one — SwiftUI resolves the
        // nearest — so the blocked set has to be re-read here or a pull would leave
        // a stale badge on a freshly-unblocked row.
        .districtRefreshable {
            await model.feed.refresh()
            await blocked.refresh(workspaceId: workspaceId)
        }
    }

    /// ⚠️ STATED UP FRONT RATHER THAN DISCOVERED BY TAPPING SOMETHING THAT 403s.
    /// Every contacts mutation excludes `viewer` server-side.
    private var readOnlyCaption: some View {
        Text("Read-only access, editing is disabled.")
            .font(DistrictType.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DistrictSpacing.gutter)
            .padding(.vertical, DistrictSpacing.tight)
    }

    private func row(for contact: Contact) -> some View {
        // ⚠️ `name` IS NON-NULL SERVER-SIDE BUT CAN BE THE LITERAL "Unknown",
        // which the voice agent writes for an unidentified caller. Printing it
        // would read as a name; see ``Contact/displayName``.
        let name = contact.displayName
        let title = name ?? "Unnamed contact"
        return DistrictListRow(
            title: title,
            subtitle: Self.subtitle(for: contact, title: title),
            leading: {
                DistrictAvatar(name: name ?? "", tone: name == nil ? .neutral : .district)
            },
            trailing: {
                // ⛔ THE BLOCK BADGE COMES FIRST, BECAUSE IT CHANGES WHAT THE ROW
                // MEANS AND THE OTHER ONE DOES NOT. A blocked caller's threads are
                // gone from the Inbox while their contact row stays here, so a
                // reviewer (and an operator) has to be able to tell at a glance
                // which rows those are. ⚠️ Both can be true at once — an
                // enrichment queued before a block keeps running — so this is not
                // an either/or.
                if blocked.isBlocked(contact.id, in: workspaceId) {
                    BlockedBadge(identifier: A11yID.Contacts.blockedRow(contact.id))
                }
                // ⛔ ONLY WHEN A DOSSIER IS GENUINELY BEING BUILT. A null
                // `dgiStatus` means "none, AND none queued" — `clear-intel` resets
                // it to NULL precisely so nothing re-crawls — so rendering null as
                // pending would promise a job that never finishes.
                if DgiStatus.isInProgress(contact.dgiStatus) {
                    DistrictBadge(text: "Building dossier…", tone: .district)
                }
            }
        )
    }

    /// The identifier line under the name, or nil when there is nothing left to
    /// say that the title has not already said.
    ///
    /// ⛔ THE SERVER WRITES THE IDENTIFIER INTO `name` ON EVERY AUTO-REGISTERED
    /// CONTACT, SO A ROW THAT ECHOES ITSELF IS THE DEFAULT AND NOT THE EDGE CASE. A
    /// contact created for an inbound call is named with the number, and one for an
    /// inbound email with no display name is named with the address, so it lands with
    /// `name == phoneNumber` or `name == email`. Rendering title and subtitle
    /// independently then prints the same value twice, and on a workspace fed by
    /// inbound calls that is a large share of the list.
    ///
    /// ⛔ ANDROID HAS THE SAME DEFECT AND IS NOT THE MODEL HERE. `ContactsScreen.kt`'s
    /// `ContactRow` is `title = displayName ?: unnamed` with
    /// `subtitle = phoneNumber ?: email ?: noContactDetails` and no dedup at all,
    /// so it renders the duplicate too. This mirrors its RULE (name first,
    /// identifier underneath, phone before email) and adds the one thing it is
    /// missing.
    ///
    /// ⚠️ AN IDENTIFIER THAT IS ALREADY THE TITLE IS SUPPRESSED, NOT REPLACED BY
    /// THE PLACEHOLDER. "No phone or email" would be a lie about a contact whose
    /// phone number is the thing on the first line; the honest second line is no
    /// second line. The placeholder is only for a contact that genuinely has
    /// neither.
    ///
    /// ⚠️ A CONTACT WITH BOTH, WHOSE NAME IS ONE OF THEM, GETS THE OTHER. That is
    /// strictly more information than Android shows, and it falls out of taking
    /// the first candidate that is not the title rather than the first candidate.
    private static func subtitle(for contact: Contact, title: String) -> String? {
        // ⚠️ Contacts are EMAIL-FIRST, so a phone-less contact is legal and
        // common. Phone before email, matching Android's preference order.
        let candidates = [contact.phoneNumber, contact.email].compactMap(\.self)
        for candidate in candidates where !readsAsSameValue(candidate, title) {
            return candidate
        }
        // Either the contact has no identifier at all, or every one it has is
        // already the title. Only the first deserves the placeholder, and only
        // when the placeholder would not itself repeat the name.
        guard candidates.isEmpty else { return nil }
        return readsAsSameValue(noIdentifiers, title) ? nil : noIdentifiers
    }

    /// ⚠️ TRIMMED AND CASE-INSENSITIVE, because the two sides are normalised
    /// differently server-side: `email` is stored lowercased by `normalizeAddress`
    /// while `name` keeps whatever was typed, so `Ada@Example.com` over
    /// `ada@example.com` is one value to a reader and two to `==`. It fires
    /// only when the strings are the same value modulo case and whitespace, which
    /// is exactly the duplicate case and never a real name.
    private static func readsAsSameValue(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        return left.caseInsensitiveCompare(right) == .orderedSame
    }

    private static let noIdentifiers = "No phone or email"

    // MARK: - Actions

    /// ⚠️ `.onAppear` ON THE LAST ROW IS THE PAGINATION TRIGGER. ``ContactsModel``
    /// guards it, so firing repeatedly while a window is in flight costs nothing.
    private func reachedEnd(of rows: [Contact], at contact: Contact) {
        guard contact.id == rows.last?.id else { return }
        loadMore()
    }

    private func loadMore() {
        Task { await model.feed.loadMore() }
    }

    private func reload() {
        Task { await model.feed.loadFirst() }
    }
}
