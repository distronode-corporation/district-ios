import DistrictModel
import Foundation

/// Every push destination in the app, seeded in full so that a feature
/// adds files under `Features/<Name>/` and changes ONE line in
/// ``RouteDestinations``.
///
/// ⛔ EVERY WORKSPACE-SCOPED CASE CARRIES ITS `workspaceId`, AND THAT IS NOT
/// REDUNDANCY. Reading the active workspace from ``WorkspaceSessionModel`` at render
/// time would be shorter, but a destination restored from a `NavigationPath` after
/// the app is killed would then render against whatever the session happened to hold
/// by then, or against nothing. Carrying it in the value makes each destination
/// self-describing, which is also what a push deep link needs. The Android client
/// carries the same rule in its nav host.
///
/// ⛔ AND THE ROLE TRAVELS WITH IT FOR THE SAME REASON, wherever the destination has
/// something to gate or something to word. It is `Optional` because
/// ``WorkspaceRole/fromWire(_:)`` fails CLOSED: nil means "the role could not be
/// established", never "assume client". See ``RouteGate``.
///
/// ⛔ SIGN-IN IS NOT A ROUTE. Whether a session exists is derived state, not a
/// navigation question. Putting sign-in in a back stack means owning the invariant
/// "you may never navigate back into the app after signing out", which is exactly
/// what a back stack quietly violates. ``RootView`` chooses between the shell and
/// the sign-in screen instead.
///
/// ⚠️ Case names match Android's `Routes` constants; the mapping is named in each
/// comment so a change on either client is greppable from the other.
///
/// ⚠️ `Sendable` IS STATED RATHER THAN LEFT TO INFERENCE. Swift would infer it for an
/// internal enum whose payloads are all `Sendable`, and it does hold today
/// (`String`, ``WorkspaceRole`` and ``SettingsSection`` each are), but the
/// conformance is load-bearing the moment a value of this type is a stored property
/// of a `Sendable` struct, which it now is (``PushRouteAction/route``). Written out,
/// a future case carrying a non-`Sendable` payload fails HERE, where the reason is
/// visible, rather than at that unrelated struct's declaration.
enum Route: Hashable, Sendable {
    /// `Routes.CALL_DETAIL`.
    case callDetail(workspaceId: String, callId: String)

    /// `Routes.THREAD`.
    ///
    /// ⚠️ `threadKey` IS A SINGLE OPAQUE VALUE carrying either `contact:<id>` or
    /// `addr:<address>`, which is the server's own form. Splitting it into two
    /// optionals would make the destination ambiguous when only the second is
    /// present, and a thread with no `Contact` row genuinely has no id.
    ///
    /// ⛔ `replyTargets` IS THE WHOLE SET, BEST FIRST, NOT ONE PAIR.
    /// ``ConversationSummary/replyTargets`` knows every channel a thread can be
    /// answered on and orders them; carrying only `.first` would leave the alternative
    /// address out of the process and `ComposerBar.channelStrip` with nothing to
    /// switch to.
    ///
    /// ⛔ AN EMPTY ARRAY MEANS **NO REPLY BOX**, AND NEVER "reply on SMS". A thread
    /// the server marked neither `canSms` nor `canEmail` has no reachable address, so
    /// the destination must offer no composer rather than one whose send is refused.
    ///
    /// ⛔ AND THE PAIRS ARE CHOSEN UPSTREAM AND ONLY TRANSPORTED HERE.
    /// ``ConversationSummary/replyTargets`` gates each one on the SERVER-DECIDED
    /// `canSms`/`canEmail` and picks the address; this route is a courier. Nothing
    /// downstream may derive a channel from the shape of an address, add a target, or
    /// reorder the list — deriving is the exact bug ``ReplyTarget`` exists to prevent,
    /// and reordering would answer an email-only thread with billable SMS again.
    ///
    /// ⚠️ IT IS `Hashable` BECAUSE ``ReplyTarget`` NOW IS. `NavigationPath` requires
    /// the whole `Route` to be, and an `Array` of a `Hashable` element is `Hashable`,
    /// so the conformance is still synthesised.
    case thread(
        workspaceId: String,
        role: WorkspaceRole?,
        threadKey: String,
        replyTargets: [ReplyTarget],
        title: String?
    )

    /// `Routes.CONTACT_DETAIL`.
    case contactDetail(workspaceId: String, role: WorkspaceRole?, contactId: String)

    /// `Routes.HQ`. Carries the role because its confirm control is role-gated.
    case hq(workspaceId: String, role: WorkspaceRole?)

    /// `Routes.ANALYTICS`.
    ///
    /// ⚠️ CARRIES NO ROLE, THE ONLY WORKSPACE-SCOPED DRILL-DOWN THAT DOES NOT. Both
    /// routes behind it admit agency, client and viewer alike, so there is nothing
    /// to gate and nothing to word. A role here would be a value that decides
    /// nothing, which is worse than an absence because the next reader has to
    /// establish that it is unused.
    case analytics(workspaceId: String)

    /// `Routes.MARKETPLACE`.
    ///
    /// ⚠️ CARRIES A ROLE EVEN THOUGH BOTH OF ITS ROUTES ADMIT `viewer`, the opposite
    /// call from ``analytics(workspaceId:)``. There is nothing here to GATE but
    /// there is something to WORD: the read-only caption points an agency or client
    /// member at the other tabs and tells a viewer to ask someone who can. Sending a
    /// viewer somewhere that will also refuse them is worse than saying nothing, and
    /// naming anywhere at all is Guideline 3.1.1 steering.
    case marketplace(workspaceId: String, role: WorkspaceRole?)

    /// `Routes.BILLING`.
    ///
    /// ⛔ WORKSPACE-SCOPED, EVEN THOUGH IT WOULD READ MORE NATURALLY AS AN ACCOUNT
    /// ROW. A plan, an overage cap and a month's metered minutes are properties of
    /// ONE TENANT and the route behind them 404s without a `workspaceId`, while the
    /// account tab is deliberately tenant-free so it survives a workspace that does
    /// not resolve. ⛔ And billing is READ-ONLY here: App Store Review Guideline
    /// 3.1.3(b) forbids offering a purchase path.
    case billing(workspaceId: String, role: WorkspaceRole?)

    /// `Routes.WORKFLOWS`.
    ///
    /// ⚠️ A MONITOR, NOT A SETTINGS SECTION, and the distinction is purpose rather
    /// than subject. Three of its four routes admit viewers and nothing on it is
    /// authored, so filing it under workspace settings would hide "is the follow-up
    /// automation running" behind a gate built for the persona editor, from the role
    /// most likely to be asked to check.
    case workflows(workspaceId: String, role: WorkspaceRole?)

    /// `Routes.ROOMS`. The lobby carries a role because every join hands one to the
    /// room, not because the list is gated.
    case rooms(workspaceId: String, role: WorkspaceRole?)

    /// `Routes.ACTIVE_ROOM`.
    ///
    /// ⛔ CARRIES THE FULL `meet_<workspaceId>_<suffix>` NAME AS ONE VALUE, NOT THE
    /// SUFFIX. The room name is what the token is minted for and what the server
    /// parses the workspace back out of, so a destination restored after process
    /// death must hold the exact string rather than a recipe for rebuilding it. And
    /// rebuilding is precisely where a `video_` name, one character away and a
    /// BILLABLE avatar session, could be produced by mistake. `RoomName` in
    /// `DistrictNetwork` is the only thing that mints one.
    case activeRoom(workspaceId: String, role: WorkspaceRole?, roomName: String)

    /// `Routes.DIALER`.
    ///
    /// ⛔ ONE DESTINATION FOR BOTH THE KEYPAD AND THE LIVE CALL, and the absence of
    /// an in-call route is a safety property rather than a simplification. A call
    /// destination reached by navigation is restored from the path after process
    /// death and the effect that starts the call runs again, placing a SECOND
    /// billable call to the same person with no user action. Holding the call in the
    /// model's state means a killed process comes back to an idle keypad, which is
    /// the truth: the socket died and the call is over.
    case dialer(workspaceId: String, role: WorkspaceRole?)

    /// `Routes.WORKSPACE_SETTINGS` and its sections.
    ///
    /// ⛔ THE ROLE HERE IS A REAL GATE, unlike ``marketplace(workspaceId:role:)`` and
    /// ``billing(workspaceId:role:)`` where it only decides wording. Every route
    /// behind the hub, INCLUDING the config read, excludes `viewer` server-side,
    /// which is unusual on this surface and deliberate: the payload carries staff
    /// transfer numbers and the operator's own prompt.
    case workspaceSettings(workspaceId: String, role: WorkspaceRole?, section: SettingsSection)

    /// The scheduling surface: its hub, its nine sections, and the two drill-downs.
    ///
    /// ⛔ ONE CASE FOR THE WHOLE FAMILY, THE SAME SHAPE AS
    /// ``workspaceSettings(workspaceId:role:section:)`` AND FOR THE SAME REASON. The
    /// sections are CHILDREN of the hub rather than siblings of it, so a back press
    /// from a booking lands on the bookings list and a second back press lands on the
    /// hub. Twelve `Route` cases would be twelve arms in ``RouteDestinations``, which
    /// is already at SwiftLint's ceiling.
    ///
    /// ⚠️ THE ROLE IS CARRIED AGAIN AND IT IS NOT THE GATE ON `canManage`. Beyond
    /// ``OverviewEntry``, it decides whether the recordings screen offers a DOWNLOAD, which is the one affordance on
    /// this surface whose bar is `agency`/`client` while the list beside it admits a
    /// viewer. ⛔ It still does not decide Enable: the status route answers `canManage`
    /// for that, and re-deriving it from a role STRING would hide the button from an
    /// owner whose role did not parse. See the ⛔ in ``RouteDestinations``.
    ///
    /// ⚠️ NO ANDROID COUNTERPART EXISTS YET. `Routes` has no scheduling destination,
    /// so this case is iOS-first rather than ported, and the Android client will need
    /// one when that feature lands on both.
    case scheduling(workspaceId: String, role: WorkspaceRole?, section: SchedulingSection)

    /// Support: this workspace's own requests **with Distronode**.
    ///
    /// ⛔ NOT THE DESK, WHICH IS THE TENANT'S OWN CUSTOMERS' TICKETS. The two
    /// surfaces have requests, threads, replies and a close, so the case names and
    /// the screen labels are the only thing separating them; a bare `tickets` on
    /// either one undoes that.
    ///
    /// ⛔ THE ROLE IS A REAL GATE HERE, LIKE ``dialer(workspaceId:role:)`` AND UNLIKE
    /// ``marketplace(workspaceId:role:)``. Every route behind this destination
    /// excludes `viewer` INCLUDING THE READS, because the payloads are support
    /// correspondence rather than operational status — so the destination is hidden
    /// outright rather than offered read-only. See ``RouteGate``.
    ///
    /// ⚠️ NO ANDROID COUNTERPART YET. `Routes` has no support destination, so this
    /// case is iOS-first rather than ported.
    case support(workspaceId: String, role: WorkspaceRole?)

    /// One support request and its conversation.
    ///
    /// ⛔ THE IDENTIFIER IS A JIRA ISSUE KEY (`DA-42`) **OR** OUR OWN ROW ID, CARRIED
    /// AS ONE OPAQUE VALUE. The server's funnel accepts either spelling, which is
    /// what makes a request that has not been filed yet addressable at all — it has
    /// no key until Atlassian answers, and that window is exactly when a customer is
    /// most likely to open it. Splitting this into two optionals would make the
    /// destination ambiguous when only one is present.
    ///
    /// ⚠️ A SEPARATE CASE RATHER THAN STATE INSIDE ``support(workspaceId:role:)``,
    /// which is the opposite call from the web (one component, two views). The
    /// reasoning there was scroll position and a re-fetch on every back-navigation;
    /// a `NavigationStack` preserves both, and a real destination is what makes the
    /// thread restorable and, later, deep-linkable. ⛔ Safe to restore because
    /// opening a request is an idempotent GET: neither write on that screen is
    /// triggered by arriving at it.
    case supportRequest(workspaceId: String, role: WorkspaceRole?, key: String)
    /// District Desk: the tenant's OWN customers' ticket queue.
    ///
    /// ⛔ NOT THE SUPPORT DESK, AND THE TWO MUST NEVER SHARE A DESTINATION OR A LABEL.
    /// This is the tenant's customers writing to the TENANT; Support is the tenant
    /// writing to DISTRONODE. The web sidebar's source carries a comment demanding the
    /// labels stay apart, and a route named for either one that reached the other is
    /// the sharpest possible version of that mistake.
    ///
    /// ⛔ THE ROLE IS A REAL GATE HERE, like ``workspaceSettings(workspaceId:role:section:)``
    /// and unlike ``marketplace(workspaceId:role:)``. Every one of the nine routes
    /// behind this screen is `["agency","client"]` and excludes `viewer` — the READS
    /// included, which is unusual on this surface and deliberate: the payloads carry a
    /// customer's name, email address and phone number in the clear plus the
    /// correspondence about them.
    ///
    /// ⚠️ NO ANDROID COUNTERPART EXISTS YET. `Routes` has no desk destination, so this
    /// case is iOS-first rather than ported.
    case desk(workspaceId: String, role: WorkspaceRole?)

    /// One ticket and its thread.
    ///
    /// ⛔ A DESTINATION OF ITS OWN RATHER THAN A SELECTION HELD IN THE QUEUE'S MODEL,
    /// which is the opposite call from ``dialer(workspaceId:role:)`` and correct for
    /// the opposite reason. A restored dialer must not re-place a billable call; a
    /// restored ticket re-reads a thread, which is idempotent and is exactly what
    /// someone returning to the app wants to see.
    ///
    /// ⚠️ IT CARRIES THE TICKET ID AND NOTHING ELSE OF THE ROW. A subject cached in the
    /// destination would be the subject as it was when the row was tapped, and it is
    /// the one field an operator can edit on the web mid-conversation.
    case deskTicket(workspaceId: String, role: WorkspaceRole?, ticketId: String)

    /// `Routes.DEVICES`.
    ///
    /// ⛔ NOT WORKSPACE-SCOPED, AND HERE IT IS STRONGER THAN A CONVENTION. A native
    /// session belongs to a USER: none of the three routes behind this screen takes
    /// a `workspaceId` and none could, because the scope comes from the verified
    /// session. A workspace here would encode a tenant into a destination whose data
    /// has none, and would make the screen unreachable in exactly the state someone
    /// needs it most.
    case devices
}

/// The sections under the workspace settings hub.
///
/// ⚠️ THE SECTIONS ARE CHILDREN OF THE HUB rather than siblings of it, which is what
/// makes a back press from a form land on the hub. ``SettingsSection/hub`` is the
/// hub itself, so one case of ``Route`` covers the whole family.
///
/// ⛔ `directory` AND `routing` ARE SEPARATE SECTIONS RATHER THAN ONE "EDITORS"
/// SCREEN, because each loads its own configuration and each save REPLACES a
/// different stored array. A screen hosting both would hand two editors one copy of
/// a value that is the input to a wholesale replace, and the second would be saving
/// from a baseline it never read.
enum SettingsSection: String, Hashable, CaseIterable {
    case hub
    case persona
    case capabilities
    /// ⛔ WHO ANSWERS A CALL, AND IT IS THE ONE CONFIG-BACKED SECTION THAT DOES NOT
    /// HYDRATE FROM `workspace/config`. `workspace/call-handling` is its own route with
    /// its own GET, its PATCH writes a scalar rather than replacing a stored array, and
    /// that PATCH ECHOES the new values — so this screen carries none of the
    /// load-before-you-save obligation the four sections around it do. ⚠️ Its read also
    /// admits `viewer`, unlike `workspace/config`, so it is offered read-only rather
    /// than hidden.
    case calls
    case directory
    case routing
    /// ⚠️ Its READ admits `viewer` while the hub in front of it does not, so it is
    /// unreachable to a viewer only because the hub is. Recorded so that opening the
    /// hub to viewers later is a decision about the persona and capability forms,
    /// which genuinely 403, rather than about this one.
    case knowledge
    /// ⚠️ Same asymmetry as ``knowledge``.
    case messaging
    /// ⛔ THE WRITES HERE ARE AGENCY-ONLY, the narrowest guard in the API, because
    /// these rows are what `getWorkspaceRole` answers from. `WorkspaceRole.canMutate`
    /// is the WRONG gate for them. See ``RouteGate/allowsMembershipWrites(_:)``.
    case members
    /// ⚠️ iOS-first; no Android counterpart yet.
    case scheduling
}
