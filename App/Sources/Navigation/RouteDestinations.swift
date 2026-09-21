import DistrictNetwork
import SwiftUI

/// The one place a ``Route`` becomes a screen.
///
/// ⛔ ONE SWITCH, ATTACHED ONCE, AND EXHAUSTIVE. `navigationDestination` is registered
/// a single time per stack in ``ShellView``, so this function is the entire routing
/// table: a feature adds files under `Features/<Name>/` and one arm here. Spreading destinations across screens is
/// what makes a navigation graph impossible to read, and SwiftUI additionally resolves
/// `navigationDestination` by TYPE, so two registrations for `Route.self` in one stack
/// is a runtime coin toss rather than a compile error.
///
/// ⚠️ THE CASES ARE GROUPED RATHER THAN LISTED ONE PER LINE, AND THAT IS A LINT
/// CEILING RATHER THAN A DESIGN STATEMENT. `swiftlint --strict` caps cyclomatic
/// complexity at 10 and fifteen separate arms is 15. Grouping keeps the switch
/// EXHAUSTIVE, which is the property worth protecting: a new ``Route`` case fails to
/// compile here until someone decides what it shows. Never reach for a `default`.
///
/// ⚠️ THE ARGUMENTS ARE THE CONTAINER AND THE SESSIONS, NEVER A ROUTE'S OWN MODEL. A
/// destination builds its model from the route's associated values, which are
/// self-describing precisely so a restored back stack does not need the session to
/// have resolved yet. See the ⛔ at the top of ``Route``.
///
/// ⛔ TWO SESSIONS, AND THEY ARE NOT INTERCHANGEABLE. ``session`` is the WORKSPACE
/// session, which every workspace-scoped destination reads. ``accountSession`` is the
/// process's one ``SessionModel``, which `Route.devices` needs: signing out a
/// device can end THIS device's session, so that screen has to drive the local
/// sign-out itself rather than leave the app on a credential the server has retired.
/// ⚠️ The label is `accountSession` rather than `session` only because the workspace
/// one already holds that name here; ``ShellView`` calls them `session` and
/// `workspaceSession`, which is the opposite way round. Read the TYPE, not the label.
///
/// ⚠️ `@MainActor` BECAUSE CASES BUILD `@Observable @MainActor` MODELS.
/// ``CallDetailView/init(container:workspaceId:callId:)`` seeds
/// `State(initialValue: CallDetailModel(…))`, and a main-actor initialiser cannot be
/// called from a nonisolated synchronous context. If the call site in ``ShellView``
/// ever rejects this, the fix is to move the model construction into a `.task`, not
/// to drop the attribute.
enum RouteDestinations {
    @MainActor
    @ViewBuilder
    static func view(
        for route: Route,
        container: AppContainer,
        session: WorkspaceSessionModel,
        accountSession: SessionModel
    ) -> some View {
        switch route {
        case let .callDetail(workspaceId, callId):
            CallDetailView(container: container, workspaceId: workspaceId, callId: callId)

        // ⛔ THE SET IS CARRIED WHOLE AND NOT NARROWED HERE. `Route.thread` holds every
        // channel the thread can be answered on, best first, and the composer is what
        // offers the choice; taking `.first` at this seam is what the old two-optional
        // route did implicitly and is the bug being closed. An EMPTY array means no
        // reply box at all — see the ⛔ on `Route.thread`.
        case let .thread(workspaceId, role, threadKey, replyTargets, title):
            ThreadView(
                container: container,
                workspaceId: workspaceId,
                role: role,
                threadKey: threadKey,
                replyTargets: replyTargets,
                title: title
            )

        case let .contactDetail(workspaceId, role, contactId):
            ContactDetailView(
                container: container,
                workspaceId: workspaceId,
                role: role,
                contactId: contactId
            )

        case let .analytics(workspaceId):
            // ⚠️ NO ROLE, THE ONLY WORKSPACE-SCOPED DRILL-DOWN WITHOUT ONE. Both routes
            // behind this screen admit agency, client and viewer alike, so there is
            // nothing to gate and nothing to word. See the ⚠️ on `Route.analytics`.
            AnalyticsView(container: container, workspaceId: workspaceId)

        // ⛔ ONE ARM FOR THE HUB, THE NINE SECTIONS AND THE TWO DRILL-DOWNS, delegated
        // for the line budget the `helpDestination` comment below records. ⚠️ The role
        // IS carried in: `canManage` still comes from the status read (see the ⛔ on `SchedulingHubView`), but the
        // recordings screen needs a role to decide whether to offer a DOWNLOAD, whose
        // bar is `agency`/`client` while the list beside it admits a viewer.
        case let .scheduling(workspaceId, role, section):
            SchedulingDestinations.view(
                for: section,
                container: container,
                workspaceId: workspaceId,
                role: role
            )

        // ⛔ THE ONE DESTINATION THAT CAN EXECUTE AN ARBITRARY WRITE, and it can only do
        // so through a proposal the operator read and approved. The role is carried
        // because the confirm control is gated on it; the composer is not.
        case let .hq(workspaceId, role):
            HQView(container: container, workspaceId: workspaceId, role: role)

        // ⚠️ A MONITOR RATHER THAN A SETTINGS SECTION, which is why it hangs here beside
        // analytics rather than under the settings hub: three of its four routes admit
        // `viewer` and nothing on it is authored. See the ⚠️ on `Route.workflows`.
        case let .workflows(workspaceId, role):
            WorkflowsView(container: container, workspaceId: workspaceId, role: role)

        // ⛔ ONE CASE FOR THE HUB AND ALL NINE OF ITS SECTIONS, which is what
        // `SettingsSection` is for: the sections are CHILDREN of the hub rather than
        // siblings of it, so a back press from a form lands on the hub. ⚠️ The
        // scheduling section is unreachable here on purpose — the hub navigates to
        // `Route.scheduling` instead, because `SchedulingView` already exists and
        // resolves `canManage` from the server rather than from a role string.
        case let .workspaceSettings(workspaceId, role, section):
            SettingsDestinations.view(
                for: section,
                container: container,
                workspaceId: workspaceId,
                role: role
            )

        // ⛔ THE ONE DESTINATION THAT SPENDS MONEY AND RINGS A STRANGER'S TELEPHONE, and
        // it is ONE destination for both the keypad and the live call. A separate in-call
        // route would be restored from the path after process death and its start effect
        // would run again, placing a second billable call with no user action; see the ⛔
        // on `Route.dialer`.
        case let .dialer(workspaceId, role):
            DialerView(container: container, workspaceId: workspaceId, role: role)

        // ⛔ FOUR ARMS DELEGATED, AND THE DELEGATION IS A LINE BUDGET RATHER THAN A
        // GROUPING. Support and the Desk are OPPOSITE surfaces — Support is this tenant
        // writing to Distronode, the Desk is their own customers writing to them — and
        // nothing about them belongs together except that this function is at
        // SwiftLint's 60-line ceiling. Keeping the switch here
        // EXHAUSTIVE is what matters: a new `Route` still fails to compile at this site,
        // which is the property the house style exists for.
        case .support, .supportRequest, .desk, .deskTicket:
            helpDestination(for: route, container: container)

        // ⚠️ Account-scoped, so it carries no workspace and must stay reachable when
        // no workspace resolves at all.
        // ⛔ IT TAKES THE ACCOUNT SESSION, NOT THE WORKSPACE ONE, which is the reason
        // `accountSession` exists on this signature: "sign out everywhere" and "sign
        // out this device" both end THIS installation's session server-side, and the
        // local half of that is ``SessionModel/signOut()``.
        case .devices:
            DevicesView(container: container, session: accountSession)

        // ⛔ READ ONLY WITH A WEB HAND-OFF, AND THE ROLE IS CARRIED FOR WORDING RATHER
        // THAN FOR A GATE. Both routes behind this screen admit `viewer`, so nothing
        // here is hidden from one; what changes is the read-only caption, which tells
        // an agency or client member where the change happens and tells a viewer who
        // to ask. See the ⚠️ on `Route.marketplace`.
        case let .marketplace(workspaceId, role):
            MarketplaceView(container: container, workspaceId: workspaceId, role: role)

        // ⛔ READ ONLY, AND THE ROLE ONLY DECIDES WORDING. There is nothing on this screen
        // to mutate: App Store Review Guideline 3.1.3(b) keeps subscription purchase and
        // management out of the app, so the screen states what is being billed and says
        // the change is not available here. It names no website, even in prose, which
        // 3.1.1 forbids. The role picks which of the two read-only
        // sentences it says, exactly as `Route.marketplace` will.
        case let .billing(workspaceId, role):
            BillingView(container: container, workspaceId: workspaceId, role: role)

        // ⚠️ THE ROLE IS CARRIED BUT THE LIST IS NOT GATED ON IT. Every join hands a
        // role to the room, and the lobby hides only the START form from a viewer:
        // creating a room is a mutation, attending one is not, and a viewer's token
        // carries `canPublish:false` so the media server already refuses their
        // microphone and camera. See the ⛔ on `RoomsLobbyModel.canStart`.
        case let .rooms(workspaceId, role):
            RoomsLobbyView(container: container, workspaceId: workspaceId, role: role)

        // ⛔ THE ONE DESTINATION THAT PUBLISHES VIDEO, AND IT JOINS NOTHING ON ARRIVAL.
        // This route is restored from the navigation path after process death, so a
        // screen that connected from a `.task` would re-enter a room and re-dispatch
        // its Companion with nobody having asked; `ActiveRoomView` opens on a Join
        // control instead. See the ⛔ on `Route.activeRoom` and on `ActiveRoomModel`.
        //

        // ⛔ THE NAME IS VALIDATED HERE AND NEVER REBUILT. `RoomName(joining:)` is what
        // refuses a `video_` room (a BILLABLE Tavus avatar, one character away) and a
        // bare `Call.id` (which the token route answers with a `supervisor` seat, and
        // the voice agent then unsubscribes the caller's microphone). A name that
        // cannot be one gets a sentence rather than an empty screen.
        case let .activeRoom(_, role, roomName):
            if let room = RoomName(joining: roomName) {
                ActiveRoomView(container: container, roomName: room, role: role)
            } else {
                FailureView(failure: RoomsCopy.unusableName)
            }
            // ⛔ THERE IS NO PLACEHOLDER ARM, AND THERE MUST NEVER BE ONE. Every `Route`
            // case above renders a real screen: a placeholder may not be reachable from a
            // build that goes to external testers (App Store Review Guideline 2.1). The
            // switch stays EXHAUSTIVE with no `default`, so a new `Route`
            // case fails to compile here rather than quietly landing on a stub.
        }
    }

    /// The two help surfaces, split out of ``view(for:container:session:accountSession:)``.
    ///
    /// ⛔ SUPPORT IS HELP **FROM DISTRONODE** AND IS NOT THE DESK, which is the tenant's
    /// own customers' tickets. Two destinations each rather than one, because a thread is
    /// a real screen: a `NavigationStack` keeps the list's place, and a restored thread
    /// route only re-runs an idempotent GET — neither write on either screen is triggered
    /// by arriving at it, which is the property `Route.dialer` deliberately lacks.
    ///
    /// ⛔ THE ROLE IS A REAL GATE ON ALL FOUR. Every route behind them excludes `viewer`,
    /// the READS included, so ``RouteGate`` answers `.hidden` and the Overview drops the
    /// row rather than offering a read-only screen that would 403 on its first request.
    /// It is still carried into the screens, which re-check it at each write's call site:
    /// a control that was not drawn is not a boundary.
    ///
    /// ⚠️ THE `default` HERE IS NOT A HOLE IN THE DISPATCH TABLE. The caller's switch
    /// stays exhaustive and names these four cases explicitly, so a new `Route` still
    /// fails to compile there; this arm is unreachable by construction and exists only
    /// because the parameter is the whole `Route`.
    @MainActor
    @ViewBuilder
    private static func helpDestination(for route: Route, container: AppContainer) -> some View {
        switch route {
        case let .support(workspaceId, role):
            SupportView(container: container, workspaceId: workspaceId, role: role)

        case let .supportRequest(workspaceId, role, key):
            SupportThreadView(container: container, workspaceId: workspaceId, role: role, key: key)

        case let .desk(workspaceId, role):
            DeskView(container: container, workspaceId: workspaceId, role: role)

        // ⚠️ ON ONE LINE BECAUSE THIS FILE IS TIGHT ON BUDGET; wrapping the arguments
        // costs four lines the next feature will need.
        case let .deskTicket(workspaceId, role, ticketId):
            DeskTicketView(container: container, workspaceId: workspaceId, ticketId: ticketId, role: role)

        default:
            EmptyView()
        }
    }
}
