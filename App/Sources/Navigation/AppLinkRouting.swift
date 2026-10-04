import DistrictModel
import Foundation

/// What the shell does about a Universal Link, once ``AppLinkResolver`` has said what
/// the URL MEANS.
///
/// ⛔ THE MIRROR OF ``PushRouting``, AND IT ANSWERS IN THE SAME CURRENCY ON PURPOSE.
/// Both produce a ``PushRouteAction`` and both are applied by ``ShellView/apply(_:)``,
/// so there is exactly ONE piece of code in the app that selects a tab and resets its
/// path. Two movers would be two places for a tab and its stack to disagree, and the
/// disagreement is invisible until someone taps back.
///
/// ⛔ THIS HALF LIVES IN `App/` AND THE RESOLVER LIVES IN `DistrictModel`, WHICH IS
/// THE SAME CUT ANDROID MAKES. `Tab` and ``Route`` name SwiftUI screens and cannot
/// leave the app target; everything about a URL that can be WRONG (which host, which
/// path, which segment, which tenant) is decided on the Linux tier where a test can
/// see it. The Kotlin client splits `AppLinkResolver` from `appLinkRoute` for the
/// identical reason.
///
/// ⛔ ONLY ONE OF THE RESOLVER'S THREE ANSWERS ARRIVES HERE, AND THAT IS WHY THIS TYPE
/// STAYS TOTAL. ``AppLinkOutcome/openInBrowser`` never becomes an
/// ``AppLinkDestination``: ``ShellView`` presents it as a Safari sheet and it moves no
/// tab and appends no route, so there is no arm for it to take below. Adding a
/// ``DistrictSection`` for a screen that does not exist, in order to give the browser
/// case somewhere to go, is exactly the mistake the ⛔ on ``DistrictSection`` refuses.
enum AppLinkRouting {
    /// ⚠️ TOTAL RATHER THAN OPTIONAL, UNLIKE ``PushRouting/action(for:selectedWorkspaceId:)``.
    /// A push can resolve to "do nothing" (wait, drop); a link that got this far was
    /// claimed by the entitlement, delivered by the OS, matched by the resolver AND
    /// mapped to a section this app can draw, so there is always somewhere honest to
    /// land. Whether the app is READY to land is a separate question and it is asked
    /// before this is called, through ``AppLinkDestination/requiresWorkspace``.
    ///
    /// - Parameters:
    ///   - destination: what the URL meant.
    ///   - selectedWorkspaceId: the SELECTED workspace, or nil while none has resolved.
    ///   - role: the SELECTED workspace's role, for the one route that carries one. ⛔ It
    ///     reaches that route only when the route's tenant IS the selected workspace; a
    ///     link naming another tenant gets nil. See the ⛔ in the body.
    static func action(
        for destination: AppLinkDestination,
        selectedWorkspaceId: String?,
        role: WorkspaceRole?
    ) -> PushRouteAction {
        // ⚠️ NIL WHENEVER THE LINK NAMED NO TENANT, WITHOUT A SECOND COMPARISON. A link
        // with no `workspaceId` leaves this nil (it equals itself), and one naming the
        // workspace already selected leaves it nil too, so the common case starts no
        // reload. Annotated because the `nil` arm of a ternary has no type of its own.
        let switchTo: String? = destination.workspaceId == selectedWorkspaceId ? nil : destination.workspaceId
        // ⛔ THE LINK'S TENANT WINS OVER THE SELECTED ONE. The switch above is async and
        // the route is appended now; taking the id the LINK named is what makes the
        // destination describe the tenant that was asked for rather than the one still
        // on screen. See the ⛔ on ``PushRouteAction/route``.
        let workspaceId = destination.workspaceId ?? selectedWorkspaceId
        // ⛔ THE ROLE BELONGS TO THE SELECTED WORKSPACE AND MUST NOT TRAVEL ONTO ANOTHER
        // TENANT'S ROUTE. `role` is read off ``WorkspaceSessionModel``, which reports the
        // membership role in the workspace currently on screen; the line above takes the
        // id the LINK named. Pairing the two produced `.scheduling(workspaceId: B, role:
        // <A's role>)` for a link naming a tenant the user was not in, which is a
        // cross-tenant claim whatever the reader does with it. nil is the honest value:
        // the link's tenant may not even be in the loaded list, and inventing a role for
        // it would be a guess wearing the shape of a fact.
        //
        // ⚠️ THE COMMON CASES STILL CARRY IT. A link naming no tenant leaves
        // `workspaceId` equal to `selectedWorkspaceId`, and one naming the workspace
        // already selected does the same, so only a genuine cross-tenant link drops the
        // role. Single-line condition on purpose (see the ⚠️ on `tab(for:)`).
        let scopedRole: WorkspaceRole? = workspaceId == selectedWorkspaceId ? role : nil
        return PushRouteAction(
            tab: tab(for: destination.section),
            selectWorkspaceId: switchTo,
            route: route(for: destination, workspaceId: workspaceId, role: scopedRole)
        )
    }

    /// The tab that HOSTS a section.
    ///
    /// ⚠️ ANALYTICS AND SCHEDULING ARE NOT TABS AND HANG OFF THE OVERVIEW, which is
    /// where ``OverviewEntry`` already offers both. Putting them anywhere else would
    /// give the app a second way to reach a screen the overview already owns, and a
    /// back swipe from one of them would land somewhere the user never chose.
    ///
    /// ⛔ DEVICES HANGS OFF `account`, NOT OFF A WORKSPACE TAB. It is account-scoped
    /// (none of the three routes behind it takes a `workspaceId` and none could,
    /// because the scope comes from the verified session), and `account` is the one tab
    /// that stays reachable when no workspace resolves at all. See the ⛔ on
    /// ``Tab/account``.
    ///
    /// ⚠️ A SWITCH EXPRESSION HERE WHILE ``route(for:workspaceId:role:)`` BELOW WRITES
    /// ITS `return`s OUT, AND THAT IS THE FORMATTER'S CALL RATHER THAN A STYLE CHOICE.
    /// Every arm of this one is a single expression, so `swiftformat --lint` fails the
    /// build on the explicit keyword (`redundantReturn`); the other function has arms
    /// carrying a guard, so it is a statement switch and the keyword is required. Both
    /// tools have to agree before this file can be committed at all. See the ⛔ on
    /// `trailing_comma` in `.swiftlint.yml` for the same pair disagreeing elsewhere.
    private static func tab(for section: DistrictSection) -> Tab {
        switch section {
        case .overview, .analytics, .scheduling: .overview
        case .inbox: .inbox
        case .calls: .calls
        case .contacts: .contacts
        case .devices: .account
        }
    }

    /// The one destination to push onto that tab's root, if the section is a drill-down.
    ///
    /// ⚠️ EXPLICIT `return` IN EVERY BRANCH RATHER THAN A SWITCH EXPRESSION, for the
    /// reason ``PushRouting`` states: nothing in this repo can compile this file, so the
    /// plainest construct that cannot be wrong about which branch types against what is
    /// the right one here.
    ///
    /// ⚠️ THE `workspaceId` GUARDS ARE DEFENSIVE RATHER THAN LIVE. ``ShellView`` holds a
    /// link whose ``AppLinkDestination/requiresWorkspace`` is true until one resolves,
    /// so nil cannot reach the three arms below today. They return nil rather than
    /// force-unwrapping because "land on the tab root" is a correct answer and a crash
    /// is not, and because a partial function whose impossible arm is wrong is exactly
    /// the shape that becomes a real bug the day the caller changes.
    private static func route(
        for destination: AppLinkDestination,
        workspaceId: String?,
        role: WorkspaceRole?
    ) -> Route? {
        switch destination.section {
        case .overview, .inbox, .contacts:
            // Tab roots. There is nothing under them a URL names today.
            return nil
        case .devices:
            // ⚠️ The one route that needs no workspace at all.
            return .devices
        case .calls:
            // ⚠️ The list is the tab root; only a `calls/<id>` link pushes anything.
            guard let workspaceId, let callId = destination.detailId else { return nil }
            return .callDetail(workspaceId: workspaceId, callId: callId)
        case .analytics:
            guard let workspaceId else { return nil }
            return .analytics(workspaceId: workspaceId)
        case .scheduling:
            // ⛔ THE ROLE REACHING HERE IS ALREADY SCOPED TO THE ROUTE'S OWN TENANT, and
            // it is nil for a cross-tenant link. See the ⛔ in
            // ``action(for:selectedWorkspaceId:role:)``.
            //
            // ⛔ NEVER THE SELECTED WORKSPACE'S ROLE. That would pair one tenant's role
            // with the LINK's `workspaceId`: a latent cross-tenant role, even where
            // ``RouteDestinations`` drops it (the status route answers `canManage`
            // instead).
            //
            // ⚠️ THE VALUE IS STILL LOAD BEARING ON THE ROUTE ITSELF: ``OverviewEntry``
            // passes it to ``RouteGate`` to decide whether to offer the row at all, and
            // the scheduling sections read it to decide whether to draw their writes.
            //
            // ⚠️ THE SECOND SEGMENT NAMES A SECTION, AND AN UNRECOGNISED ONE LANDS ON THE
            // HUB RATHER THAN ON A FAILURE. That is the opposite of the top-level rule —
            // where a section this app cannot draw becomes `openInBrowser` — and it is
            // correct for the opposite reason: the claim is already narrowed to
            // scheduling, so the hub IS the surface the URL named, one level up, with
            // every section one tap away. See the ⛔ on
            // ``SchedulingSection/forPathSegment(_:)``.
            guard let workspaceId else { return nil }
            return .scheduling(
                workspaceId: workspaceId,
                role: role,
                section: SchedulingSection.forPathSegment(destination.detailId)
            )
        }
    }
}

/// One claimed URL this app has no screen for, carried to the browser sheet.
///
/// ⛔ THE CARRIER FOR THE RESOLVER'S THIRD ANSWER, WHICH IS WHY IT SITS BESIDE THE OTHER
/// TWO. The ⛔ at the top of this file records that ``AppLinkOutcome/openInBrowser``
/// never becomes an ``AppLinkDestination`` and so never reaches ``AppLinkRouting``; this
/// is what it becomes instead. ⚠️ It lives here rather than in `ShellView.swift`, which
/// sits against the 500-line ceiling `swiftlint --strict` reports as an error, and it
/// puts all three of a link's outcomes in one file rather than two.
///
/// ⛔ THE `id` IS A FRESH UUID AND NEVER THE URL, for the reason ``SchedulingHandOff``
/// states: identity has to change on every hand-off so that tapping the SAME link twice
/// re-presents the sheet rather than being deduplicated against a URL SwiftUI is still
/// holding a copy of. A user who dismissed the sheet by accident and tapped the link
/// again would otherwise get nothing at all.
///
/// ⚠️ THIS TYPE IS WHY THIS FILE IMPORTS `Foundation` EXPLICITLY. The app's other
/// hand-off type reaches `UUID` and `URL` through what its file imports for its own
/// reasons; this one imports nothing of the kind, and a transitive re-export
/// from SwiftUI is not a promise worth building on.
struct AppLinkHandOff: Identifiable {
    let id = UUID()
    let url: URL
}
