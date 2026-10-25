import DistrictCall
import DistrictData
import DistrictModel
import Foundation

/// Which reducer event an ending that did not come from this app's own Decline button feeds.
///
/// ⛔ ONLY A PERSON MAY FEED ``IncomingCallEvent/declinePressed``. While the call rings it
/// emits ``IncomingCallCommand/requestDecline(workspace:call:)``, which tells the server, and
/// through the agent the caller, that somebody refused the call (Sean, 2026-10-24, GitLab #2
/// note 4083623386). An ending with nobody behind it feeds ``IncomingCallEvent/withdrawnLocally``,
/// which ends the ring the same way and sends nothing.
///
/// ⚠️ ITS OWN TYPE, OUT OF ``IncomingCallModel``, so `DistrictAITests` can run these choices
/// through the real reducer: the model needs CallKit and the container and has no test lane.
enum IncomingCallEnding {
    /// The OS's own end-call action: the lock screen, an Apple Watch, a headset or a car. A
    /// person pressed it, so while the call rings it is that person's decline; once answered it
    /// is a hang-up. ⚠️ A RING IS DECLINED AND A CONVERSATION IS HUNG UP, and the reducer records
    /// a different ``CallEndReason`` for each.
    static func systemEnd(in phase: IncomingCallPhase) -> IncomingCallEvent {
        phase == .ringing ? .declinePressed : .hangUpPressed
    }

    /// The session gate found nobody signed in. ⛔ NOT A DECLINE: nobody saw the call.
    static let noSession: IncomingCallEvent = .withdrawnLocally
}

/// Sends a person's decline, `POST /api/district/calls/{callId}/decline`.
///
/// ⛔ ONCE AND NEVER RETRIED. The reducer emits ``IncomingCallCommand/requestDecline(workspace:call:)``
/// at most once per call, and there is no retry here to reach for: by the time one fired the
/// ring could be over, and the route fails open (the ring then times out as it did before
/// declines were reported).
///
/// ⛔ HELD OPEN BY A BACKGROUND TASK, BEGUN BEFORE THE REQUEST IS SPAWNED. A decline from the
/// lock screen, a watch or a headset often reaches a suspended app, which CallKit wakes only
/// for the end action; without the lease the request would be frozen with it.
///
/// ⛔ AND IT LEAVES THE STEER NOTIFICATION BEHIND (3.2): "You declined the call. Tell the
/// assistant what to say?" (``DeclineSteerNotification``). Posted here because this is the one
/// place only a person's decline reaches; posted at once, not after the answer, because the
/// assistant is taking the call now and an instruction is worth most in its first seconds.
///
/// ⚠️ THE RESULT IS FOR A TEST, NOT A SCREEN. The ring has already ended locally, so no answer
/// changes what the person sees (see `InboundCallRepository.decline`).
@MainActor
final class IncomingCallDeclineSender {
    typealias Send = @Sendable (_ callId: String, _ workspaceId: String) async -> Result<Void, ApiError>

    private let send: Send
    private let backgroundTasks: any BackgroundTaskScheduling
    private let steer: any DeclineSteerPosting

    convenience init(
        inbound: InboundCallRepository,
        backgroundTasks: any BackgroundTaskScheduling = UIKitBackgroundTasks(),
        steer: any DeclineSteerPosting = UserNotificationsDeclineSteerPoster()
    ) {
        self.init(
            send: { await inbound.decline(callId: $0, workspaceId: $1) },
            backgroundTasks: backgroundTasks,
            steer: steer
        )
    }

    init(send: @escaping Send, backgroundTasks: any BackgroundTaskScheduling, steer: any DeclineSteerPosting) {
        self.send = send
        self.backgroundTasks = backgroundTasks
        self.steer = steer
    }

    /// ⚠️ SPAWNED, NOT AWAITED, as the answer is: the model's command loop must not wait on a
    /// round trip, and ``IncomingCallModel``'s teardown cancels nothing this starts.
    @discardableResult
    func decline(workspace: WorkspaceID, call: CallID) -> Task<Result<Void, ApiError>, Never> {
        let lease = BackgroundTaskLease.begin("district.call-decline", on: backgroundTasks)
        steer.post(workspaceId: workspace.rawValue, callId: call.rawValue)
        let send = send
        return Task { @MainActor in
            let outcome = await send(call.rawValue, workspace.rawValue)
            lease.end()
            return outcome
        }
    }
}
