import DistrictCall
import DistrictData
import DistrictModel
import Foundation
import Observation

/// The outbound softphone: the keypad, and the one call it may have in flight.
///
/// ⛔ IT PLACES CALLS, WHICH MAKES IT THE ONLY MODEL IN THIS APP WHOSE MISTAKES COST
/// MONEY AND RING A STRANGER'S TELEPHONE. Four properties follow from that and are
/// each enforced here rather than left to care, and they are the same four the Kotlin
/// `DialerViewModel` states:
///
///   1. **Nothing dials without an explicit tap.** No `.task` dials on entry, and
///      there is no retry anywhere at any layer. `POST /api/district/calls/dial`
///      writes the `Call` row and instructs the carrier BEFORE it mints the credential
///      it answers with, so a re-send is a second call to the same person, billed
///      again. ``DialRepository``'s own ⛔ says the property holds by construction
///      today; this is the half of it that lives in a screen.
///   2. **One audio owner at a time**, and a second attempt while a call OR A MEETING
///      ROOM is live is refused rather than queued. Two engines would fight over the
///      device's audio focus. ⚠️ The room half is enforced here; see ``RoomAudio``.
///   3. **The number travels exactly as typed.** Normalisation is the server's and it
///      runs BEFORE the DNC lookup and before the dial, so a client-side canonicaliser
///      that disagreed by one character would place a call the compliance check never
///      saw.
///   4. **The call outlives the screen.** See below.
///
/// ⛔ THE CALL'S LIFETIME IS THE CLAIM ON ``CallStack/onSystemRequest``, AND THAT IS
/// ALSO WHAT KEEPS THIS OBJECT ALIVE. `AppContainer` holds one ``CallStack`` for the
/// process; ``placeCall()`` installs a closure that captures `self` STRONGLY, and
/// ``release()`` clears it on every terminal path. Three things fall out, and all
/// three are the point rather than a side effect:
///
///   * A screen popped mid-call does not end the call. The `CXProvider` still has it,
///     the engine still has its socket, and this model is still reading the engine
///     stream and answering the OS — because the container holds it. A model that died
///     with its view would leave a live microphone the user believes is off.
///   * A SECOND dialer cannot steal the first call's callbacks: ``placeCall()`` refuses
///     while the claim is held, and ``CallKitBridge/onSystemRequest`` is documented as
///     "set by the owner before any call is started, never after".
///   * The strong capture is a REFERENCE CYCLE for exactly the duration of one call,
///     and ``release()`` is the only thing that breaks it. It is reached from a single
///     sink (``settle()``) on every terminal phase, plus every refusal, so a path that
///     forgot it would leak one model per call.
///
/// ⛔ THERE IS NO `deinit`. It could not do the cleanup anyway — a `@MainActor` class's
/// `deinit` is nonisolated under Swift 6 and cannot touch these stored properties — and
/// it does not need to: while a call is live the claim makes deallocation impossible,
/// and when no call is live there is nothing to clean up. Nothing else here escapes
/// this object: both background tasks capture `self` weakly and are cancelled by
/// ``release()``.
///
/// ⛔ NO VIDEO, EVER, AND THE ENFORCEMENT IS AN ABSENCE. ``CallCommand`` has no camera
/// case and ``CallEngine`` has no camera member, so the softphone cannot publish video
/// even by accident. See the ⛔ on ``InCallView``.
///
/// ⚠️ ITS ``LiveCallControls`` CONFORMANCE ADDS NO CODE: the four members have
/// exactly the protocol's signatures, and the protocol exists so ``InCallView`` can
/// serve the inbound call as well. See the ⛔ on that protocol for why the STATE is
/// not shared the same way.
@MainActor
@Observable
final class DialerModel: LiveCallControls {
    /// What the operator typed, verbatim. ⛔ See property 3 on the type.
    private(set) var entry: String = ""

    /// The live call, or nil when the dialer is on the keypad.
    ///
    /// ⛔ HELD HERE RATHER THAN BEING A DESTINATION, WHICH IS A SAFETY DECISION RATHER
    /// THAN A LAYOUT ONE. `Route.dialer` is one destination for both surfaces precisely
    /// so a back stack restored after process death cannot re-run an effect that dials;
    /// see the ⛔ on that case. A killed process comes back to an idle keypad, which is
    /// the truth, because the socket died with it.
    private(set) var call: SoftphoneSession?

    /// Why the last dial did not happen, or nil.
    ///
    /// ⚠️ SHOWN ON THE KEYPAD RATHER THAN OVER A CALL SCREEN, because a refused dial
    /// produced no call and there is nothing to show it over. Cleared the moment the
    /// entry changes: a message about a number the operator has moved on from is worse
    /// than none.
    private(set) var refusal: FailureText?

    /// The recent inbound callers, or why they could not be read.
    ///
    /// ⛔ A FAILED READ MUST NOT DISABLE THE KEYPAD, and the enforcement is
    /// structural rather than careful: ``canPlaceCall`` does not mention this
    /// property and nothing on its path writes ``refusal``. See
    /// ``DialerCallbacksState``.
    private(set) var callbacks: DialerCallbacksState = .loading

    /// True between the tap and the OS accepting the start action.
    ///
    /// ⚠️ ITS OWN FLAG RATHER THAN A PHASE, because ``SoftphonePhase/dialing`` begins
    /// when CallKit reports the action performed. Between the two there is no session
    /// at all, and the button still has to say something.
    private(set) var placing = false

    /// ⛔ `allowsMutation` ON THE OPTIONAL, NOT `role != .viewer`. A role the wire did
    /// not recognise is nil, and `nil != .viewer` is TRUE — so the shorter expression
    /// would hand an unknown role the ability to spend the workspace's minutes. See the
    /// ⛔ on ``RouteGate``.
    let canDial: Bool

    let calls: CallStack

    /// ⚠️ MODULE-VISIBLE, WITH ``workspaceId``, BECAUSE `DialerServerHangUp.swift`
    /// SPENDS BOTH. Immutable `let`s, so neither fails the test `DialerTasks.swift`
    /// applies to ``refusal``: there is no setter to hand a view.
    let dial: DialRepository

    /// ⚠️ `callLog` BECAUSE `calls` ABOVE IS THE LIVE CALL, not the log of past ones.
    private let callLog: CallsRepository
    let workspaceId: String

    /// Why the last carrier hang-up did not go through. ⛔ DIAGNOSIS ONLY, never
    /// user-facing, which is why the SETTER widens where ``refusal``'s did not.
    /// ``CallKitBridge/lastTransactionFailure``'s twin for the far end of a call.
    var lastServerHangUpFailure: String?

    /// The call this model owns, as the OS knows it, or nil between calls.
    private var callUUID: UUID?

    /// The number pinned at the tap. ⛔ See ``placeCall()``.
    private var pendingNumber = ""

    /// True while ``CallStack/onSystemRequest`` belongs to this model. See the ⛔ on
    /// the type.
    private var claimed = false

    /// ⛔ REPORTED ONCE. `reportOutgoingCall(uuid:connectedAt:)` starts the OS's own
    /// duration counter, and reporting it twice restarts it.
    private var connectedReported = false

    /// ⛔ "you hung up" IS A CLAIM ABOUT A PERSON AND THE REDUCER CANNOT MAKE IT.
    /// ``SoftphoneEvent/hangUpPressed`` is fed by ``hangUp()`` AND by a
    /// `CXEndCallAction` the OS performed, so ``CallEndReason/hungUpLocally`` means
    /// "ended on this device" and nothing narrower. This is the one bit that
    /// separates them, written on exactly one path, and cleared at the next tap
    /// rather than in ``release()`` because the summary is drawn AFTER teardown.
    private(set) var endedByOperator = false

    // ⚠️ MODULE-VISIBLE RATHER THAN `private`, ALONG WITH ``calls``, ``apply(_:)`` AND
    // ``abandonStart(uuid:)``, BECAUSE THE THREE TASKS THAT WRITE THEM LIVE IN
    // `DialerTasks.swift` AND SWIFT'S `private` IS FILE-SCOPED. That file says which
    // members widened and why; it is a `file_length` consequence, not an invitation.
    var engineTask: Task<Void, Never>?
    var tickTask: Task<Void, Never>?
    var startTask: Task<Void, Never>?

    init(container: AppContainer, workspaceId: String, role: WorkspaceRole?) {
        calls = container.callStack
        dial = container.dial
        callLog = container.calls
        self.workspaceId = workspaceId
        canDial = WorkspaceRole.allowsMutation(role)
    }

    // MARK: - What the keypad may do

    /// ⚠️ CLEARS THE PREVIOUS REFUSAL, because it was about a different number.
    func onEntryChange(_ value: String) {
        entry = value
        refusal = nil
    }

    /// Read the recent inbound calls the operator might return. ⚠️ IDEMPOTENT AND
    /// SAFE TO REPLAY, unlike everything else here, because it is a GET and dials
    /// nothing.
    func loadCallbacks() async {
        switch await callLog.recentCallbacks(workspaceId: workspaceId) {
        case let .success(rows):
            callbacks = .ready(rows)
        case let .failure(error):
            // ⛔ A FAILURE, NEVER AN EMPTY LIST. "We could not look" and "nobody
            // has called in" are different answers, and the second is a state this
            // list reaches legitimately.
            callbacks = .failed(FailureText.from(error))
        }
    }

    // MARK: - Placing one call

    /// The operator pressed Call.
    ///
    /// ⛔ IT ASKS THE MICROPHONE, THEN THE OS, AND STOPS. The dial goes out in ``beginDial(uuid:)``,
    /// which runs only when CallKit reports the start action PERFORMED, so the system
    /// knows about the call before the carrier does — that ordering is what puts the
    /// call on the lock screen, in Recents and under a headset button, and what stops
    /// the OS ringing an incoming call over one in progress.
    ///
    /// ⚠️ A REFUSED START ENDS THE ATTEMPT AS SOON AS iOS SAYS SO, and a watchdog covers one it never
    /// answers. See ``abandonStart(uuid:because:)`` and ``startAfterMicrophone(uuid:handle:)``.
    func placeCall() {
        guard canPlaceCall else { return }
        // ⛔ THE PROCESS HOLDS ONE CALL. See property 2 on the type. This also covers
        // an inbound call already owning the bridge.
        guard !calls.hasLiveCall else {
            refusal = Self.busy
            return
        }
        // ⛔ AND ONE AUDIO OWNER, WHICH IS A WIDER STATEMENT THAN THE LINE ABOVE. A
        // meeting room is not a telephone call and never reaches ``CallKitBridge``, so
        // the guard above cannot see one; dialling from inside a live room would put
        // ``LiveKitCallEngine`` and ``RoomEngine`` on one `AVAudioSession` with opposite
        // requirements, and would put the meeting on the call and the call in the meeting.
        //
        // ⛔ REFUSED RATHER THAN YIELDED, WHICH IS THE OPPOSITE OF WHAT AN INBOUND CALL
        // DOES, AND THE ASYMMETRY IS THE DECISION. This is a deliberate press by an
        // operator who is right here and can be told a sentence; an inbound call is
        // revenue arriving from somebody who cannot be told anything, so that one wins
        // and the room is left explicitly. See the ⛔ on ``RoomAudioYield/telephoneCall``.
        guard !calls.hasLiveRoom else {
            refusal = Self.inRoom
            return
        }
        refusal = nil
        placing = true
        // ⚠️ CLEARED HERE, NOT IN ``release()``. See the ⛔ on the property.
        endedByOperator = false
        // ⛔ THE NUMBER IS PINNED AT THE TAP, NOT READ AGAIN AT DIAL TIME. The keypad is
        // still on screen between the tap and CallKit performing the start action, so a
        // field read in ``beginDial(uuid:)`` could dial a DIFFERENT number from the one
        // the OS was handed — the call log, Recents and the invoice would then disagree
        // with each other about who was called. The field is disabled while `placing`
        // for the same reason; this is the half that does not depend on a view.
        pendingNumber = entry
        let uuid = UUID()
        callUUID = uuid
        claimed = true
        // ⚠️ AND FINDABLE: a dial screen rebuilt around this call re-attaches to this
        // model through ``CallStack/softphone`` (weak; the claim below keeps it alive).
        calls.softphone = self
        // ⛔ ARMED BEFORE THE TRANSACTION, NEVER AFTER. `CXProvider` can perform an
        // action before the method that asked for it returns, so a handler installed
        // afterwards leaves a window in which a hang-up from the OS reaches nothing.
        // ⚠️ The capture is STRONG on purpose; see the ⛔ on the type.
        //
        // ⛔ `assumeIsolated` RATHER THAN A HOP, AND IT IS SOUND FOR THE SAME REASON
        // ``CallKitBridge``'S OWN CALLBACKS USE IT. That type sets its provider's
        // delegate queue to nil, which `CXProvider.setDelegate` documents as the main
        // queue, and it invokes this closure from INSIDE its own `assumeIsolated`
        // block — so this is already on the main actor. The property's type carries no
        // isolation, so without this the body cannot call a main-actor method at all.
        // ⚠️ A `Task { @MainActor in … }` here would compile and would be WORSE: it
        // would defer a hang-up by a hop, and CallKit's end action is the one request
        // whose ordering against the reducer matters.
        calls.onSystemRequest = { [self] request in
            MainActor.assumeIsolated {
                system(request)
            }
        }
        // ⛔ THE MICROPHONE FIRST, THEN THE OS. See ``startAfterMicrophone(uuid:handle:)``.
        Task { await startAfterMicrophone(uuid: uuid, handle: pendingNumber) }
    }

    /// End the call this model owns.
    ///
    /// ⛔ THE OS IS TOLD FIRST, AND ONLY THEN THE REDUCER.
    /// ``CallKitBridge/requestEndCall(uuid:)`` disarms itself before issuing the
    /// action, so the `CXEndCallAction` it produces does NOT come back through
    /// ``system(_:)`` — this method is the whole of the local teardown.
    ///
    /// ⚠️ IDEMPOTENT. A second press finds no `callUUID`; and even if one arrived,
    /// ``SoftphonePhase/ended(_:)`` is terminal and absorbs it, so the disconnect is
    /// emitted exactly once.
    func hangUp() async {
        guard let uuid = callUUID else { return }
        // ⛔ THE ONLY PLACE THIS IS SET. See the ⛔ on the property.
        endedByOperator = true
        calls.callKit.requestEndCall(uuid: uuid)
        await apply(.hangUpPressed)
    }

    /// ⛔ THROUGH CALLKIT, NEVER STRAIGHT TO THE ENGINE, so the system's own call UI
    /// and this screen cannot disagree about the microphone. The action comes back as
    /// ``CallKitRequest/muteRequested(uuid:muted:)`` and is applied there, which keeps
    /// ONE path to the microphone whichever surface was pressed.
    func toggleMute() {
        guard let uuid = callUUID, let session = call else { return }
        calls.callKit.requestMuted(uuid: uuid, muted: session.state.media.microphoneEnabled)
    }

    /// ⚠️ NOT THROUGH CALLKIT: there is no system action for the audio route, so this
    /// is the app's own ask and ``CallMediaState/speakerRequested`` records it as one.
    func toggleSpeaker() async {
        await apply(.speakerToggled)
    }

    /// Dismiss the ended-call summary and return to the keypad.
    ///
    /// ⚠️ THE ENDED CALL IS A SCREEN, NOT AN IMMEDIATE POP. The operator needs to see
    /// the duration and be told the record is the call log; a surface that vanished on
    /// hang-up would answer "how long was that" with nothing.
    func dismissEndedCall() {
        guard let session = call, case .ended = session.state.phase else { return }
        call = nil
    }

    // MARK: - What the system asks for

    /// ⛔ EVERY CASE ORIGINATES OUTSIDE THIS APP — a car head unit, a headset button,
    /// the lock-screen banner, Recents. A request that did not reach the reducer would
    /// leave the OS believing one thing and the media doing another.
    private func system(_ request: CallKitRequest) {
        switch request {
        case let .dialRequested(uuid):
            guard uuid == callUUID else { return }
            Task { await beginDial(uuid: uuid) }
        case let .endRequested(uuid):
            guard uuid == callUUID else { return }
            Task { await apply(.hangUpPressed) }
        case let .muteRequested(uuid, muted):
            guard uuid == callUUID else { return }
            Task { await mute(desiredMuted: muted) }
        // ⚠️ INBOUND, AND NEVER THIS SCREEN'S. ``IncomingCallModel`` owns the answer;
        // a dialer that acted on one would answer a call it has no state for.
        case .answerRequested:
            break
        // ⛔ NOT SCOPED TO A UUID, DELIBERATELY. The provider tore its calls down
        // without asking, so there is nothing left to report against and the only
        // correct move is to end ours.
        case .reset:
            Task { await apply(.hangUpPressed) }
        }
    }

    /// The OS performed the start action: place the dial.
    private func beginDial(uuid: UUID) async {
        startTask?.cancel()
        startTask = nil
        guard call == nil, callUUID == uuid else { return }
        placing = false
        call = SoftphoneSession(number: pendingNumber)
        await apply(.dialRequested)
        // ⛔ THE NUMBER AS TYPED. See property 3 on the type.
        let outcome = await dial.dial(workspaceId: workspaceId, to: pendingNumber)
        // ⛔ THE CALL CAN END WHILE THE DIAL IS IN FLIGHT. Measured: the
        // `CXEndCallAction` arrived about a second after the start and this round trip
        // returned 1.7s after that, so `accept` reported "started connecting" AFTER
        // the end and built an engine ``release()`` had stopped watching.
        // `callUUID` is nil on every terminal path.
        //
        // ⛔ AND THE ANSWER IS NOT DROPPED, BECAUSE THAT IS WHERE THE MONEY GOES.
        // "``SoftphonePhase/ended(_:)`` absorbs `dialAccepted`" is true of the local
        // machine and false of the carrier: the body carries the `callId` and the
        // server has ALREADY dialled a telephone. See ``abandonPlacedCall(_:)``.
        guard callUUID == uuid else {
            await abandonPlacedCall(outcome)
            return
        }
        switch outcome {
        case let .success(outcome):
            await accept(outcome, uuid: uuid)
        case let .failure(error):
            await refuse(FailureText.from(error))
        }
    }

    /// ⛔ THE THREE REFUSALS CARRY THE SERVER'S OWN SENTENCE. Their remedies differ —
    /// "ask the person you called to opt back in", "pay on the website", "ask us to
    /// turn this workspace back on" — and the dormancy message is the only place the
    /// 100-day window and the reactivation instruction are stated at all. A client that
    /// paraphrased would tell the operator something the server did not say. See the ⛔
    /// on ``DialOutcome``.
    private func accept(_ outcome: DialOutcome, uuid: UUID) async {
        switch outcome {
        case let .placed(response):
            // ⚠️ THE OS'S OWN "connecting", WHICH IS NOT CONNECTED. It is the CallKit
            // half of ``SoftphonePhase/connecting``.
            calls.callKit.reportOutgoingCall(uuid: uuid, startedConnectingAt: Date())
            // ⛔ BEFORE THE EVENT, because the reducer answers `.dialAccepted` with
            // ``CallCommand/connect(url:token:)`` and ``CallStack/perform(_:)`` drops a
            // command that arrives with no engine.
            await startEngine()
            await apply(.dialAccepted(response))
        case let .doNotCall(message):
            await refuse(Self.refusalText(message, fallback: Self.doNotCallFallback))
        case let .subscriptionInactive(message):
            await refuse(Self.refusalText(message, fallback: Self.subscriptionFallback))
        case let .workspaceDormant(message):
            await refuse(Self.refusalText(message, fallback: Self.dormantFallback))
        }
    }

    /// ⛔ THE REDUCER IS TOLD BEFORE THE STATE IS CLEARED, so the session ends in a
    /// phase that matches what happened, and then the call is dropped because NOTHING
    /// WAS PLACED. Leaving a call screen up would draw a call that does not exist, on
    /// the one surface where "is there a call happening" has to be answerable at a
    /// glance.
    private func refuse(_ text: FailureText) async {
        await apply(.dialRefused)
        call = nil
        refusal = text
        await release()
    }

    /// ⛔ AN ABSOLUTE REQUEST MEETS A TOGGLE EVENT, so it is applied only when the two
    /// disagree. ``SoftphoneEvent/muteToggled`` flips; the system's action carries the
    /// state it wants. Feeding it unconditionally would double-flip whenever the OS and
    /// this app already agreed.
    private func mute(desiredMuted: Bool) async {
        guard let session = call else { return }
        guard session.state.media.microphoneEnabled == desiredMuted else { return }
        await apply(.muteToggled)
    }

    // MARK: - The one sink

    /// Apply one event, perform what it asked for, then settle.
    ///
    /// ⛔ EVERY EVENT GOES THROUGH HERE, WHICH IS WHAT MAKES ``release()`` TOTAL. The
    /// commands are performed IN ORDER and sequentially, because the order is part of
    /// ``SoftphoneCommand``'s contract.
    func apply(_ event: SoftphoneEvent) async {
        guard var session = call else { return }
        let commands = session.handle(event)
        // ⚠️ WRITTEN BACK BEFORE THE AWAIT, so an event that interleaves reads the new
        // state rather than resurrecting the old one.
        call = session
        await perform(commands)
        await settle()
    }

    /// Tell the OS the call is over.
    ///
    /// ⛔ THERE IS NO "DID THIS APP ASK FOR IT" FLAG HERE, AND THAT IS NOT AN OVERSIGHT
    /// EVEN THOUGH ``IncomingCallModel`` HAS ONE. The reducer already made that
    /// decision: ``SoftphoneCommand/reportCallEnded`` is emitted on exactly the endings
    /// CallKit did not perform itself, so a flag would be a second copy of the answer
    /// on the one tier that has no tests. See the ⛔ on ``SoftphoneCommand``.
    ///
    /// ⚠️ IT RUNS BEFORE ``release()``, WHICH IS WHAT MAKES `callUUID` NON-NIL. The
    /// commands are performed inside ``apply(_:)`` and the teardown happens in
    /// ``settle()`` afterwards; moving either would silently drop every report.
    /// ⚠️ MODULE-VISIBLE: ``perform(_:)`` moved to `DialerServerHangUp.swift`.
    func reportEnded() {
        guard let uuid = callUUID, let session = call else { return }
        calls.callKit.reportCallEnded(uuid: uuid, reason: DialerModel.endedReason(for: session.state.phase))
    }

    /// React to the phase the reducer has just reached.
    private func settle() async {
        guard let session = call else { return }
        switch session.state.phase {
        case .connected:
            reportConnected()
            startTicking()
        case .ended:
            await release()
        case .idle, .dialing, .connecting, .ringing:
            break
        }
    }

    /// ⛔ THIS IS WHAT THE OS BILLS AGAINST, so it is reported at the ANSWER and never
    /// at the press or at the dial. The platform bills answered time; reporting early
    /// overstates every call by its ring duration on the one surface the user can
    /// compare against an invoice.
    private func reportConnected() {
        guard !connectedReported, let uuid = callUUID else { return }
        connectedReported = true
        calls.callKit.reportOutgoingCall(uuid: uuid, connectedAt: Date())
    }

    /// ⛔ THE ONE EXIT, AND IT DROPS THE CLAIM LAST. Clearing
    /// ``CallStack/onSystemRequest`` releases the container's only strong reference to
    /// this object, so nothing below that line may touch `self`.
    ///
    /// ⚠️ SAFE TO CALL WITH NOTHING CLAIMED: the tasks are nil and the guard returns.
    private func release() async {
        engineTask?.cancel()
        engineTask = nil
        tickTask?.cancel()
        tickTask = nil
        startTask?.cancel()
        startTask = nil
        placing = false
        connectedReported = false
        guard claimed else { return }
        claimed = false
        callUUID = nil
        calls.onSystemRequest = nil
        calls.endCall()
    }

    // MARK: - The start that never came back

    func abandonStart(uuid: UUID, because text: FailureText? = nil) async {
        guard callUUID == uuid, call == nil else { return }
        // ⚠️ BELT AND BRACES. If the action was in fact performed and merely arrived
        // late, this ends the call the OS is holding; if it was refused, the end
        // transaction is refused too and recorded the same way.
        calls.callKit.requestEndCall(uuid: uuid)
        refusal = text ?? Self.notStarted
        await release()
    }
}
