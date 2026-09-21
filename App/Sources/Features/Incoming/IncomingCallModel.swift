import DistrictCall
import DistrictData
import DistrictModel
import Foundation
import Observation
import UIKit

/// One inbound call, from the ring to the hang-up.
///
/// ⛔ ONE PER PROCESS, BUILT IN `DistrictApp` BESIDE THE ONE ``AppContainer`` AND
/// THE ONE ``PushRegistrar``, AND IT MUST OUTLIVE EVERY VIEW. A VoIP push can
/// arrive with no window on screen, during a cold launch, or while the user is on
/// a different tab; a model owned by a view would not exist to receive it, and one
/// rebuilt on a redraw would lose the call. ``DialerModel`` gets the same lifetime
/// from a different mechanism (it claims ``CallStack/onSystemRequest`` for the
/// length of one call) and the two must never hold the claim at once, which is
/// what the guard in ``ringing(uuid:workspace:call:)`` enforces.
///
/// ⛔ THE REDUCER IS ``IncomingCallController`` AND EVERY DECISION LIVES THERE,
/// ON THE LINUX-TESTED TIER. This class is the three things that cannot: the
/// clock, the network round trip, and CallKit. A branch added here is a branch
/// with no test on the one target that has no test lane.
///
/// ⛔ BOTH ANSWER PATHS CONVERGE ON ``IncomingCallEvent/answerPressed``, WHICH IS
/// WHAT MAKES "ONE ANSWER PER CALL" TRUE. The on-screen button and the system's
/// own `CXAnswerCallAction` — the lock screen, a car head unit, a headset, a watch
/// — feed the SAME event, and the reducer drops a second one because
/// ``IncomingCallPhase/answering`` absorbs it. Two entry points writing the
/// server's rendezvous twice would tell the agent a human took the call twice.
///
/// ⚠️ THE CALLKIT CALL IS MARKED ACTIVE AT THE PRESS RATHER THAN AT THE MEDIA,
/// AND THAT IS A DIVERGENCE FROM ``IncomingCallCommand/reportCallActive``'S OWN
/// RULE THAT THIS FILE CANNOT FIX. `CXAnswerCallAction` has to be fulfilled
/// promptly or iOS times the whole call out, and ``CallKitBridge`` fulfils it
/// inside the delegate callback; there is no second report for an INCOMING call
/// the way `reportOutgoingCall(uuid:connectedAt:)` exists for an outbound one. So
/// the OS's duration counter starts at the press and this app's own counter starts
/// at the media, and the two differ by one answer round trip. Closing it means
/// holding the action and calling `fulfill(withDateConnected:)`, which is a change
/// to `CallKitBridge` and a risk to every answer.
@MainActor
@Observable
final class IncomingCallModel: LiveCallControls {
    /// ⚠️ MIRRORED OUT OF THE REDUCER RATHER THAN COMPUTED FROM IT, so the
    /// observation dependency is a stored property this class writes.
    private(set) var state = IncomingCallState()

    private(set) var session: IncomingCallSession = .unknown

    /// Who is calling, once the workspace's records answered. See ``IncomingCallIdentity``.
    private(set) var caller: IncomingCallIdentity?

    /// The workspace being called, for a screen that wants to name it.
    var workspaceId: String? {
        state.workspaceID?.rawValue
    }

    /// Whether anything should be on screen. ⚠️ True from the ring all the way
    /// through the ended-call summary, which the user dismisses.
    var isPresented: Bool {
        state.phase != .idle
    }

    // ⚠️ MODULE-VISIBLE RATHER THAN `private`, ALONG WITH ``callUUID``, the three
    // tasks, ``apply(_:)`` and ``nowMilliseconds()``, BECAUSE THE BACKGROUND TASKS
    // THAT DRIVE THEM LIVE IN `IncomingCallTasks.swift` AND SWIFT'S `private` IS
    // FILE-SCOPED. Same trade `DialerModel` already made for `DialerTasks.swift`; it
    // is a `file_length` consequence, not an invitation. ⛔ `state` did NOT widen: its
    // `private(set)` is what stops a view assigning a phase the reducer never
    // produced. Widen nothing else without the same test.
    let calls: CallStack
    private let inbound: InboundCallRepository
    /// ⚠️ The call LOG, not ``calls``, which is the live call. See ``AppContainer/callStack``.
    private let callLog: CallsRepository

    private var controller = IncomingCallController()
    var callUUID: UUID?

    /// True while ``CallStack/onSystemRequest`` belongs to this model.
    private var claimed = false

    /// ⛔ SET BEFORE THIS APP ASKS THE OS TO END A CALL, AND READ BY
    /// ``IncomingCallCommand/reportCallEnded``. `requestEndCall` and
    /// `reportCallEnded` are for different endings — the first is "the user
    /// pressed it here", the second is "it ended for a reason nobody pressed" —
    /// and the reducer emits one command for both. Without this flag a decline
    /// would send the action AND report the call ended, which leaves the OS being
    /// told twice about one ending.
    private var endRequestedLocally = false

    private var answerTask: Task<Void, Never>?
    var engineTask: Task<Void, Never>?
    var tickTask: Task<Void, Never>?
    var timeoutTask: Task<Void, Never>?
    private var identityTask: Task<Void, Never>?

    init(container: AppContainer) {
        calls = container.callStack
        inbound = container.inboundCalls
        callLog = container.calls
    }

    // MARK: - What the push handler hands over

    /// A VoIP push arrived. ⛔ THE CALL IS REPORTED TO CALLKIT BEFORE ANYTHING
    /// ELSE, INCLUDING BEFORE THE PAYLOAD IS READ.
    ///
    /// Apple's rule is absolute: an app that declares the `voip` background mode
    /// and receives a VoIP push without reporting a call is terminated, and
    /// repeated offences stop the pushes being delivered at all. So the report
    /// comes first and every other outcome — a payload this build cannot read, a
    /// call already in progress, a signed-out handset — is expressed by ENDING the
    /// call that was reported rather than by not reporting one.
    ///
    /// ⚠️ A REFUSED REPORT IS NOT A LOST CALL AND IS NOT TREATED AS ONE. The OS
    /// declines (Do Not Disturb, a cellular call in progress) more often than it
    /// fails, and ``CallKitBridge/reportIncomingCall(uuid:handle:)`` says so; the
    /// ring is still driven so a foregrounded app can answer it.
    ///
    /// - Parameter event: what the payload turned out to mean, or nil for anything
    ///   this build cannot act on. ⚠️ PARSED BY THE CALLER because
    ///   ``PushPayload/parse(userInfo:)`` lives in the module that has tests for
    ///   it; see the ⚠️ on `VoIPPushHandler.receive`.
    func incomingPush(uuid: UUID, event: PushEvent?) async {
        try? await calls.callKit.reportIncomingCall(uuid: uuid)
        guard case let .incomingCall(workspaceId, callId)? = event else {
            // ⛔ A PAYLOAD THIS BUILD CANNOT READ STILL COSTS A REPORTED CALL, so
            // it is ended immediately rather than left ringing at nothing. `failed`
            // rather than `unanswered`: nobody missed this, the app could not read
            // it, and a missed-call entry in Recents for a call that was never
            // presented would be a lie.
            calls.callKit.reportCallEnded(uuid: uuid, reason: .failed)
            return
        }
        ringing(uuid: uuid, workspace: WorkspaceID(workspaceId), call: CallID(callId))
    }

    /// The session gate moved. ⛔ A ring that is waiting on ``IncomingCallSession/unknown``
    /// is resolved here, in both directions.
    func sessionChanged(_ phase: AuthPhase) {
        switch phase {
        case .checking:
            session = .unknown
        case .signedIn:
            session = .usable
        // ⚠️ `unavailable` COUNTS AS UNUSABLE. See the ⚠️ on ``IncomingCallSession``.
        case .signedOut, .unavailable:
            session = .unusable
            endForNoSession()
        }
    }

    // MARK: - What the user may do

    /// ⛔ IT FEEDS THE REDUCER RATHER THAN CALLING THE ROUTE. The reducer is what
    /// guarantees exactly one ``IncomingCallCommand/requestAnswer(workspace:call:)``
    /// per call, whichever surface the press came from.
    func answerPressed() {
        Task { await apply(.answerPressed) }
    }

    /// ⛔ NOTHING IS SENT TO THE SERVER FOR A DECLINE. See the ⛔ on
    /// ``IncomingCallController``: a decline and a phone in a pocket must be
    /// indistinguishable from outside, so neither transmits and the server's own
    /// rendezvous timeout does the work.
    func declinePressed() {
        Task { await endLocally(.declinePressed) }
    }

    /// ⛔ "you hung up" IS A CLAIM ABOUT A PERSON AND THE REDUCER CANNOT MAKE IT.
    /// ``IncomingCallEvent/hangUpPressed`` is fed by this method AND by the CallKit
    /// handler in ``system(_:)``, so ``CallEndReason/hungUpLocally`` means "ended on
    /// this device" and nothing narrower. This is the one bit that separates them,
    /// written on exactly one path, and cleared when the next call rings rather than
    /// in ``release()`` because the ended sentence is drawn AFTER teardown.
    ///
    /// ⚠️ THE OUTBOUND SCREEN CARRIES THE IDENTICAL BIT. See
    /// ``DialerModel/endedByOperator``; the two machines are separate, so a fix to the
    /// mislabel on one does not reach the other.
    private(set) var endedByOperator = false

    func hangUp() async {
        // ⛔ THE ONLY PLACE THIS IS SET. See the ⛔ on the property.
        endedByOperator = true
        await endLocally(.hangUpPressed)
    }

    func toggleMute() {
        guard let uuid = callUUID, let media = state.media else { return }
        // ⛔ THROUGH CALLKIT, NEVER STRAIGHT TO THE ENGINE, so the system's own call
        // UI and this screen cannot disagree about the microphone.
        calls.callKit.requestMuted(uuid: uuid, muted: media.microphoneEnabled)
    }

    func toggleSpeaker() async {
        await apply(.speakerToggled)
    }

    func dismissEndedCall() {
        Task { await apply(.dismissed) }
    }

    // MARK: - Starting one ring

    /// ⛔ ONE CALL AT A TIME, AND THE CLAIM IS THE TEST. A second ring while a call
    /// is live is DROPPED rather than queued or allowed to replace: one engine owns
    /// the device's audio focus, and a replacement would tear down a conversation
    /// the user is having in order to ring them about another. The dropped call
    /// still reaches the server's rendezvous timeout and falls back to PSTN, which
    /// is the correct outcome for a person who is already on the phone.
    private func ringing(uuid: UUID, workspace: WorkspaceID, call: CallID) {
        // ⛔ AN ENDED-CALL SUMMARY IS NOT A CALL IN PROGRESS, AND TREATING IT AS ONE
        // WOULD DROP THE MOST LIKELY SECOND RING THERE IS: a caller who was cut off
        // dialling straight back while the previous call's summary is still on
        // screen. ``release()`` has already dropped the claim by then, so the only
        // thing standing in the way is the phase — which the user was going to
        // clear with a button anyway.
        if state.phase.isEnded, calls.onSystemRequest == nil {
            controller.handle(.dismissed)
            state = controller.state
        }
        // ⚠️ CLEARED HERE, NOT IN ``release()``. See the ⛔ on the property: the
        // previous call's ended sentence is drawn after its teardown, so clearing on
        // release would erase the attribution while it was still on screen. A new
        // ring is the first moment the old answer stops being needed.
        endedByOperator = false
        guard state.phase == .idle, calls.onSystemRequest == nil else {
            calls.callKit.reportCallEnded(uuid: uuid, reason: .failed)
            return
        }
        guard session != .unusable else {
            // ⛔ NEVER RING A HANDSET THAT CANNOT ANSWER. The server's
            // `DevicePushToken` row survives a sign-out whose unregister could not
            // be delivered, so this is reachable rather than theoretical.
            calls.callKit.reportCallEnded(uuid: uuid, reason: .unanswered)
            return
        }
        callUUID = uuid
        claimed = true
        endRequestedLocally = false
        // ⛔ ARMED BEFORE ANYTHING ELSE. `CXProvider` can perform an action before
        // the method that asked for it returns, so a handler installed afterwards
        // leaves a window in which a lock-screen answer reaches nothing at all.
        // ⚠️ The capture is STRONG, which is the same lifetime rule ``DialerModel``
        // documents; ``release()`` is what breaks it.
        calls.onSystemRequest = { [self] request in
            MainActor.assumeIsolated {
                system(request)
            }
        }
        Task {
            await apply(.ringing(workspace: workspace, call: call, atMilliseconds: Self.nowMilliseconds()))
            armRingTimeout(uuid: uuid)
        }
        // ⛔ LAST, AND IT MAY NEVER MOVE AHEAD OF THE REPORT OR THE GUARDS ABOVE. ⚠️ The capture is
        // STRONG for the reason the claim above is; ``release()`` cancels it. See ``IncomingCallIdentity``.
        caller = nil
        identityTask = Task { @MainActor [self] in
            let found = await IncomingCallIdentity.lookUp(callLog, workspace: workspace, call: call)
            guard let found, callUUID == uuid, !state.phase.isEnded, state.phase != .idle else { return }
            caller = found
            calls.callKit.updateCall(uuid: uuid, handle: found.handle, callerName: found.name)
        }
    }

    // MARK: - What the system asks for

    /// ⛔ EVERY CASE ORIGINATES OUTSIDE THIS APP. A request that did not reach the
    /// reducer would leave the OS believing one thing and the media doing another:
    /// a connection the system says is active that this app never joined is silence
    /// for the caller.
    private func system(_ request: CallKitRequest) {
        switch request {
        case let .answerRequested(uuid):
            guard uuid == callUUID else { return }
            answerPressed()
        case let .endRequested(uuid):
            guard uuid == callUUID else { return }
            // ⛔ THE OS ALREADY PERFORMED THE END ACTION, so nothing may report the
            // call ended a second time. Same flag, different origin.
            endRequestedLocally = true
            Task { await apply(endEventForCurrentPhase()) }
        case let .muteRequested(uuid, muted):
            guard uuid == callUUID else { return }
            Task { await mute(desiredMuted: muted) }
        // ⚠️ OUTBOUND, AND NEVER THIS MODEL'S. ``DialerModel`` owns the dial.
        case .dialRequested:
            break
        // ⛔ NOT SCOPED TO A UUID, DELIBERATELY. The provider tore its calls down
        // without asking, so there is nothing left to report against.
        case .reset:
            endRequestedLocally = true
            Task { await apply(.hangUpPressed) }
        }
    }

    /// ⚠️ A RING IS DECLINED AND A CONVERSATION IS HUNG UP, and the reducer records
    /// a different ``CallEndReason`` for each. They share a teardown; they are not
    /// the same act.
    private func endEventForCurrentPhase() -> IncomingCallEvent {
        state.phase == .ringing ? .declinePressed : .hangUpPressed
    }

    /// ⛔ THE OS IS TOLD FIRST, AND ONLY THEN THE REDUCER.
    /// ``CallKitBridge/requestEndCall(uuid:)`` disarms itself before issuing the
    /// action, so the `CXEndCallAction` it produces does NOT come back through
    /// ``system(_:)`` and this is the whole of the local teardown.
    private func endLocally(_ event: IncomingCallEvent) async {
        guard let uuid = callUUID else { return }
        endRequestedLocally = true
        calls.callKit.requestEndCall(uuid: uuid)
        await apply(event)
    }

    /// The gate resolved to "there is no session". End a ring that is waiting on it.
    private func endForNoSession() {
        guard callUUID != nil, !state.phase.isEnded, state.phase != .idle else { return }
        Task { await apply(.declinePressed) }
    }

    /// ⛔ AN ABSOLUTE REQUEST MEETS A TOGGLE EVENT, so it is applied only when the
    /// two disagree. Feeding it unconditionally would double-flip whenever the OS
    /// and this app already agreed.
    private func mute(desiredMuted: Bool) async {
        guard let media = state.media else { return }
        guard media.microphoneEnabled == desiredMuted else { return }
        await apply(.muteToggled)
    }

    // MARK: - The one sink

    /// Apply one event, perform what it asked for, then settle.
    ///
    /// ⛔ EVERY EVENT GOES THROUGH HERE, WHICH IS WHAT MAKES ``release()`` TOTAL.
    /// The commands are performed IN ORDER and sequentially, because the order is
    /// part of ``IncomingCallCommand``'s contract.
    func apply(_ event: IncomingCallEvent) async {
        let commands = controller.handle(event)
        // ⚠️ WRITTEN BACK BEFORE THE AWAIT, so an event that interleaves reads the
        // new state rather than resurrecting the old one.
        state = controller.state
        await perform(commands)
        await settle()
    }

    private func perform(_ commands: [IncomingCallCommand]) async {
        for command in commands {
            await perform(command)
        }
    }

    private func perform(_ command: IncomingCallCommand) async {
        switch command {
        // ⚠️ ALREADY DONE, AND DONE EARLIER THAN THIS MODEL EXISTS TO DO IT.
        // ``incomingPush(uuid:userInfo:)`` reports the call to CallKit before it
        // parses the payload, because Apple's rule is about the PUSH rather than
        // about the state machine. ⛔ There is no notification of our own to draw:
        // CallKit's native screen IS the ring on this platform, unlike Android
        // where a heads-up notification is posted beside the Telecom connection.
        case .startRinging:
            break
        // ⚠️ AND NOTHING TO TAKE AWAY, FOR THE SAME REASON. The system call UI is
        // dismissed by the answer action or by the end, both of which are already
        // expressed as other commands.
        case .stopRinging:
            break
        case let .requestAnswer(workspace, call):
            // ⛔ SPAWNED RATHER THAN AWAITED HERE. The round trip ends in another
            // event, so awaiting it inside this command loop would re-enter
            // ``apply(_:)`` while the outer call was still mid-flight and settle
            // the same state twice.
            answerTask = Task { @MainActor [weak self] in
                await self?.requestAnswer(workspace: workspace, call: call)
            }
        case .reportCallActive:
            // ⚠️ NO-OP ON iOS, AND NOT AN OVERSIGHT. See the ⚠️ on the type: the
            // `CXAnswerCallAction` was fulfilled at the press, which is what marks
            // an incoming call active, and there is no second report for one.
            break
        case .reportCallEnded:
            reportEnded()
        case let .engine(engineCommand):
            await calls.perform(engineCommand)
        }
    }

    /// React to the phase the reducer has just reached.
    private func settle() async {
        switch state.phase {
        case .inCall:
            startTicking()
        case .ended:
            await release()
        case .idle, .ringing, .answering:
            break
        }
    }

    /// ⛔ SKIPPED WHEN THIS APP ASKED FOR THE ENDING. See ``endRequestedLocally``.
    private func reportEnded() {
        guard let uuid = callUUID, !endRequestedLocally else { return }
        calls.callKit.reportCallEnded(uuid: uuid, reason: IncomingCallCopy.endedReason(for: state.phase))
    }

    /// ⛔ THE ONE EXIT, AND IT DROPS THE CLAIM LAST. Clearing
    /// ``CallStack/onSystemRequest`` releases the container's only strong reference
    /// to the closure holding this object, so nothing below that line may touch
    /// `self`.
    ///
    /// ⚠️ THE STATE IS NOT RESET HERE. ``IncomingCallPhase/ended(_:)`` is a screen
    /// the user leaves, and ``IncomingCallEvent/dismissed`` is what clears it; a
    /// call that vanished on hang-up would answer "what happened, how long was
    /// that" with nothing.
    private func release() async {
        answerTask?.cancel()
        answerTask = nil
        engineTask?.cancel()
        engineTask = nil
        tickTask?.cancel()
        tickTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        identityTask?.cancel()
        identityTask = nil
        guard claimed else { return }
        claimed = false
        callUUID = nil
        calls.onSystemRequest = nil
        calls.endCall()
    }

    // MARK: - The answer round trip

    /// ⛔ CALLED ONCE PER CALL AND NEVER RETRIED. `calls/answer` writes the Redis
    /// rendezvous the agent's transfer is blocked on, so a second attempt races a
    /// call that is being connected. The reducer guarantees the "once"; this
    /// guarantees the "never retried" by having no retry to reach for.
    private func requestAnswer(workspace: WorkspaceID, call: CallID) async {
        // ⛔ THE MICROPHONE IS ASKED FIRST AND ITS ANSWER GATES NOTHING; see
        // ``prepareMicrophoneForAnswer()``. ⛔ But a call that ended while the alert was up (declined,
        // or the caller gone) must not write the rendezvous afterwards, and ``release()`` cancels this.
        await prepareMicrophoneForAnswer()
        guard !Task.isCancelled else { return }
        let outcome = await inbound.answer(callId: call.rawValue, workspaceId: workspace.rawValue)
        switch outcome {
        case let .success(.joinable(response)):
            // ⛔ BEFORE THE EVENT, because the reducer answers `.answerJoinable` with
            // ``CallCommand/connect(url:token:)`` and ``CallStack/perform(_:)`` drops a
            // command with no engine. ⛔ AWAITED: it also takes the audio off a live room.
            await startEngine()
            await apply(.answerJoinable(url: response.url, token: response.token))
        case .success(.callerGone):
            await apply(.answerRejected(.callerGone))
        case let .success(.refused(message)):
            await apply(.answerRejected(.refused(message: message)))
        // ⚠️ EVERYTHING ELSE IS A REFUSAL WITH THE SHARED SENTENCE — offline, a
        // dead session, a 5xx, contract drift. ``FailureText`` is where every
        // screen's wording for an ``ApiError`` is single-homed, so the ringing
        // screen says what the rest of the app would say about the same fault.
        case let .failure(error):
            await apply(.answerRejected(.refused(message: FailureText.from(error).message)))
        }
    }

    /// ⚠️ THE WALL CLOCK, BECAUSE THE REDUCER'S BOUND IS A TIMESTAMP RATHER THAN A
    /// COUNTDOWN — which is what lets the timeout be tested on Linux with no
    /// sleeping task. See ``IncomingCallState/ringStartedAtMilliseconds``.
    static func nowMilliseconds() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
