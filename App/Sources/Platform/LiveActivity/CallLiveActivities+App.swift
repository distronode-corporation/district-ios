import DistrictCall
import DistrictModel
import Foundation

// What the app's screens and models hand ``CallLiveActivities``, translated from their own
// types. Pure where it can be, so `DistrictAITests` pins each rule.

extension CallLiveActivities {
    /// The app's own: ActivityKit, and the session's call repository for the tokens.
    convenience init(container: AppContainer) {
        self.init(host: ActivityKitCallActivityHost(), registrar: container.calls)
    }

    // MARK: - Callers

    /// ⛔ MASKED LIKE THE WATCH, BECAUSE THE ACTIVITY IS ON THE WATCH TOO (the Smart Stack):
    /// a contact's name as is, a bare number as its last four digits. Empty when there is no
    /// caller ID; the extension writes its own "Unknown caller" in the reader's language.
    static func callerName(_ display: CallDisplay) -> String {
        display.displayName.map(WatchMasking.caller) ?? ""
    }

    static func callerName(_ identity: IncomingCallIdentity) -> String {
        identity.name ?? identity.handle.map(WatchMasking.caller) ?? ""
    }

    // MARK: - The open app

    /// A call row the app loaded: in progress starts (or moves on) its activity; over ends it.
    /// Ringing says nothing yet, as for the live transcript.
    func observed(_ call: CallSummary, workspaceId: String) {
        let display = CallDisplay(call)
        if display.transcribesLive {
            seenLive(
                workspaceId: workspaceId,
                callId: call.id,
                callerName: Self.callerName(display),
                startedAt: WireInstant.parse(call.createdAt)
            )
        } else if !display.live {
            ended(callId: call.id)
        }
    }

    /// The watch relay's live list: each call in it is a call the open app saw in progress.
    func observed(_ calls: [WatchLiveCall]) {
        for call in calls {
            seenLive(workspaceId: call.workspaceId, callId: call.id, callerName: call.caller, startedAt: call.startedAt)
        }
    }

    /// A live transcript published: its latest final line, and the end when it ended.
    func observed(_ feed: any WatchLiveTranscriptFeed, callId: String) {
        transcript(callId: callId, lines: feed.lines)
        if case .ended = feed.phase {
            ended(callId: callId)
        }
    }

    // MARK: - The ring

    /// The incoming-call reducer moved: a ring that ended here moves or ends the activity.
    func ring(_ event: IncomingCallEvent, from before: IncomingCallPhase, to state: IncomingCallState) {
        guard let callId = state.callID?.rawValue,
              let outcome = Self.ringOutcome(event, from: before, to: state.phase)
        else { return }
        ringEnded(callId: callId, outcome)
    }

    /// How a ring ended for the activity, from the event and the phases around it; nil when
    /// the event was not the end of a ring on this phone.
    ///
    /// ⛔ ONLY ``IncomingCallEvent/declinePressed`` IS A PERSON'S DECLINE, the rule the
    /// decline request keeps (``IncomingCallEnding``). A withdrawal is nobody signed in, so the
    /// activity goes; a timeout or the server's cancel leaves the call with the assistant.
    nonisolated static func ringOutcome(
        _ event: IncomingCallEvent,
        from before: IncomingCallPhase,
        to after: IncomingCallPhase
    ) -> CallActivityRingOutcome? {
        guard before == .ringing, after != .ringing else { return nil }
        switch after {
        case .answering, .inCall:
            return .answeredHere
        case .ended:
            switch event {
            case .declinePressed: return .declinedHere
            case .withdrawnLocally: return .withdrawn
            default: return .unanswered
            }
        case .idle, .ringing:
            return nil
        }
    }
}
