import DistrictModel
import SwiftUI

/// The Inbox tab root.
///
/// ⛔ `.id(workspaceId)` IS LOAD-BEARING AND IS THE WHOLE REASON THIS WRAPPER EXISTS.
/// Seeding `@State` in an initialiser only takes effect for a NEW view identity, so
/// without this the model would survive a workspace change and show one tenant's
/// threads under another tenant's name. Changing the id discards the identity and runs
/// the initialiser again. Same shape as ``CallLogView``.
///
/// ⚠️ THE ROLE IS NOT PART OF THE IDENTITY, WHICH IS A DELIBERATE NARROWING. Keying on
/// both would rebuild the model whenever the workspace list re-reported a role, and the
/// role only ever moves for a given workspace when someone changes the membership. The
/// cost of the narrow key is that such a change is picked up on the next workspace
/// switch or cold start rather than immediately, and the failure it can produce is the
/// harmless direction: a stale `canReply` of false hides a badge, while a stale true
/// spends one 403 on a bookkeeping write nothing waits for.
///
/// ⛔ NO `NavigationStack` HERE. ``ShellView`` provides one per tab and registers
/// `navigationDestination(for: Route.self)` on it exactly once; SwiftUI resolves that
/// by TYPE, so a second registration inside a tab root is a runtime coin toss.
struct InboxView: View {
    let container: AppContainer
    let workspaceId: String
    /// ⛔ Optional because ``WorkspaceRole/fromWire(_:)`` fails CLOSED: nil means "the
    /// role could not be established", never "assume client".
    let role: WorkspaceRole?

    /// This tab's own navigation path.
    ///
    /// ⛔ PASSED IN RATHER THAN OWNED, AND IT IS THE ONLY WAY THIS SCREEN CAN PUSH
    /// WITHOUT A SECOND `navigationDestination`. ``ShellView`` provides one
    /// `NavigationStack` per tab and registers `navigationDestination(for: Route.self)`
    /// on it exactly once; SwiftUI resolves that by TYPE, so a `navigationDestination`
    /// here would be a runtime coin toss. Every ordinary row uses
    /// `NavigationLink(value:)` and needs none of this — what needs it is the compose
    /// sheet, which has to land the operator in the thread its send CREATED, and that
    /// destination is not known until two requests have answered.
    let path: Binding<[Route]>

    /// Bumped by ``ShellView`` when a message push for this workspace arrives.
    ///
    /// ⛔ A COUNTER RATHER THAN A CALL, BECAUSE THE SHELL CANNOT REACH THE MODEL. The
    /// ``InboxModel`` is `@State` on the screen below and is rebuilt with the view's
    /// identity on a workspace change; the shell holds neither. A monotonic value it can
    /// write and this view can observe is the SwiftUI-shaped version of "tell the inbox
    /// something arrived".
    ///
    /// ⚠️ BY CONSTRUCTION THE INBOX IS ON SCREEN WHEN THIS MOVES. The shell only bumps
    /// it for a decision that also selects the inbox tab, so "while the inbox is on
    /// screen" is a property of the caller rather than a check here.
    let pushSignal: Int

    /// The open row, on regular width only; nil on the phone. See ``RouteList``.
    var selection: Binding<Route?>?

    var body: some View {
        InboxScreen(
            container: container,
            workspaceId: workspaceId,
            role: role,
            path: path,
            pushSignal: pushSignal,
            selection: selection
        )
        .id(workspaceId)
    }
}

/// The conversation list for one workspace.
private struct InboxScreen: View {
    let workspaceId: String
    let role: WorkspaceRole?
    let path: Binding<[Route]>
    let pushSignal: Int
    let selection: Binding<Route?>?

    @State private var model: InboxModel

    /// The compose sheet's model, built once with this screen's identity.
    ///
    /// ⛔ HELD HERE RATHER THAN CONSTRUCTED IN THE `sheet` CLOSURE, SO A PRESENTATION
    /// CANNOT REBUILD IT MID-FLIGHT. That closure is re-evaluated on redraws; a model
    /// built inside it would take its in-flight send state with it. The cost of the
    /// longer lifetime is that the form has to be reset explicitly on open, which is
    /// ``ComposeModel/prepare()``'s job.
    /// ⚠️ It is `.id(workspaceId)`-scoped like ``model``, because a recipient list is a
    /// tenant's own and must not survive a workspace change.
    @State private var compose: ComposeModel

    /// ⛔ THE FIELD'S TEXT LIVES HERE AND THE MODEL IS WRITTEN THROUGH
    /// ``InboxModel/searchQueryChanged(_:)``, never bound directly. That method is
    /// the only thing that arms a debounce, and `.searchable` needs a plain
    /// `Binding<String>` that updates on every keystroke — binding it straight to a
    /// model property would either skip the debounce or put a `Task` cancellation
    /// inside a setter. Same split as ``ThreadModel``'s composer.
    @State private var searchText = ""

    @State private var composing = false

    /// ⛔ THE CONTAINER'S ONE STORE, AND THE LIST FILTERS ON IT. Blocking from a
    /// thread has to take that thread out of this list at once; see the ⛔ on
    /// ``BlockedContactsStore``.
    private let blocked: BlockedContactsStore

    init(
        container: AppContainer,
        workspaceId: String,
        role: WorkspaceRole?,
        path: Binding<[Route]>,
        pushSignal: Int,
        selection: Binding<Route?>?
    ) {
        self.workspaceId = workspaceId
        self.role = role
        self.path = path
        self.pushSignal = pushSignal
        self.selection = selection
        blocked = container.blockedContacts
        // ⚠️ `State(initialValue:)` in `init`, exactly as `CallLogScreen` does it:
        // SwiftUI keeps the value for the lifetime of this view's identity, so the
        // model is not rebuilt on every re-render.
        _model = State(initialValue: InboxModel(container: container, workspaceId: workspaceId, role: role))
        _compose = State(initialValue: ComposeModel(container: container, workspaceId: workspaceId, role: role))
    }

    var body: some View {
        content
            .navigationTitle("Inbox")
            .toolbar { toolbar }
            .sheet(isPresented: $composing) {
                // ⚠️ A CLOSURE LITERAL RATHER THAN `onSent: landed`. The measured
                // compiler abort in `.swiftlint.yml`'s custom rule is specific to a
                // `Binding` setter and a `(Route?) -> Void` parameter forces no
                // reabstraction, so a bare reference would compile — the literal is
                // consistency with the house rule rather than a workaround.
                ComposeSheet(model: compose, onSent: { landed($0) })
            }
            // ⛔ ON THE LIST ROOT, INSIDE ``ShellView``'s `NavigationStack` (or the split
            // view's content column, which has a bar of its own) AND NOT AROUND ONE.
            // `.searchable` attaches its field to the enclosing navigation bar; outside
            // one it would need a second stack, which this list must never have (see
            // the ⛔ on ``InboxView``).
            //
            // ⚠️ IT REPLACES THE LIST RATHER THAN FILTERING IT. The server searches
            // every message in the workspace, including threads the conversation list's
            // 500-message scan window never reached, so a client-side filter over the
            // loaded rows would answer "no matches" for messages the workspace has.
            .searchable(text: $searchText, prompt: "Search messages")
            .commandTargets(canCompose: model.canReply, composing: $composing)
            .onChange(of: searchText) { _, query in
                model.searchQueryChanged(query)
            }
            // ⛔ NOT `initial: true`: the first evaluation is not a push, and `.task` reads.
            .onChange(of: pushSignal) {
                Task { await model.refreshFromPush() }
            }
            // ⛔ RE-READ WHEN A PUSHED SCREEN POPS, WHICH IS HOW THE BADGE CLEARS. The
            // thread recorded the read on the server and this list holds no overlay, so
            // the count comes from a read, never from a guess made on the way in.
            // ⚠️ BESIDE THE DETAIL, LEAVING A THREAD IS A NEW SELECTION RATHER THAN A POP,
            // so on regular width that is a reason too; on the phone the rule is unchanged.
            .onChange(of: path.wrappedValue) { previous, current in
                let popped = current.count < previous.count
                let reselected = selection != nil && ListDetailPath.leftSelection(from: previous, to: current)
                guard popped || reselected else { return }
                Task { await model.load(refreshing: true) }
            }
            .task {
                // ⚠️ Once per appearance of this view identity, not per redraw.
                await model.load()
            }
            // ⛔ ITS OWN `.task`, so neither read can skip the other (the store's is silent).
            .task { await blocked.refresh(workspaceId: workspaceId) }
            // ⛔ `.contain` FIRST, or every row inherits this identifier. Same
            // trap `SignInView`'s root documents.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(A11yID.Inbox.root)
    }

    // MARK: - Controls

    /// Compose, and clear the whole workspace's badge.
    ///
    /// ⛔ BOTH ARE HIDDEN FOR A ROLE THE SERVER WOULD REFUSE rather than drawn and
    /// disabled. `messages/send` and `messages/mark-read` both exclude `viewer`, and a
    /// greyed-out control invites a read-only seat to work out why; ``InboxModel/canReply``
    /// is the same gate the two calls are made behind, so the affordance and the
    /// refusal cannot disagree.
    ///
    /// ⛔ AND "Mark all read" IS ONLY OFFERED WHEN THERE IS SOMETHING TO CLEAR. It marks
    /// every unread inbound row in the WORKSPACE — every colleague's badge goes with it
    /// — so a control that spends that write to change nothing is worse than an absent
    /// one. ⚠️ IT SITS IN `.secondaryAction`, WHICH ON iOS IS THE OVERFLOW MENU, AND THE
    /// EXTRA TAP IS THE POINT: it is not destructive (nothing is deleted, the customer
    /// sees nothing, a repeat marks zero rows) but it does change what every colleague
    /// sees, so it should not be adjacent to the thing an operator reaches for
    /// constantly.
    ///
    /// ⚠️ NEITHER IS DRAWN WHILE A SEARCH IS ON SCREEN. The search REPLACES the list, so
    /// a badge-clearing control there would act on rows the operator is not looking at.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if showsWriteControls {
            ToolbarItem(placement: .primaryAction) {
                Button("New", systemImage: "square.and.pencil") { composing = true }
                    .accessibilityLabel("New message")
            }
            if model.unreadTotal > 0 {
                ToolbarItem(placement: .secondaryAction) {
                    Button("Mark all read") { Task { await model.markAllRead() } }
                }
            }
        }
    }

    /// ⚠️ HOISTED OUT OF THE BUILDER RATHER THAN WRITTEN INLINE. A `ToolbarContent`
    /// builder does accept an `if` whose condition list includes a `case` pattern, and
    /// naming the condition is cheaper than relying on that: this is the one gate on two
    /// controls, and the two reasons behind it are unrelated to each other.
    private var showsWriteControls: Bool {
        guard model.canReply else { return false }
        guard case .idle = model.searchState else { return false }
        return true
    }

    /// Where a freshly sent message lands.
    ///
    /// ⛔ THE LIST IS RE-READ ON EVERY OUTCOME, INCLUDING THE ONE WITH NO ROUTE. A send
    /// whose thread could not be resolved still happened, so the new conversation is in
    /// the workspace and has to appear — that refresh is the whole fallback, and it is
    /// why an unresolvable send is not an error the operator has to act on.
    ///
    /// ⛔ AND THE PUSH IS APPENDED ONTO THIS TAB'S OWN PATH rather than replacing it, so
    /// a back swipe lands on the inbox list. ``ShellView`` owns the stack; this writes
    /// through the binding it passed down, because a `navigationDestination` here would
    /// be a second registration for `Route.self` — a runtime coin toss.
    /// ⚠️ BESIDE THE DETAIL IT IS SELECTED INSTEAD, which writes the same path as
    /// `[route]`: the list is still on screen, so the new thread becomes the open row
    /// rather than a screen stacked on whichever thread was open before.
    private func landed(_ route: Route?) {
        Task { await model.load(refreshing: true) }
        guard let route else { return }
        if let selection {
            selection.wrappedValue = route
        } else {
            path.wrappedValue.append(route)
        }
    }

    // MARK: - States

    /// ⛔ THE SEARCH STATE IS CONSULTED FIRST AND `idle` IS WHAT YIELDS TO THE LIST.
    /// Drawing both would put a filtered-looking list under a set of results that is
    /// not a subset of it, and the two answer different questions.
    @ViewBuilder
    private var content: some View {
        switch model.searchState {
        case .idle:
            // ⚠️ THE PULL-TO-REFRESH LIVES ON THIS ARM RATHER THAN ON THE ROOT, AND
            // THAT IS THE POINT. `refreshable` publishes into the environment and
            // the enclosed `List` consumes it, so on the root it would also arm the
            // SEARCH list — where the gesture would spin a spinner and re-read
            // the conversation list, changing nothing the user could see. A search is
            // refreshed by retyping. The conversation states that draw no scroll view
            // (skeleton, empty, failure) never consumed it either way.
            conversationContent
                .districtRefreshable { await model.load(refreshing: true) }
        case .belowFloor:
            // ⛔ NOT AN EMPTY RESULT. Nothing was searched, so claiming "no matches"
            // would be a false negative this app invented.
            EmptyStateView(
                systemImage: "magnifyingglass",
                title: "Keep typing",
                message: "Search needs at least \(InboxModel.minimumSearchLength) characters."
            )
        case .searching:
            skeleton
        case let .results(hits, capped):
            searchList(hits: hits, capped: capped)
        case .empty:
            // ⚠️ Reachable only after a SUCCESSFUL search, and the copy says the
            // search ran rather than implying the workspace is empty.
            EmptyStateView(
                systemImage: "magnifyingglass",
                title: "No matches",
                message: "No message in this workspace contains that."
            )
        case let .failed(failure):
            // ⛔ A DIFFERENT SCREEN FROM "No matches", ON THE ONE SURFACE WHERE AN
            // EMPTY LIST IS A PLAUSIBLE CORRECT ANSWER. See the ⛔ on
            // ``InboxSearchState``.
            FailureView(failure: failure, onRetry: retrySearch)
        }
    }

    @ViewBuilder
    private var conversationContent: some View {
        switch model.state {
        case .loading:
            skeleton
        case let .content(conversations, isPartial, draftKeys, _):
            // ⛔ FILTERED AT RENDER RATHER THAN IN ``InboxModel``, AND IT IS THE
            // "immediately" HALF OF GUIDELINE 1.2: the server also stops returning
            // blocked threads, but only from the NEXT read.
            // ⚠️ `let` INSIDE THE BUILDER, as `ComposerBar.attachControl` does.
            let visible = conversations.filter { !blocked.isBlocked(conversation: $0, in: workspaceId) }
            if visible.isEmpty {
                noConversations
            } else {
                list(conversations: visible, isPartial: isPartial, draftKeys: draftKeys)
            }
        case .empty:
            // ⚠️ Reachable only after a SUCCESSFUL read, which is what makes an empty
            // state honest here rather than a failure wearing the wrong copy.
            noConversations
        case let .failed(failure):
            FailureView(failure: failure, onRetry: reload)
        }
    }

    /// ⚠️ ONE COPY, TWO ARMS: an empty workspace and one whose every conversation is
    /// with a blocked caller get the same screen. The Contacts tab is where the
    /// blocked set is visible.
    private var noConversations: some View {
        EmptyStateView(
            systemImage: "tray",
            title: "No conversations yet",
            message: "Texts and emails from your customers will appear here."
        )
    }

    /// ⚠️ SKELETON ROWS, NOT A CENTRED SPINNER. The list that is arriving has a known
    /// shape, so drawing that shape says what is loading and stops the layout jumping
    /// when it lands. A spinner on a blank screen conveys only "wait".
    private var skeleton: some View {
        VStack(spacing: DistrictSpacing.row) {
            ForEach(0 ..< 8, id: \.self) { _ in
                SkeletonBlock(height: 56)
            }
            Spacer(minLength: 0)
        }
        .padding(DistrictSpacing.gutter)
    }

    private func list(
        conversations: [ConversationSummary],
        isPartial: Bool,
        draftKeys: Set<String>
    ) -> some View {
        RouteList(selection: selection) {
            // ⛔ KEYED ON `threadKey`, NEVER ON THE COUNTERPART ADDRESS. A contact-keyed
            // thread carries both a phone number and an email, so an address key
            // produces a DUPLICATE identifier the moment one person's SMS and email
            // fold into a single row, and a duplicate id in a `ForEach` is a rendering
            // fault rather than a cosmetic repeat.
            // ⛔ NOTHING BUT THE `NavigationLink` HANDLES THE TAP. A
            // `simultaneousGesture(TapGesture())` that recorded the read here consumed
            // every tap on a real device, so no row opened at all. The thread records its
            // own read (``ThreadModel/recordRead()``); no gesture here.
            ForEach(conversations, id: \.threadKey) { conversation in
                NavigationLink(value: route(for: conversation)) {
                    ConversationRow(
                        conversation: conversation,
                        unreadCount: model.unreadCount(for: conversation),
                        hasDraft: draftKeys.contains(conversation.threadKey)
                    )
                }
                // ⚠️ SUFFIXED WITH THE THREAD KEY, WHICH IS WHAT THE `ForEach` KEYS
                // ON. "The first row" is not an address that survives a reorder.
                .accessibilityIdentifier(A11yID.Inbox.row(conversation.threadKey))
                .rowContextMenu(RowContextActions.thread(counterpart: conversation.counterpart))
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
            }
            if isPartial {
                partialCaption
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
    }

    /// The search results for one query.
    ///
    /// ⛔ KEYED ON `messageId`, NEVER ON `threadKey`. Two matches in one conversation
    /// are two rows the server deliberately sent separately, so a thread key here is
    /// a DUPLICATE identifier — which in a `ForEach` is a rendering fault rather
    /// than a cosmetic repeat, the same trap the conversation list documents from
    /// the other direction.
    private func searchList(hits: [MessageSearchHit], capped: Bool) -> some View {
        RouteList(selection: selection) {
            ForEach(hits, id: \.messageId) { hit in
                // ⛔ THE LINK ALONE HANDLES THE TAP, as in the conversation list.
                NavigationLink(value: route(for: hit)) {
                    MessageSearchRow(hit: hit)
                }
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
            }
            if capped {
                cappedCaption
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
    }

    /// ⛔ STATED, NOT SWALLOWED, exactly as ``partialCaption`` is. The server stopped
    /// at its ceiling, so older matches exist and are not on this screen. There is no
    /// offset to page on, so this is a note rather than a control — and drawing a
    /// full page as if it were every match is the same class of mistake as reporting
    /// a degraded region's absence as "you have no workspaces".
    private var cappedCaption: some View {
        InboxListCaption(text: "Showing the most recent matches. Narrow the search to see older ones.")
    }

    /// ⛔ STATED, NOT SWALLOWED. The scan window was exhausted, so a quiet older thread
    /// is simply absent. Showing a truncated list as if it were complete is the same
    /// class of mistake as reporting a degraded region's absence as "you have no
    /// workspaces". There is nothing to fetch, so this is a note rather than a control.
    private var partialCaption: some View {
        InboxListCaption(text: "Showing recent conversations. Older, quieter threads are not listed.")
    }

    // MARK: - Actions

    /// ⛔ THE REPLY ADDRESSES AND CHANNELS ARE RESOLVED HERE, because this is the only
    /// screen that has them. ``ConversationSummary/replyTargets`` gates them on the
    /// SERVER-DECIDED `canSms`/`canEmail` and never infers sendability from `channels`,
    /// and it never hands over the thread key: `messages/send` passes `to` straight to
    /// the carrier or to Postmark, so `contact:<id>` would dispatch an SMS to a cuid.
    /// An EMPTY array means the thread has nothing to reply on, and the destination
    /// must offer no reply box at all.
    ///
    /// ⛔ THE WHOLE SET TRAVELS, BEST FIRST, NOT `.first`. A single pair would let
    /// `ComposerBar` name a channel and not offer one: the alternative address would
    /// not be in the destination's process at all. The ORDER is the choice —
    /// ``ConversationSummary/replyTargets`` puts the thread's own traffic first, so an
    /// email-only conversation opens on email rather than on billable SMS — and
    /// nothing downstream may reorder it.
    ///
    /// ⚠️ THE THREAD KEY TRAVELS AS ONE OPAQUE VALUE carrying either `contact:<id>` or
    /// `addr:<address>`, which is the server's own form. Splitting it into two optionals
    /// would make the destination ambiguous when only the second is present, and a
    /// thread with no `Contact` row genuinely has no id. See the ⚠️ on ``Route/thread``.
    private func route(for conversation: ConversationSummary) -> Route {
        .thread(
            workspaceId: workspaceId,
            role: role,
            threadKey: conversation.threadKey,
            replyTargets: conversation.replyTargets,
            title: conversation.displayName
        )
    }

    /// Where a search hit opens.
    ///
    /// ⛔ A PUSH ONTO THE EXISTING THREAD ROUTE, NOT A NEW DESTINATION.
    /// ``MessageSearchHit/threadKey`` is the SAME value `getConversationSummaries`
    /// computes — the route resolves it stored-link-first, address-second,
    /// identically to the list — so a hit lands on the conversation the Inbox
    /// already knows about instead of forking a second one.
    ///
    /// ⛔ THE REPLY TARGETS COME FROM THE LOADED CONVERSATION ROW OR FROM NOWHERE.
    /// A hit carries no `canSms`/`canEmail`, and ``ConversationSummary/replyTargets``
    /// gates every entry on exactly those two server-decided flags. Deriving a
    /// channel from the hit's own `kind` would reintroduce the web bug where a
    /// customer who had only ever emailed could not be sent an SMS. See the ⛔ on
    /// ``InboxModel/conversation(forThreadKey:)``.
    ///
    /// ⚠️ SO A HIT IN A THREAD OUTSIDE THE LOADED WINDOW OPENS READ-ONLY, and that
    /// is the truthful outcome rather than a gap: this app does not know whether
    /// that thread can be replied to, and offering a box whose send would be refused
    /// is worse than not offering one. ⚠️ An empty array is what says so.
    private func route(for hit: MessageSearchHit) -> Route {
        .thread(
            workspaceId: workspaceId,
            role: role,
            threadKey: hit.threadKey,
            replyTargets: model.conversation(forThreadKey: hit.threadKey)?.replyTargets ?? [],
            title: hit.displayName
        )
    }

    private func reload() {
        Task { await model.load() }
    }

    /// ⚠️ RE-RUNS THE FIELD'S CURRENT TEXT, not the query that failed. If the
    /// operator edited it while the failure was on screen, the newer text is the one
    /// they want, and it also re-arms the debounce rather than firing immediately.
    private func retrySearch() {
        model.searchQueryChanged(searchText)
    }
}
