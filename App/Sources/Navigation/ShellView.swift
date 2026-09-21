import DistrictModel
import Foundation
import SwiftUI

/// The signed-in shell: five tabs, each with its own navigation stack, or on regular
/// width a sidebar beside the section it selects (``RegularShellView``).
///
/// ⛔ ONE PATH PER TAB, HELD IN ``ShellPaths``, AND IT IS NOT A
/// MICRO-OPTIMISATION. A single shared path would make every tab show the same
/// depth, so opening a call from Calls and then tapping Contacts would land on the
/// call again. Android reached the same place through `saveState`/`restoreState` on
/// `navigateTopLevel`, and its note says why it matters: on a long call log, keeping
/// a tab's place is the whole difference between a tab bar and a set of links.
/// ⚠️ The tab bar reads ``ShellPaths``'s compact projection, which is one of two:
/// that type is the navigation state for every layout, and says why it must be.
///
/// ⛔ `navigationDestination(for: Route.self)` IS ATTACHED EXACTLY ONCE PER STACK,
/// HERE. SwiftUI resolves it by TYPE, so a second registration for `Route.self`
/// inside a destination is a runtime coin toss rather than a compile error. Every
/// screen therefore appends a ``Route`` to its stack's path and this file decides
/// what that means, through ``RouteDestinations``.
///
/// ⛔ THE TABS DO NOT EXIST UNTIL A WORKSPACE RESOLVES. Two of the five have nowhere
/// to go without a `workspaceId`, and a tab that does nothing is worse than an
/// absent one. Android gates its nav bar on exactly this (`showNavBar = topLevel &&
/// workspaceId != null`). Until then this view is the workspace gate, and each of
/// the four ways that can fail gets its own sentence: see ``WorkspaceSessionState``.
///
/// ⛔ AND IT IS WHERE A TAPPED NOTIFICATION LANDS, WHICH MAKES THIS FILE THE PLACE A
/// SIGNED-OUT DEVICE DRAWS NOTHING. Kotlin's `PushMessageHandler` states that rule
/// as its own gate, because on Android the push path runs in a service that exists
/// whether or not anybody is signed in. Here it is structural instead: ``RootView``
/// renders this view only from ``AuthPhase/signedIn``, so the routing below cannot
/// run for an account that is no longer on this handset, the case that is
/// genuinely reachable, since the server's `DevicePushToken` row survives a
/// sign-out whose unregister could not be delivered and APNs keeps delivering to a
/// live token regardless. ⚠️ Moving this wiring up to ``RootView`` or into
/// ``DistrictApp`` would silently delete that gate.
struct ShellView: View {
    let container: AppContainer

    /// ⚠️ PASSED IN, NEVER CONSTRUCTED HERE. There is one session model per process
    /// and ``RootView`` owns it; a second one would leave the gate and the account
    /// tab disagreeing about whether the user is signed in, which is precisely the
    /// bug the Android client shipped (two `OverviewViewModel`s, and a successful
    /// sign-in reloading the instance nobody was looking at).
    let session: SessionModel

    /// ⚠️ THREADED THROUGH FROM ``DistrictApp`` LIKE ``session``, NEVER BUILT HERE.
    /// There is one registrar per process and it holds the tapped payload; a second
    /// one would hold the payload nothing was reading. See the ⛔ on
    /// ``PushRegistrar``.
    let push: PushRegistrar

    /// ⚠️ THREADED THROUGH LIKE ``push``, AND THIS VIEW IS ONLY ITS SCREEN RATHER
    /// THAN ITS GATE. ``RootView`` presents this subtree from
    /// ``AuthPhase/signedIn``, but a ring is reported to CallKit above that gate —
    /// so unlike the notification routing below, an inbound call is NOT gated by
    /// this file. What is gated here is the full-screen cover, which is the only
    /// part that needs a window.
    let incoming: IncomingCallModel

    /// ⚠️ FOUR OF THIS VIEW'S `@State` PROPERTIES ARE INTERNAL RATHER THAN `private`,
    /// AND ONLY BECAUSE THE ROUTING LIVES IN `ShellView+Routing.swift`. `private` is
    /// file-scoped in Swift, so an extension in a sibling file cannot see them;
    /// internal is the narrowest level that works, App is one module, and nothing
    /// outside these two files reads any of them. The sibling exists because of the
    /// 500-line `file_length` that `swiftlint --strict` enforces — see its own header.
    /// ⛔ `@State`'s setter is nonmutating, so writing one from an extension is
    /// ordinary rather than a loophole; what is NOT ordinary would be a second view
    /// reading them, and the ⛔s below say why each is here.
    @State var workspaceSession: WorkspaceSessionModel

    /// Every navigation stack, which one is selected, and the tenant they belong to.
    ///
    /// ⛔ THE TENANT IS PART OF THE VALUE RATHER THAN A SECOND `@State`, so a workspace
    /// switch cannot leave the previous tenant's screens pushed under the new tenant's
    /// name. ``ShellPaths`` carries the whole of that reasoning.
    ///
    /// ⛔ AND SO IS THE SELECTED TAB, RATHER THAN A `@State` OF ITS OWN. A hub
    /// section is a tab's screen on compact width and a selection of its own on regular
    /// width, so the two cannot be stored apart without a size-class flip having to
    /// reconcile them.
    @State var paths = ShellPaths()

    /// The outstanding push, if any.
    ///
    /// ⛔ A HOLDER RATHER THAN A DIRECT READ OF THE REGISTRAR, BECAUSE THE PUSH
    /// ARRIVES BEFORE ANYTHING CAN NAVIGATE. On a cold start from a tap the
    /// workspace comes from two requests that are still in flight, so the event has
    /// to be recorded and resolved again once there is something to resolve it
    /// against. ``PushDeepLinks`` owns that rule and is tested on the Linux tier.
    @State var deepLinks = PushDeepLinks()

    /// The outstanding Universal Link, if any.
    ///
    /// ⛔ A SECOND HOLDER RATHER THAN A SHARED ONE, DELIBERATELY, AND ANDROID SPLITS
    /// THEM THE SAME WAY (`AppLinkDeepLinks` beside `PushDeepLinks`). The two carry
    /// different things: a push names a WORKSPACE and is dropped when it is not the
    /// selected one, while a link names a SECTION of a tenant the user just asked for
    /// by tapping a URL. Merging them would mean one nullable field per source and a
    /// resolver that has to ask which arrived. They cannot race meaningfully, since a
    /// person can only have tapped one thing.
    ///
    /// ⚠️ A PLAIN OPTIONAL RATHER THAN A HOLDER TYPE, unlike the push side. There is no
    /// decision to make about a link beyond "can it be acted on yet", and that question
    /// is one pure property on the value itself
    /// (``AppLinkDestination/requiresWorkspace``), so a wrapper would hold nothing.
    @State var pendingLink: AppLinkDestination?

    /// Bumped once per message push that reaches the inbox.
    ///
    /// ⛔ A COUNTER RATHER THAN A CALL, BECAUSE THIS VIEW CANNOT REACH AN
    /// ``InboxModel``. That model is `@State` on the tab root and is rebuilt with the
    /// view's identity on a workspace change; the shell holds neither it nor a way to
    /// find it. A monotonic value the shell writes and the tab observes is the
    /// SwiftUI-shaped version of "something arrived".
    ///
    /// ⛔ AND IT MUST STAY A COUNTER RATHER THAN A `Bool` OR THE EVENT ITSELF. The tab
    /// reacts through `onChange`, which compares values, so two pushes carrying the
    /// same payload — a second message in the same thread — would not register as a
    /// change and the second refresh would never happen. `Int` overflow is not a
    /// consideration at one increment per notification.
    ///
    /// ⛔ IT IS NOT POLLING AND MUST NOT BECOME A TIMER. ``InboxModel``'s own header
    /// argues against a foreground poll and calls a push channel the right answer; this
    /// is that channel. Nothing here schedules anything.
    @State var inboxPushSignal = 0

    /// The claimed URL that is being handed back to the web, if any.
    ///
    /// ⛔ SEPARATE FROM ``pendingLink`` BECAUSE IT NEVER WAITS FOR ANYTHING. A destination
    /// can be held until a workspace resolves; a hand-off has nothing to resolve against
    /// and is presented the moment it is made. Merging them would put a browser sheet
    /// behind the workspace gate, so a link to a page this app does not draw would sit
    /// doing nothing on exactly the cold start it exists for.
    @State private var browserHandOff: AppLinkHandOff?

    /// Where the hardware keyboard's commands meet the screens. See ``ShellCommandCenter``.
    @State private var commands = ShellCommandCenter()

    /// ⚠️ THE ONE READ OF THE SIZE CLASS, AND IT IS THE SIZE CLASS RATHER THAN THE
    /// DEVICE. An iPad in narrow Split View or Slide Over is compact and gets the tab bar.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(
        container: AppContainer,
        session: SessionModel,
        push: PushRegistrar,
        incoming: IncomingCallModel
    ) {
        self.container = container
        self.session = session
        self.push = push
        self.incoming = incoming
        _workspaceSession = State(initialValue: WorkspaceSessionModel(container: container))
    }

    var body: some View {
        gate
            .task {
                // ⚠️ Once per appearance of this view identity, not per redraw.
                await workspaceSession.load()
            }
            // ⚠️ `initial: true` BECAUSE THE PAYLOAD CAN ALREADY BE THERE. The
            // registrar attaches itself to the delegate from ``RootView``'s
            // `onAppear`, which drains ``PushTapRelay``'s buffered cold-start tap,
            // and SwiftUI does not promise that runs before or after this view's
            // first evaluation. Firing on the initial value as well as on changes
            // is what makes the order not matter.
            .onChange(of: push.pendingTapPayload, initial: true) { adoptTappedPush() }
            // ⛔ THE SECOND TRIGGER IS THE ONE THE COLD START NEEDS. A tap resolves
            // to ``PushDeepLinkDecision/wait`` until a workspace exists, so without
            // this the deep link would work only when the app was already open,
            // which is never in the case it exists for. Kotlin's
            // `PushDeepLinkEffect` keys its effect on the same two values.
            .onChange(of: workspaceSession.workspaceId) {
                // ⛔ FIRST, AND THE ORDER IS LOAD BEARING. This drops the previous
                // tenant's pushed screens; the two resolvers below may append a route
                // for the NEW tenant, and running them the other way round would clear
                // the destination a deep link had just installed.
                paths.adopt(workspaceSession.workspaceId)
                resolvePendingPush()
                // ⛔ THE SAME SECOND TRIGGER THE PUSH PATH NEEDS, FOR THE SAME REASON. A
                // cold start from a tapped link resolves while the workspace list is
                // still in flight, so a destination that needs a tenant waits here for
                // the one read that can supply it.
                resolvePendingLink()
            }
            // ⛔ `onOpenURL` IS THE UNIVERSAL-LINK ENTRY POINT ON iOS 17, NOT
            // `onContinueUserActivity(NSUserActivityTypeBrowsingWeb)`. SwiftUI delivers
            // a verified web link to this modifier in a SwiftUI lifecycle app, on a warm
            // open and on a COLD start alike. The launch URL arrives here after the
            // scene appears, so there is nothing extra to write for the cold path and
            // nothing to read out of a launch options dictionary.
            //
            // ⛔ AND IT IS ATTACHED HERE RATHER THAN ON ``RootView`` OR ``DistrictApp``
            // BECAUSE THIS VIEW IS THE SIGNED-IN GATE. `RootView` renders this subtree
            // only from ``AuthPhase/signedIn``, so a link arriving on a handset that is
            // signed out reaches nothing and the app simply opens on the sign-in screen,
            // which is the honest outcome: there is no session to resolve a workspace
            // with. Moving this modifier up would silently delete that gate, exactly as
            // the ⛔ at the top of this file says of the push wiring.
            //
            // ⚠️ THE AUTH CALLBACK DOES NOT COME THROUGH HERE AND MUST NOT BE MADE TO.
            // `ASWebAuthenticationSession` intercepts `districtai://auth` IN-SESSION
            // (``WebAuthLoginController``), which is what closes the custom-scheme
            // hijack surface; the resolver refuses a non-https URL anyway, so a stray
            // one is left alone rather than swallowed.
            //
            // ⛔ THREE ANSWERS, AND THE MIDDLE ONE IS NOT THE SAME AS EITHER NEIGHBOUR.
            // nil is "never ours" and must leave the URL completely alone, or the
            // `districtai://auth` callback would be opened in a browser and sign-in
            // would break. ``AppLinkOutcome/openInBrowser`` is "ours, and the honest
            // answer is the web page". Only the third navigates.
            .onOpenURL { url in
                guard let outcome = AppLinkResolver.resolve(url) else { return }
                switch outcome {
                case .openInBrowser:
                    // ⚠️ THE URL AS DELIVERED, NEVER A REBUILT ONE. Query and fragment
                    // included: the page the tap named is the page that has to open.
                    browserHandOff = AppLinkHandOff(url: url)
                case let .destination(destination):
                    // ⚠️ LAST ONE WINS, no queue. A second link is the one the user is
                    // looking at, and honouring the first afterwards would navigate away
                    // from what they just asked for.
                    pendingLink = destination
                    resolvePendingLink()
                }
            }
            // ⛔ `SFSafariViewController`, NOT `openURL`, AND THE REASON IS A RELAUNCH
            // LOOP RATHER THAN A PREFERENCE. Every URL that reaches this sheet is one
            // the app CLAIMS: `applinks:www.distronode.com` is in the entitlement and
            // the served association file claims `/dashboard/district/*`, which is the
            // only reason the OS handed it to `onOpenURL` at all. Asking the system to
            // open that same URL would ask it to route a claimed https URL, and the
            // routing that brings a claimed URL to the front app is the routing that
            // just brought this one here: app opens link, OS opens app, with no user
            // input anywhere in the cycle. `UIApplication.open` has no option that
            // suppresses it either (`universalLinksOnly` selects that behaviour, it does
            // not disable it), and whether an app is exempted from its OWN claim has
            // changed between iOS versions, so it is not something to bet a launch loop
            // on.
            //
            // ⛔ A SAFARI SHEET CANNOT LOOP, STRUCTURALLY. It renders web content INSIDE
            // this process; associated-domain routing is not consulted, because nothing
            // is being handed to the system to open. There is no intent to intercept, so
            // there is nothing to pin. Android reaches the same guarantee the other way
            // round, by naming a browser package explicitly and REFUSING when it cannot
            // (`CustomTabsLauncher.launchExternally`, whose ⛔ says an implicit intent
            // "is not a wasted tap: it is an unbounded relaunch loop").
            //
            // ⚠️ AND THE SHEET KEEPS THE USER IN THE APP, which is the second reason it
            // is right here. A link tapped from Mail or Messages already cost one app
            // switch; sending it on to Safari would cost another and leave the person
            // two apps away from where they started, for a page they can close with one
            // tap from here.
            .sheet(item: $browserHandOff) { handOff in
                SafariView(url: handOff.url)
            }
            // ⛔ A FULL-SCREEN COVER RATHER THAN A NAVIGATION DESTINATION, and it
            // covers the WHOLE shell rather than one tab. A ring can arrive for a
            // workspace that is not the selected one and while any tab is showing;
            // a destination pushed onto a tab's stack would put a live call behind
            // a back button and, restored after process death, would re-present a
            // call that died with the process.
            //
            // ⚠️ IT IS PRESENTED FROM THE GATE RATHER THAN FROM `tabs`, so a ring
            // that lands while the workspace list is still loading still draws.
            .fullScreenCover(isPresented: incomingCallPresented) {
                IncomingCallView(model: incoming, workspaceName: ringingWorkspaceName)
            }
    }

    // ── The inbound call ─────────────────────────────────────────────────────

    /// ⛔ THE SETTER DISMISSES THROUGH THE MODEL, NEVER BY WRITING STATE. A
    /// swipe-down or an interactive dismissal has to reach
    /// ``IncomingCallEvent/dismissed`` or the reducer would still believe the call
    /// is on screen and the next ring would be dropped as "one call at a time".
    ///
    /// ⚠️ IT CANNOT END A LIVE CALL, because ``IncomingCallEvent/dismissed`` is
    /// absorbed in every phase but `ended`. A cover dismissed mid-conversation
    /// re-presents on the next redraw, which is the correct outcome: the call is
    /// still happening.
    private var incomingCallPresented: Binding<Bool> {
        Binding(
            get: { incoming.isPresented },
            set: { presented in
                guard !presented else { return }
                incoming.dismissEndedCall()
            }
        )
    }

    /// ⚠️ RESOLVED FROM THE LOADED LIST RATHER THAN FROM THE SELECTED WORKSPACE,
    /// because a ring can arrive for any workspace this account belongs to. nil is
    /// ordinary: a cold launch from a VoIP push has not read the list yet, and the
    /// copy degrades to a bare "Incoming call" rather than naming the wrong tenant.
    private var ringingWorkspaceName: String? {
        guard let workspaceId = incoming.workspaceId else { return nil }
        return workspaceSession.workspaces.first { $0.id == workspaceId }?.name
    }

    // ── The gate ─────────────────────────────────────────────────────────────

    @ViewBuilder
    private var gate: some View {
        switch workspaceSession.state {
        case .loading:
            LoadingView(message: "Loading your workspaces…")
        case .content, .partial:
            tabs.shellCommands(
                commands,
                paths: $paths,
                workspaceId: workspaceSession.workspaceId,
                role: workspaceSession.role,
                regular: horizontalSizeClass == .regular
            )
        case let .degraded(message):
            FailureView(failure: FailureText(message: message, action: .retry), onRetry: reload)
        case .empty:
            EmptyStateView(
                systemImage: "building.2",
                title: "No workspaces yet",
                message: "This account does not belong to a workspace. Ask whoever invited you to add you to one."
            )
        case let .lapsed(inactiveCount):
            lapsed(inactiveCount: inactiveCount)
        case let .failed(failure):
            FailureView(failure: failure, onRetry: reload, onSignIn: signIn)
        }
    }

    /// ⛔ STATES THE FACT AND STOPS, AND NAMES NO WEBSITE. Billing is read-only in this
    /// app: Guideline 3.1.3(b) forbids a purchase path, and a "renew" button here is the
    /// kind of thing that fails review after the build is already waiting — while 3.1.1
    /// makes the same rejection out of a sentence that names where to renew instead. A
    /// reactivation is a billing action, so no remedy can be given here at all. It must
    /// also never be worded as "you have no workspaces", which is the state next door and
    /// a different sentence entirely.
    private func lapsed(inactiveCount: Int) -> some View {
        let noun = inactiveCount == 1 ? "workspace is" : "workspaces are"
        return EmptyStateView(
            systemImage: "creditcard",
            title: "Subscription not active",
            message: "Your \(noun) paused because the subscription is not active."
        )
    }

    // ── The tabs ─────────────────────────────────────────────────────────────

    /// ⛔ THE SIZE-CLASS SWITCH IS HERE, INSIDE THE GATE, AND NOWHERE ABOVE IT. Everything
    /// presented from the gate (the incoming-call cover, the browser sheet) stays attached
    /// to a view that exists in both layouts, so a rotation can never dismiss a ring. Both
    /// branches read and write the one ``ShellPaths``, which is what makes the flip a
    /// change of view rather than of state.
    ///
    /// ⛔ `districtBackground()` GOES ON THE STACK ROOT **AND** ON THE PUSHED
    /// DESTINATION, AND NEITHER IS REDUNDANT. A `NavigationStack` supplies an opaque
    /// container background of its own — black in dark, white in light — which covers
    /// `RootView`'s painted page, so without this the whole signed-in app would lose it
    /// while the screens outside the tabs kept it. A pushed screen is a second container
    /// with the same default, so the destination needs its own.
    /// ⚠️ Painting on the `TabView` instead does NOT work: the stacks are above it.
    /// See `ShellBackground.swift`.
    @ViewBuilder
    private var tabs: some View {
        if horizontalSizeClass == .regular, let workspaceId = workspaceSession.workspaceId {
            RegularShellView(
                container: container,
                session: session,
                workspaceSession: workspaceSession,
                push: push,
                workspaceId: workspaceId,
                paths: $paths,
                inboxPushSignal: inboxPushSignal,
                onSignIn: signIn
            )
        } else {
            tabBar
        }
    }

    private var tabBar: some View {
        TabView(selection: $paths.compactTab) {
            ForEach(Tab.allCases, id: \.self) { tab in
                NavigationStack(path: path(for: tab)) {
                    root(for: tab)
                        .districtBackground()
                        .navigationDestination(for: Route.self) { route in
                            RouteDestinations.view(
                                for: route,
                                container: container,
                                session: workspaceSession,
                                accountSession: session
                            )
                            .districtBackground()
                        }
                }
                .tabItem { Label(tab.label, systemImage: tab.systemImage) }
                .tag(tab)
                // ⛔ THIS TAGS THE TAB'S CONTENT, NOT ITS BUTTON, AS A DEVICE RUN SHOWS.
                // `.tabItem` takes no
                // identifier, so the tab-bar button keeps only its label; on an iPhone XS
                // Max the tree showed `district-nav-overview` as a full-screen `Other`
                // and the TabBar holding `Button, label: 'Overview'`. A test TAPS by
                // label (``A11yID/NavLabel``) and uses this id to assert which tab is
                // showing.
                .accessibilityIdentifier(tab.accessibilityID)
            }
        }
    }

    /// ⚠️ EACH ARM HANDS THE FEATURE ITS RESOLVED WORKSPACE; the feature owns its own
    /// loading, empty, failed and partial states.
    ///
    /// ⚠️ THE WORKSPACE IS UNWRAPPED ONCE RATHER THAN FORCED PER ARM. The tabs only
    /// render from `.content` / `.partial`, where a selection has resolved, so the
    /// fallback is unreachable today; it is a loading view rather than a crash so
    /// that a future state which renders tabs without a selection degrades to
    /// "still loading" instead of taking the app down.
    @ViewBuilder
    private func root(for tab: Tab) -> some View {
        if let workspaceId = workspaceSession.workspaceId {
            switch tab {
            case .overview:
                OverviewView(
                    container: container,
                    session: session,
                    workspaceSession: workspaceSession,
                    onSignIn: signIn,
                    // ⛔ THE ONE WAY INTO THE SELECTED TAB FROM INSIDE A TAB. The overview
                    // carries entries for Calls and Contacts, which are tab roots here
                    // and ordinary destinations on Android; pushing them would give the
                    // app a second copy of a screen the tab bar already owns.
                    onSelectTab: { paths.compactTab = $0 }
                )
            case .inbox:
                // ⛔ IT TAKES THIS TAB'S PATH, WHICH NO OTHER TAB ROOT DOES, AND THE
                // REASON IS THE COMPOSE SHEET. A send creates a thread whose key only
                // the server knows, so the destination is not available until two
                // requests have answered — and a `navigationDestination` inside the tab
                // would be a second registration for `Route.self`, which SwiftUI
                // resolves by TYPE. Writing through the binding is how a tab root pushes
                // without owning a stack. Every ordinary row still uses
                // `NavigationLink(value:)`.
                InboxView(
                    container: container,
                    workspaceId: workspaceId,
                    role: workspaceSession.role,
                    path: path(for: .inbox),
                    pushSignal: inboxPushSignal
                )
            case .calls:
                CallLogView(container: container, workspaceId: workspaceId)
            case .contacts:
                ContactsView(container: container, workspaceId: workspaceId, role: workspaceSession.role)
            case .account:
                AccountView(container: container, session: session, push: push)
            }
        } else {
            LoadingView(message: "Loading your workspace…")
        }
    }

    /// ⚠️ A BINDING BUILT ON DEMAND. `@State`'s setter is nonmutating, which is what
    /// lets this write from a non-mutating context. What a tab shows, and what a write
    /// to it opens or closes, is ``ShellPaths``'s compact projection.
    private func path(for tab: Tab) -> Binding<[Route]> {
        Binding(
            get: { paths.compactPath(for: tab) },
            set: { paths.setCompactPath($0, for: tab) }
        )
    }

    private func reload() {
        Task { await workspaceSession.load() }
    }

    private func signIn() {
        Task { await session.signIn() }
    }
}
