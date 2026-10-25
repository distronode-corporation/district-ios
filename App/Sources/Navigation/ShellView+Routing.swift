import DistrictData
import DistrictModel
import SwiftUI

/// Everything that MOVES the shell: a tapped notification, a Universal Link, and the
/// one function that applies either.
///
/// ⛔ A SIBLING FILE BECAUSE OF SwiftLint's 500-LINE `file_length`, WHICH `--strict`
/// PROMOTES TO AN ERROR. The same ceiling decides boundaries in `Features/Inbox/Thread/`
/// and in `EndpointTable`; the alternative here would be the message-push resolver with
/// none of the reasoning below, which is the trade this repo does not make.
///
/// ⚠️ WHAT THE SPLIT COSTS, LISTED SO IT CANNOT QUIETLY GROW. Four `@State` properties on
/// ``ShellView`` are internal rather than `private` — `workspaceSession`, `paths`,
/// `deepLinks`, `pendingLink` — because `private` is file-scoped in Swift and every one of
/// them is read or written here. `container`, `push` and `session` are internal `let`s,
/// and App is one module with no second reader.
///
/// ⛔ AND THIS FILE IS STILL INSIDE THE SIGNED-IN GATE. ``RootView`` renders
/// ``ShellView`` only from ``AuthPhase/signedIn``, so nothing here can run for an
/// account that is no longer on this handset — which is genuinely reachable, since the
/// server's `DevicePushToken` row survives a sign-out whose unregister could not be
/// delivered and APNs keeps delivering to a live token regardless. Moving any of it up
/// to ``RootView`` or ``DistrictApp`` would silently delete that gate.
extension ShellView {
    // ── Notification routing ─────────────────────────────────────────────────

    /// Take whatever the registrar is holding and make it the outstanding push.
    ///
    /// ⛔ THE MAILBOX IS EMPTIED ON PICKUP RATHER THAN ON CONSUMPTION, SO THERE IS
    /// NEVER MORE THAN ONE LIVE COPY OF "A PUSH IS OUTSTANDING". Leaving the payload
    /// on the registrar until the decision consumed it would mean two stores of the
    /// same fact and, worse, a swallowed tap: this is driven by `onChange`, which
    /// compares values, so a second tap on an IDENTICAL notification would not
    /// register as a change and would never be routed at all. Whether the event
    /// survives is ``PushDeepLinks``'s question, and it is asked below.
    ///
    /// ⚠️ AN UNPARSEABLE PAYLOAD IS STILL CONSUMED. `PushPayload.parse` answers nil
    /// for a push type this build does not know (forward compatibility, deliberately
    /// silent) and for a missing id; either way there is nothing to act on, and a
    /// payload left in the mailbox would block the next real one.
    ///
    /// ⚠️ INTERNAL RATHER THAN `private`, LIKE THE TWO RESOLVERS BELOW, AND ONLY
    /// BECAUSE THE `onChange` THAT CALLS IT IS IN `ShellView.swift`. `private` is
    /// file-scoped; ``apply(_:)`` at the foot of this file is called only from here and
    /// stays private, which is the line between the two.
    ///
    /// ⛔ A SHADE ACTION NEVER ARRIVES HERE. Reply and Mark read do not navigate, and they
    /// must work on a background launch that has no scene and no loaded workspace, so
    /// ``NotificationPresenter`` hands them to ``NotificationActionHandler`` and only
    /// taps reach the relay this mailbox is fed from.
    func adoptTappedPush() {
        guard let payload = push.pendingTapPayload else { return }
        push.pendingTapPayload = nil
        guard let event = PushPayload.parse(payload) else { return }
        deepLinks.offer(event)
        resolvePendingPush()
    }

    /// Ask what the outstanding push means now, and act if it means anything yet.
    ///
    /// ⛔ CLEARED ON EVERY RESOLUTION EXCEPT ``PushDeepLinkDecision/wait``, INCLUDING
    /// ``PushDeepLinkDecision/drop``. A dropped link that survived would re-fire the
    /// moment the user switched to that workspace for their own reasons, minutes
    /// later, and yank them into the inbox. ``PushDeepLinkDecision/consumesPending``
    /// carries the rule; Kotlin's `PushDeepLinkEffect` states it in its own ⛔.
    ///
    /// ⚠️ CHEAP AND SAFE TO CALL WITH NOTHING PENDING: the decision is `.wait`,
    /// which consumes nothing and moves nothing.
    ///
    /// ⛔ THE TAB MOVE HAPPENS BEFORE THE RESOLVE AND NOT AFTER IT, WHICH IS WHAT MAKES
    /// A FAILED RESOLVE HARMLESS. ``apply(_:)`` selects the inbox and resets it to its
    /// root synchronously; ``resolveMessagePush(workspaceId:messageId:)`` then spends a
    /// request to put the conversation on top. Reversing the two would mean an operator
    /// staring at whatever they were last looking at for the length of a round trip, and
    /// a blank screen when it failed.
    func resolvePendingPush() {
        let selected = workspaceSession.workspaceId
        let decision = deepLinks.decision(selectedWorkspaceId: selected)
        guard decision.consumesPending else { return }
        deepLinks.clear()
        guard let action = PushRouting.action(for: decision, selectedWorkspaceId: selected) else { return }
        apply(action)
        // ⚠️ THE ONLY DECISION WITH A SECOND, ASYNCHRONOUS HALF. Every other case is
        // fully described by its `PushRouteAction`; a message names a row rather than a
        // destination, so the thread has to be fetched. `PushRouting` cannot do it — it
        // is a pure function, deliberately, because it is the part Linux can test.
        if case let .openMessage(workspaceId, messageId) = decision {
            resolveMessagePush(workspaceId: workspaceId, messageId: messageId)
        }
    }

    // ── Universal Links ──────────────────────────────────────────────────────

    /// Act on the outstanding link, if the app knows enough to.
    ///
    /// ⛔ WAIT, NOT DROP, AND THE LINK SURVIVES THE WAIT. Only a destination that
    /// becomes a workspace-scoped ``Route`` needs a tenant; the tabs carry none, so a
    /// link to the inbox moves immediately while a link to `analytics` is held until
    /// ``WorkspaceSessionModel/workspaceId`` resolves and the `onChange` above asks
    /// again. Dropping instead would make Universal Links work only when the app was
    /// already open and loaded, which is never the case they exist for.
    ///
    /// ⛔ CLEARED THE MOMENT IT IS ACTED ON, exactly as ``resolvePendingPush()``
    /// clears a consumed push: a link that survived its own resolution would re-fire
    /// the next time the workspace changed for the user's own reasons and yank them
    /// somewhere they did not ask to go.
    ///
    /// ⚠️ CHEAP AND SAFE TO CALL WITH NOTHING PENDING.
    ///
    /// ⚠️ INTERNAL FOR THE REASON ``adoptTappedPush()`` IS: its two callers are
    /// `onChange` modifiers in `ShellView.swift`, and `private` is file-scoped.
    func resolvePendingLink() {
        resolvePendingCallBack()
        guard let destination = pendingLink else { return }
        let selected = workspaceSession.workspaceId
        guard !destination.requiresWorkspace || selected != nil else { return }
        pendingLink = nil
        apply(AppLinkRouting.action(
            for: destination,
            selectedWorkspaceId: selected,
            role: workspaceSession.role
        ))
    }

    // ── Handoff from the watch ───────────────────────────────────────────────

    /// "Call back" on the watch's call card, picked up on this phone (``CallBackHandoff``).
    ///
    /// ⛔ THE ACTIVITY CARRIES A CALL ID, NEVER A NUMBER: the number is read here, under this
    /// phone's session, by the rule of the dialler's own "Call them back" list, and only fills
    /// the field (``DialerPrefill``). ⚠️ The dialler opens even when no number can be read
    /// (offline, an outbound or withheld call): the person asked for it.
    func continueCallBack(_ activity: NSUserActivity) {
        guard let target = CallBackHandoff.parse(activity.userInfo) else { return }
        container.dialerPrefill.handoff = target
        resolvePendingCallBack()
    }

    /// ⚠️ WAITS FOR THE WORKSPACE LIST, like ``resolvePendingLink()``, and is asked again from
    /// it; a workspace the loaded list does not hold drops the Handoff.
    func resolvePendingCallBack() {
        let prefill = container.dialerPrefill
        guard let target = prefill.handoff, !workspaceSession.workspaces.isEmpty else { return }
        prefill.handoff = nil
        guard let entry = workspaceSession.workspaces.first(where: { $0.id == target.workspaceId }) else { return }
        let switching = workspaceSession.workspaceId == target.workspaceId ? nil : target.workspaceId
        apply(PushRouteAction(
            tab: .overview,
            selectWorkspaceId: switching,
            route: .dialer(workspaceId: target.workspaceId, role: WorkspaceRole.fromWire(entry.role))
        ))
        let calls = container.calls
        Task {
            guard case let .success(row) = await calls.detail(workspaceId: target.workspaceId, callId: target.callId),
                  let number = WatchLiveComposer.callBackNumber(row)
            else { return }
            prefill.offer(number, workspaceId: target.workspaceId)
        }
    }

    // ── Applying an action ───────────────────────────────────────────────────

    /// ⛔ THE ONE PLACE ANYTHING MOVES A TAB, WHICH IS WHY PUSHES AND LINKS SHARE AN
    /// ACTION TYPE. Two movers would be two places for a tab and its stack to
    /// disagree, and the disagreement is invisible until someone taps back.
    ///
    /// ⚠️ WHAT MOVES IS DECIDED BY ``ShellPaths/apply(_:)``, WHICH IS PURE; WHAT STAYS
    /// HERE IS WHAT CANNOT BE. Which item is selected and what lands on its stack is
    /// the same answer for either layout and is tested there; ending the room and
    /// starting the switch are effects on the world, and the reset has to come before
    /// the landing it protects.
    ///
    /// ⚠️ THE WORKSPACE SWITCH IS STARTED FIRST AND NOT WAITED FOR. It re-reads the
    /// workspace list, which puts this view back on ``WorkspaceSessionState/loading``
    /// for the length of a request; the tab selection is `@State` on this view and
    /// survives that, so setting it now means the correct tab is showing the moment
    /// the tabs come back rather than a frame later. The route below is appended for
    /// the same reason and is safe to append early because it carries its own
    /// `workspaceId`; see the ⛔ on ``PushRouteAction/route``.
    ///
    /// ⛔ A WORKSPACE SWITCH ENDS A LIVE ROOM. `selectWorkspaceId`
    /// is non-nil only for a GENUINE switch, and a switch puts this view back on
    /// ``WorkspaceSessionState/loading``, which renders INSTEAD of `tabs` and destroys
    /// the room screen with them — leaving a meeting publishing a microphone and a
    /// camera with no controls anywhere, because ``CallStack`` holds it. A room belongs
    /// to the workspace that minted its token, so ending it is the truthful answer as
    /// well as the safe one. ⚠️ Its own task, not awaited before the select, so the ⚠️
    /// above still holds.
    private func apply(_ action: PushRouteAction) {
        if let workspaceId = action.selectWorkspaceId {
            Task { await container.callStack.endRoom(.workspaceChanged) }
            Task { await workspaceSession.select(workspaceId) }
            // ⛔ EVERY OTHER STACK IS CLEARED HERE AND NOT LEFT TO
            // ``ShellPaths/adopt(_:)``. The line below rebuilds ONE stack; every other
            // tab and hub section would still hold the previous tenant's routes. The
            // stamp this makes is also what tells the `onChange` above that the switch
            // is already accounted for, so without it the route landed below would be
            // cleared again the moment the new list resolved.
            paths.reset(to: workspaceId)
        }
        paths.apply(action)
    }

    // ── Resolving a pushed message into its conversation ─────────────────────

    /// Turn a pushed `messageId` into the thread it names, and push it.
    ///
    /// ⛔ THE LIST IS ALREADY ON SCREEN BY THE TIME THIS RUNS, AND THAT IS THE WHOLE
    /// FALLBACK. ``apply(_:)`` has selected the inbox tab and reset it to its root
    /// before a single request goes out, so every way this can fail — a 404 (the route
    /// answers the same body for "not in this workspace" and "no such message", on
    /// purpose), a 409 (a row whose counterpart does not normalise), an offline handset,
    /// a 403 for a viewer, a message a workflow handled and deleted — degrades to
    /// the inbox list, which is a useful place for a message push to land. ⛔ It is
    /// written that way deliberately rather than left as an accident of ordering: there
    /// is NO failure branch below, because there is nothing better to do than the thing
    /// already done.
    ///
    /// ⛔ AND THE PATH IS RE-READ RATHER THAN CAPTURED. The resolve is a round trip, and
    /// the operator can tap a row, switch tabs or switch tenant while it is in flight;
    /// appending onto a path captured before the await would resurrect a stack that has
    /// since been replaced. The guard is the tenant: if the selected workspace has moved
    /// on, the thread belongs to a tab this notification no longer has any claim over
    /// and is dropped. That is the same reasoning ``PushDeepLinkDecision/drop`` applies
    /// one step earlier.
    ///
    /// ⚠️ IT ALSO REFRESHES THE LIST, THROUGH ``inboxPushSignal``. A push means the
    /// workspace has a message the loaded rows do not, so the list behind the thread has
    /// to be re-read whether or not the resolve succeeds — and on the failure path it is
    /// the only thing that makes the new conversation reachable at all.
    func resolveMessagePush(workspaceId: String, messageId: String) {
        inboxPushSignal += 1
        let repository = container.inbox
        let role = workspaceSession.role
        Task {
            guard case let .success(resolved) = await repository.messageThread(
                workspaceId: workspaceId,
                messageId: messageId
            ) else {
                return
            }
            guard workspaceSession.workspaceId == workspaceId else { return }
            // ⚠️ THE INBOX IS A TAB, SO ITS COMPACT AND REGULAR STACKS ARE ONE STACK and
            // this write lands in either layout. Only the Overview is a projection.
            paths.setCompactPath([
                Route.thread(
                    workspaceId: workspaceId,
                    role: role,
                    threadKey: resolved.threadKey,
                    // ⛔ THE SERVER'S OWN PAIR, AND THE ONLY ONE AVAILABLE HERE. `conversations`
                    // has not been read on this path, so there is no `canSms`/`canEmail` row
                    // to consult — the resolver's `(counterpart, channel)` IS the server's
                    // answer for this thread, and it is the unwrapped address. ⚠️ It is one
                    // target rather than the set, so the composer names the channel instead of
                    // offering it; the full set arrives with the list refresh, on the next
                    // open from a row.
                    replyTargets: [resolved.replyTarget],
                    // ⚠️ NO TITLE. The route's title is the counterpart name the LIST
                    // resolved, and this path has not read the list; the thread screen falls
                    // back to a neutral noun rather than asserting a name nobody supplied.
                    title: nil
                ),
            ], for: .inbox)
        }
    }
}
