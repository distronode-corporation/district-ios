import Foundation

/// What the shell must do about a push, given what the app currently knows.
///
/// Port of the Android client's `DeepLinkDecision` (in its `PushDeepLinks`),
/// widened to cover the call family as well: on Android the ring is reached
/// through `PushMessageHandler.onIncomingCall` rather than through the
/// deep-link decision, and folding both into one enum is what lets the iOS
/// shell hold a single `switch` over "a push is outstanding, now what".
///
/// ⛔ A VALUE TYPE OVER PURE FUNCTIONS SO THE FIVE CASES ARE TESTABLE ON LINUX.
/// Everything about a notification tap that can be WRONG is a decision over an
/// event and one optional id; none of it needs UserNotifications, a view or a
/// device. What is left in the App target is reading the payload and calling one
/// function, which is the part no test could add value to.
public enum PushDeepLinkDecision: Equatable, Sendable {
    /// Nothing is outstanding, or the selected workspace has not resolved yet.
    ///
    /// ⛔ WAIT RATHER THAN DROP. On a cold start from a notification this is the
    /// state for the whole of the first two reads (`workspace/list` then
    /// `overview`), and dropping here would make the deep link work only when
    /// the app was already open, which is never in the case it exists for.
    case wait

    /// The link is for a workspace that is not the selected one.
    ///
    /// ⛔ DROPPED RATHER THAN SWITCHED, AND THAT IS A DELIBERATE LIMITATION
    /// RATHER THAN A BUG. The selected workspace is explicit client state that
    /// the user chose; a notification silently re-pointing the whole app at
    /// another tenant, mid-task, from a lock screen, is a worse outcome than
    /// landing on the overview. The notification did its job: it said something
    /// arrived. ⚠️ Switching workspace from a deep link is a product decision,
    /// not a gap to fill.
    case drop

    /// Open the workspace's inbox, and the CONVERSATION the message is in.
    ///
    /// ⛔ IT CARRIES THE MESSAGE ID, NOT ONLY THE WORKSPACE. The payload names one
    /// message ROW, and the inbox groups rows into threads server-side, so there is
    /// no client-side way to reach a thread without a request. That request is
    /// `GET /api/district/messages/{id}`, which answers the thread selectors, so the
    /// honest destination is the conversation rather than the list.
    ///
    /// ⛔ THIS CASE STAYS PURE AND MAKES NO REQUEST. Resolution is `ShellView`'s, which
    /// is why the id travels rather than a `Route`: a decision that had to await a
    /// network round trip could not be a total function over an event and an optional
    /// id, and this is the only part of the notification path that Linux can test.
    ///
    /// ⛔ AND THE LIST IS STILL SHOWN FIRST, WHICH IS WHAT MAKES THE RESOLUTION SAFE TO
    /// FAIL. The shell selects the inbox tab and resets it before it asks, so a 404, a
    /// 409, an offline handset or a message a workflow handled degrades to exactly the
    /// inbox list rather than to a blank screen.
    case openMessage(workspaceId: String, messageId: String)

    /// Put the ringing call on screen. ⛔ SHOW, NOT ANSWER: nothing may call
    /// `calls/{id}/answer` until a human presses Answer. See
    /// ``PushEvent/incomingCall(workspaceId:callId:)``.
    case ring(workspaceId: String, callId: String)

    /// Whether acting on this decision consumes the pending event.
    ///
    /// ⛔ TRUE FOR THE ONES THAT NAVIGATE NOWHERE TOO, WHICH IS THE WHOLE POINT.
    /// Kotlin's `PushDeepLinks.clear()` carries the same rule in its own ⛔: a
    /// dropped link that survived would re-fire the moment the user switched to
    /// that workspace for their own reasons, minutes later, and yank them into
    /// the inbox. Only ``wait`` leaves the event pending, because waiting is the
    /// one answer that is expected to be asked again.
    public var consumesPending: Bool {
        self != .wait
    }
}

/// The outstanding push, waiting for a shell that can act on it.
///
/// Port of Kotlin's `PushDeepLinks` holder, as a value type: the App target owns
/// the single mutable copy (`@Observable`), and this stays Linux-testable.
///
/// ⛔ A HOLDER EXISTS BECAUSE THE PUSH ARRIVES **BEFORE** ANYTHING CAN NAVIGATE.
/// It is delivered on launch or from the background, at which point the selected
/// workspace is not known: it comes from `GET /api/district/workspace/list` plus
/// `GET /api/district/overview`, which are in flight. So the shell records the
/// event and consumes it when it has what it needs. Navigating on delivery
/// instead would mean guessing a destination from state that has not loaded.
///
/// ⚠️ ONE PENDING EVENT AT A TIME, LAST ONE WINS. Two notifications tapped in
/// quick succession are one delivery each, and the second is the one the user is
/// looking at. There is no queue because there is no sensible way to honour the
/// first afterwards; it would navigate away from the screen they just asked for.
public struct PushDeepLinks: Equatable, Sendable {
    /// ⚠️ Nil when there is nothing outstanding, which is almost always.
    public private(set) var pending: PushEvent?

    public init(pending: PushEvent? = nil) {
        self.pending = pending
    }

    public mutating func offer(_ event: PushEvent) {
        pending = event
    }

    public mutating func clear() {
        pending = nil
    }

    /// The decision for the currently pending event.
    ///
    /// ⚠️ NON-MUTATING ON PURPOSE. Clearing is the caller's move, gated on
    /// ``PushDeepLinkDecision/consumesPending``, because the shell has to be
    /// able to ask the question on every state change without consuming the
    /// answer it is still waiting to be able to act on.
    public func decision(selectedWorkspaceId: String?) -> PushDeepLinkDecision {
        pushDeepLinkDecision(pending: pending, selectedWorkspaceId: selectedWorkspaceId)
    }
}

/// Resolve a pending push against the selected workspace.
///
/// The iOS counterpart of Kotlin's `inboxDeepLinkDecision`, with the call family
/// folded in.
///
/// - Parameters:
///   - pending: the outstanding event, or nil.
///   - selectedWorkspaceId: the SELECTED workspace, once the overview has
///     resolved one. Nil means "not yet known", never "none".
///
/// ⛔ THE CALL BRANCH IS ANSWERED FIRST AND IS NOT GATED ON THE SELECTED
/// WORKSPACE, WHICH IS THE ONE PLACE THIS DIVERGES FROM THE MESSAGE RULE ABOVE
/// IT. Android reaches the ring from `PushMessageHandler` with no workspace
/// comparison at all, and it has to: the server is holding the caller on a ~25
/// second Redis rendezvous, so waiting for two reads to resolve a workspace, or
/// dropping because the user happens to be looking at another tenant, spends
/// that window and hands the caller to nobody. A ring names its own workspace,
/// and the shell switches to it as part of showing the call.
///
/// ⚠️ THERE IS NO CLIENT-SIDE MEMBERSHIP CHECK HERE, AND ITS ABSENCE IS A
/// FINDING RATHER THAN A GAP. "Is this workspace one the user belongs to" is not
/// answerable offline: the app holds no membership list it could consult without
/// a request. The question is already answered twice by parties that CAN answer
/// it, `sendPushToWorkspace` fanning out only to members' devices and
/// `POST /api/district/calls/{id}/answer` re-checking membership and role
/// against the bearer before it mints anything. A check that could only ever be
/// weaker than those two would trade a real capability for the appearance of one.
public func pushDeepLinkDecision(
    pending: PushEvent?,
    selectedWorkspaceId: String?
) -> PushDeepLinkDecision {
    guard let pending else { return .wait }
    switch pending {
    case let .incomingCall(workspaceId, callId):
        return .ring(workspaceId: workspaceId, callId: callId)
    case let .message(workspaceId, messageId):
        // ⚠️ NOT YET KNOWN, so nothing can be decided. See `.wait`.
        guard let selectedWorkspaceId else { return .wait }
        guard workspaceId == selectedWorkspaceId else { return .drop }
        return .openMessage(workspaceId: workspaceId, messageId: messageId)
    }
}
