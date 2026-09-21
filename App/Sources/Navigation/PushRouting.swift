import DistrictModel

/// What the shell does about a push, once
/// ``pushDeepLinkDecision(pending:selectedWorkspaceId:)`` has said what the push
/// MEANS.
///
/// ⛔ THE TAB'S PATH IS ALWAYS RESET, AND ``route`` IS APPENDED ONTO THE RESET ROOT
/// RATHER THAN REPLACING IT. Landing on a destination while the tab still holds a
/// stack from an earlier session would show the new arrival underneath whatever the
/// user was last reading, so the reset is part of arriving rather than a knob. A
/// drill-down then sits on top of its own tab root, which is what makes a back swipe
/// land somewhere useful instead of dismissing the app.
///
/// ⚠️ ``route`` IS NIL FOR EVERY PUSH. The payload carries a `messageId`, not a
/// conversation id; `GET /api/district/messages/{id}` resolves one, so a message push
/// DOES end in a thread, but it cannot end in one HERE: this is a pure function and the
/// resolve is a request. ``ShellView`` appends the thread afterwards, onto the root this
/// action resets. The field exists for Universal Links (``AppLinkRouting``), where
/// `/dashboard/district/calls/<id>` genuinely names a drill-down synchronously.
/// Sharing one action type is what keeps ``ShellView/apply(_:)`` the ONE way anything
/// moves a tab.
///
/// ⚠️ NIL IS A REAL ANSWER AND IT IS THE COMMON ONE. ``PushDeepLinkDecision/wait``
/// and ``PushDeepLinkDecision/drop`` both navigate nowhere; the difference between
/// them is whether the event stays pending, which belongs to ``PushDeepLinks`` and
/// not here.
struct PushRouteAction: Equatable, Sendable {
    /// The tab to select. Its stack is reset to the tab root; see the ⛔ on the type.
    ///
    /// ⚠️ A ROUTE THAT BELONGS TO A HUB SECTION OVERRIDES IT: the hub is selected and the
    /// route lands on that hub's root rather than on this tab's. Every such route is
    /// paired with `.overview` today, which is where the hubs live on compact width, so
    /// the override moves nothing on a phone but the back stack. See
    /// ``ShellPaths/apply(_:)``.
    let tab: Tab

    /// The workspace to switch to first, or nil when the selection already matches.
    ///
    /// ⛔ FOR A PUSH, ONLY EVER SET FOR A RING. A message decision reaches
    /// ``openMessage`` only when the workspaces already agree (``pushDeepLinkDecision``
    /// answers ``PushDeepLinkDecision/drop`` otherwise, deliberately: a notification
    /// silently re-pointing the whole app at another tenant, mid-task, is the worse
    /// outcome). A ring is the documented exception, because the server is holding
    /// the caller on a ~25 second rendezvous and dropping spends that window.
    /// ⚠️ A LINK IS A THIRD CASE AND IT MAY ALWAYS SWITCH, because someone tapped a
    /// URL that names the tenant; see ``AppLinkDestination/workspaceId``.
    let selectWorkspaceId: String?

    /// The single destination to push onto the freshly reset tab root, if any.
    ///
    /// ⛔ SELF-DESCRIBING, WHICH IS WHY IT MAY BE APPENDED BEFORE THE WORKSPACE
    /// SWITCH HAS FINISHED. ``selectWorkspaceId`` starts an async reload; every
    /// workspace-scoped ``Route`` carries its own `workspaceId` in the value (see the
    /// ⛔ at the top of ``Route``), so the destination renders against the tenant the
    /// link named rather than against whatever the session happens to hold while the
    /// reload is in flight.
    let route: Route?

    /// ⚠️ WRITTEN OUT RATHER THAN SYNTHESISED so ``route`` can default to nil. A `let`
    /// carrying a default value is dropped from the memberwise initialiser entirely,
    /// which would make it unsettable rather than optional.
    init(tab: Tab, selectWorkspaceId: String?, route: Route? = nil) {
        self.tab = tab
        self.selectWorkspaceId = selectWorkspaceId
        self.route = route
    }
}

/// The pure half of notification routing: a decision in, a shell action out.
///
/// ⛔ SEPARATED FROM ``ShellView`` SO THE MAPPING IS READABLE WITHOUT A DEVICE.
/// Everything here is a total function over four cases and one optional id, and the
/// decision it consumes is already tested on the Linux tier
/// (`PushDeepLinkTests`). What is left in the view is reading one payload and
/// calling one function, which is the part no test could add value to.
enum PushRouting {
    /// ⚠️ EXPLICIT `return` IN EVERY BRANCH RATHER THAN A SWITCH EXPRESSION: the
    /// plainest construct that cannot be wrong about which branch types against what.
    ///
    /// - Parameters:
    ///   - decision: what the pending push resolved to.
    ///   - selectedWorkspaceId: the SELECTED workspace, or nil while none has
    ///     resolved.
    /// - Returns: the action to apply, or nil when nothing should move.
    static func action(
        for decision: PushDeepLinkDecision,
        selectedWorkspaceId: String?
    ) -> PushRouteAction? {
        switch decision {
        case .wait, .drop:
            // ⚠️ Two different reasons for the same absence of movement. See the ⚠️
            // on ``PushRouteAction``.
            return nil

        case .openMessage:
            // ⚠️ THE WORKSPACE IS NOT CARRIED THROUGH. It is the selected one by
            // construction here, so switching to it would be a no-op that reloads
            // the workspace list for nothing.
            //
            // ⛔ AND NO `route` IS RETURNED, WHICH IS DELIBERATE RATHER THAN A GAP. The
            // thread is not known yet: turning a `messageId` into a destination takes
            // an authenticated request, and this function is pure. ``ShellView``
            // resolves it and appends the thread onto the inbox root this action has
            // just reset — so the LIST is what appears first, and every way the resolve
            // can fail degrades to exactly that rather than to a blank screen.
            return PushRouteAction(tab: .inbox, selectWorkspaceId: nil)

        case let .ring(workspaceId, _):
            // ⛔ SHOW, NEVER ANSWER. The answer path is `POST
            // /api/district/calls/{id}/answer` and it must sit behind a UI press,
            // never behind the arrival of a push: a call answered on the strength
            // of a notification alone hands the caller to nobody, which is worse
            // than the fallback to PSTN the server already does when the rendezvous
            // expires. The incoming-call cover is driven by the call itself, not by
            // this tap, so a tapped ring lands on the call log, which says a call happened.
            // ⚠️ Annotated because the `nil` arm of a ternary has no type of its
            // own to join with.
            let switchTo: String? = workspaceId == selectedWorkspaceId ? nil : workspaceId
            return PushRouteAction(tab: .calls, selectWorkspaceId: switchTo)
        }
    }
}
