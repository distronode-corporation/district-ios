import AVFoundation
import CallKit
import Foundation

/// Something the SYSTEM asked for, on a surface this app does not draw.
///
/// ⛔ EVERY CASE ORIGINATES OUTSIDE THE APP, AND THAT IS THE WHOLE REASON THIS TYPE
/// EXISTS. A car head unit, a headset button, the lock-screen call banner and the
/// Recents list can all start, answer, mute or end a call, and none of them goes
/// through the in-app buttons. A request that did not reach the state machine would
/// leave the OS believing one thing and the media doing another: a connection the
/// system says is ACTIVE that this app never joined is silence for the person on the
/// line, and a hang-up the app never heard is a live microphone the user believes is
/// off. The Kotlin client makes the identical point on `DistrictConnection`.
///
/// ⚠️ FILE SCOPE RATHER THAN NESTED IN ``CallKitBridge``, following
/// `DistrictButtonVariant`: a helper nested inside a type that conforms to a protocol
/// with associated types can be silently picked up as the witness.
enum CallKitRequest: Sendable, Equatable {
    /// The OS accepted a `CXStartCallAction`. ⚠️ Drives ``SoftphoneEvent/dialRequested``.
    case dialRequested(uuid: UUID)

    /// The OS answered a ringing call. ⚠️ Drives ``IncomingCallEvent/answerPressed``.
    case answerRequested(uuid: UUID)

    /// The OS ended or refused the call.
    case endRequested(uuid: UUID)

    /// The OS's own mute control moved. ⛔ Note the polarity matches
    /// ``CallCommand/setMuted(_:)``: `muted == true` means silence.
    case muteRequested(uuid: UUID, muted: Bool)

    /// The provider reset. ⛔ Everything is gone and nothing may be reported against
    /// the old call again.
    case reset
}

/// What this app tells iOS about the call it is on, and what iOS tells it back.
///
/// ⛔ A RECORDER IN ONE DIRECTION AND A COURIER IN THE OTHER, EXACTLY LIKE THE ANDROID
/// `DistrictConnection`. The state machines in `DistrictCall` decide; this reports
/// their decisions to `CXProvider` and carries the system's own requests back through
/// ``onSystemRequest``. The inverse arrangement — CallKit callbacks mutating app state
/// directly — produces two state machines that can disagree about whether a call is
/// live, and the losing one is still holding the microphone.
///
/// ⛔ NO UI, NO HTTP AND NO LIVEKIT TYPE IN THIS FILE. The media engine is reached only
/// through ``CallEngine``, which this type does not import: CallKit and LiveKit both
/// want to own `AVAudioSession`, and keeping them in separate files with one
/// ``AudioSessionCoordinator`` between them is what makes the single owner visible.
///
/// ⛔ `@MainActor` WITH THE PROVIDER'S DELEGATE QUEUE SET TO nil. `CXProvider.setDelegate`
/// documents a nil queue as the main queue, so every callback below genuinely arrives
/// on the main actor. ⚠️ They are still declared `nonisolated` and hop with
/// `MainActor.assumeIsolated`: `CXProviderDelegate` is not itself annotated in every
/// SDK, and a main-actor method cannot satisfy a nonisolated requirement under Swift 6.
/// The assumption is sound BECAUSE of the nil queue, so the two lines move together.
///
/// ⚠️ NONE OF THIS IS REQUIRED FOR MEDIA TO FLOW. CallKit buys audio focus, the OS
/// knowing not to ring over a call in progress, and the system's own call surfaces. So
/// every failure here is absorbed rather than propagated — losing the call because the
/// OS declined to be told about it would be the worse outcome. The Android bridge
/// swallows `SecurityException` for the same reason.
@MainActor
final class CallKitBridge: NSObject, CXProviderDelegate {
    /// Where a system-originated request goes.
    ///
    /// ⛔ SET BY THE OWNER BEFORE ANY CALL IS STARTED OR REPORTED, NEVER AFTER. The
    /// framework can perform an action before the method that asked for it returns, and
    /// a handler installed afterwards leaves a window in which a hang-up from the OS
    /// reaches nothing at all. The Android `DistrictCallRegistry` arms its handlers
    /// before `placeCall` for exactly this.
    var onSystemRequest: ((CallKitRequest) -> Void)?

    /// The last transaction the OS refused, for diagnosis only. ⛔ Never user-facing.
    private(set) var lastTransactionFailure: String?

    private let provider: CXProvider

    private let controller = CXCallController()

    private let audio: AudioSessionCoordinator

    /// Every call this app currently believes the OS is holding.
    ///
    /// ⛔ A SET RATHER THAN ONE SLOT. A single slot assigned unconditionally by
    /// `reportIncomingCall` lets a second VoIP push arriving during a live call DISOWN
    /// that call: the ring is dropped by the owner's own guard, its end report nils the
    /// field, and `provider(_:perform: CXEndCallAction)` afterwards computes
    /// `isOurs == false` for the call that is still up. The operator's hang-up from the
    /// lock screen, CarPlay or a headset then tears down CallKit's UI and reaches
    /// nothing in the app — a live microphone the user believes is off, which is the
    /// exact failure the ⛔ on ``CallKitRequest`` names — and the claim on the owner's
    /// teardown is never released, so every later dial and ring is refused for the
    /// life of the process.
    ///
    /// ⛔ IT IS NOT A SECOND SIMULTANEOUS CALL, AND `maximumCallGroups = 1` STAYS.
    /// One engine owns the device's audio focus, so one call at a time remains a
    /// product invariant. What a set buys is that two UUIDs can be ALIVE IN THIS TYPE
    /// at once — a push that is about to be refused overlapping a call that is about
    /// to end — and that neither can disown the other while they overlap. CallKit is
    /// inherently a multi-call API and pretending otherwise here is what produced a
    /// wrong answer rather than a refusal.
    ///
    /// ⛔ AN ENTRY IS REMOVED BEFORE THIS APP REQUESTS ITS OWN END, WHICH IS WHAT
    /// STOPS THE LOOP. `requestEndCall` produces a `CXEndCallAction` that comes
    /// straight back through `provider(_:perform:)`; without the removal, the app's
    /// own hang-up would re-enter the owner's teardown from the far side and look
    /// exactly like the OS ending the call. `TelecomBridge.setDisconnected` disarms
    /// first for the same reason.
    private var trackedCalls: Set<UUID> = []

    init(audio: AudioSessionCoordinator) {
        self.audio = audio
        let configuration = CXProviderConfiguration()
        // ⛔ THE SOFTPHONE PUBLISHES NO VIDEO, IN EITHER DIRECTION. Declaring video
        // support would put a camera button on the system call UI that this app cannot
        // honour.
        configuration.supportsVideo = false
        // ⛔ ONE CALL AT A TIME, AND IT IS A PRODUCT INVARIANT RATHER THAN A LIMIT OF
        // THIS TYPE. One engine owns the device's audio focus, so a second call would
        // mean two engines competing for the route — see ``CallEngine``'s own ⛔.
        // ⚠️ IT ALSO MAKES A STALE CALL CATASTROPHIC RATHER THAN UNTIDY. A call the OS
        // still believes in consumes the one group, so every later call is refused in
        // both directions and a business phone stops receiving customers with no error
        // anywhere. That is why every ending is reported — see ``SoftphoneCommand`` and
        // ``IncomingCallCommand/reportCallEnded`` — and why ``trackedCalls`` is a set.
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.phoneNumber]
        // ⚠️ THE CALL APPEARS IN THE SYSTEM'S RECENTS LIST. It is what makes a missed
        // call visible where a person looks for one, and it is a privacy statement
        // worth being deliberate about: the number is the one the operator dialled.
        configuration.includesCallsInRecents = true
        provider = CXProvider(configuration: configuration)
        super.init()
        // ⚠️ nil IS THE MAIN QUEUE. See the ⛔ on the type: it is what makes
        // `MainActor.assumeIsolated` in every callback below sound.
        provider.setDelegate(self, queue: nil)
    }

    // ── Outbound ─────────────────────────────────────────────────────────────────

    /// Ask the OS to start an outgoing call.
    ///
    /// ⚠️ NOTHING IS HANDED BACK TO HOLD, LIKE THE ANDROID `startOutgoing`. The transaction is
    /// asynchronous, and the state machine advances when ``onSystemRequest`` reports the
    /// action performed; the owner dials the carrier only then.
    ///
    /// ⛔ A REFUSAL IS HANDED BACK, THROUGH `onRefused`, BECAUSE NOTHING HAS HAPPENED YET AND THE
    /// OWNER IS WAITING ON THIS ANSWER. The OS reports a start it will not perform (another call
    /// up, a provider that declined, an app it does not entitle to call) in the request's
    /// completion, usually within milliseconds. An owner told nothing would keep its Call button
    /// spinning until its own watchdog gave up, for a question iOS had already answered.
    /// `onRefused` runs on the main actor, at most once.
    func startOutgoingCall(uuid: UUID, handle: String, onRefused: @escaping @MainActor @Sendable () -> Void) {
        trackedCalls.insert(uuid)
        let action = CXStartCallAction(call: uuid, handle: CXHandle(type: .phoneNumber, value: handle))
        action.isVideo = false
        request(CXTransaction(action: action), onRefused: onRefused)
    }

    /// The dial has left and the far end is being reached.
    ///
    /// ⚠️ THE OS'S OWN "connecting" STATE, WHICH IS NOT THE SAME AS CONNECTED. It is the
    /// CallKit half of ``SoftphonePhase/connecting``.
    func reportOutgoingCall(uuid: UUID, startedConnectingAt date: Date) {
        provider.reportOutgoingCall(with: uuid, startedConnectingAt: date)
    }

    /// The callee picked up.
    ///
    /// ⛔ AFTER MEDIA, NEVER AT THE PRESS OR AT THE DIAL. This starts the OS's own
    /// duration counter, and the platform bills answered time; reporting it early
    /// overstates every call by its ring duration on the one surface the user can
    /// compare against an invoice. See ``CallMediaState/elapsedSeconds``.
    func reportOutgoingCall(uuid: UUID, connectedAt date: Date) {
        provider.reportOutgoingCall(with: uuid, connectedAt: date)
    }

    // ── Inbound ──────────────────────────────────────────────────────────────────

    /// Report a ringing call to the OS. The CallKit half of ``IncomingCallCommand/startRinging(workspace:call:)``.
    ///
    /// ⛔ NO HANDLE IS SUPPLIED WHEN THE CALLER IS UNKNOWN, AND AT THE MOMENT OF THE
    /// REPORT THAT IS THE ORDINARY CASE. The ring push carries identifiers only
    /// (deliberately, because a notification is readable by the OS and by any
    /// notification-listener app), so this client does not yet know who is calling.
    /// Inventing a handle (the call id in a `tel:` URI, say) would write a
    /// meaningless string into the system call log, on every device, forever.
    ///
    /// ⚠️ "DOES NOT KNOW" MEANS "DOES NOT KNOW YET". The caller is resolved after
    /// the report, over the authenticated API, and reaches the same call through
    /// ``updateCall(uuid:handle:callerName:)``. What has NOT changed is the push
    /// payload: it carries ids only, and nothing here may wait on the lookup.
    ///
    /// ⚠️ IT THROWS AND THE CALLER MUST NOT TREAT THAT AS LOSING THE CALL. A refusal
    /// here (Do Not Disturb, a cellular call in progress, a blocked number) is the OS
    /// declining to be told; the in-app ring is drawn independently so the call is
    /// still answerable, which is the degraded-first rule ``IncomingCallCommand/startRinging(workspace:call:)``
    /// states.
    ///
    /// ⛔ THE CALL IS TRACKED BEFORE THE REPORT AND UNTRACKED IF THE REPORT THROWS,
    /// AND BOTH HALVES ARE DELIBERATE. Tracking first is not tidiness left over from
    /// the old single slot: `try await` is a SUSPENSION POINT on the main actor, and
    /// `CXProvider`'s delegate queue is nil, so a `CXEndCallAction` for this very call
    /// can be delivered while this method is suspended. Tracking afterwards would
    /// leave that action finding an untracked UUID and dropping the hang-up — the
    /// same defect the set was introduced to close, moved to a narrower window.
    /// Untracking on the throw is the other half: this set is a record of what the OS
    /// is HOLDING, and a call the OS declined to hold does not belong in it. The call
    /// itself survives the refusal (the owner still rings it in-app), and nothing is
    /// lost by forgetting it here, because the OS cannot send an action for a call it
    /// never accepted.
    func reportIncomingCall(uuid: UUID, handle: String? = nil) async throws {
        let update = CXCallUpdate()
        update.hasVideo = false
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        if let handle {
            update.remoteHandle = CXHandle(type: .phoneNumber, value: handle)
        }
        trackedCalls.insert(uuid)
        do {
            try await provider.reportNewIncomingCall(with: uuid, update: update)
        } catch {
            trackedCalls.remove(uuid)
            throw error
        }
    }

    /// Fill in who is calling on a call that has ALREADY been reported.
    ///
    /// ⛔ AN UPDATE, NOT A SECOND REPORT, AND THE ORDER IS THE WHOLE POINT.
    /// ``reportIncomingCall(uuid:handle:)`` runs synchronously with the VoIP push
    /// because Apple terminates an app that does not report one; the identity
    /// arrives afterwards, from a request that may be slow, may fail, and on a
    /// handset that has not been unlocked since booting cannot succeed at all.
    /// `CXProvider.reportCall(with:updated:)` is what lets that second fact reach a
    /// call the first already created, so the ring never waits on the network. The
    /// shape is the sibling of ``reportCallEnded(uuid:reason:)``, which reports
    /// against an already-live call the same way. ``IncomingCallIdentity`` carries
    /// the reasoning for fetching the identity rather than pushing it.
    ///
    /// ⛔ NEVER CALLED FOR A CALL THAT HAS ENDED. Updating a call CallKit has
    /// already torn down is API misuse, and this type cannot tell: ``trackedCalls``
    /// loses an entry on the app's OWN end requests but a report-driven ending races
    /// this. The owner checks its own phase first (see the ring block in
    /// ``IncomingCallModel``).
    ///
    /// ⚠️ AN EMPTY HANDLE IS NOT REPORTED, mirroring the guard in
    /// ``reportIncomingCall(uuid:handle:)``: a `CXHandle` carrying an empty value
    /// is a blank row in the system's own call log rather than an absent one.
    ///
    /// ⚠️ nil FOR EITHER ARGUMENT MEANS "NO CHANGE" RATHER THAN "CLEAR IT", which
    /// is `CXCallUpdate`'s own contract for its optional properties.
    ///
    /// ⛔ THE CAPABILITY FLAGS ARE ABSENT HERE AND ARE STILL BEING ASSERTED. A
    /// fresh `CXCallUpdate` carries `hasVideo` and the four `supports…` flags as
    /// false, which is exactly what ``reportIncomingCall(uuid:handle:)`` set, so
    /// this update leaves them where they were. If that method ever turns one of
    /// them ON, this one has to set it too or the first identity to arrive would
    /// quietly turn it back off mid-call.
    func updateCall(uuid: UUID, handle: String?, callerName: String?) {
        let update = CXCallUpdate()
        if let handle, !handle.isEmpty {
            update.remoteHandle = CXHandle(type: .phoneNumber, value: handle)
        }
        update.localizedCallerName = callerName
        provider.reportCall(with: uuid, updated: update)
    }

    // ── Both directions ──────────────────────────────────────────────────────────

    /// Tell the OS the call is over. The CallKit half of
    /// ``IncomingCallCommand/reportCallEnded`` and of ``SoftphoneCommand/reportCallEnded``.
    ///
    /// ⛔ THIS IS THE REPORT, NOT THE REQUEST, AND THE TWO ARE FOR DIFFERENT ENDINGS.
    /// Use this when the call ended for a reason the user did not press: the far end
    /// hung up, the media failed, the ring timed out. Use ``requestEndCall(uuid:)`` when
    /// the user pressed hang up inside this app. Reporting an ending the user asked for
    /// leaves the OS's own end-call affordance armed against a call that is gone.
    ///
    /// ⚠️ THE OUTBOUND MACHINE MUST CALL THIS TOO, AND ITS ABSENCE IS INVISIBLE. A
    /// `DialerModel` that reached only for ``requestEndCall(uuid:)`` would leave CallKit
    /// believing every finished outbound call was live: the callee hanging up, a refused
    /// dial and a media failure would each leave one behind, and
    /// `maximumCallGroups = 1` would then refuse every later call in both directions.
    ///
    /// ⚠️ IDEMPOTENT BY CONTRACT, and it is issued on every terminal path including ones
    /// where nothing was ever connected.
    func reportCallEnded(uuid: UUID, reason: CXCallEndedReason) {
        provider.reportCall(with: uuid, endedAt: nil, reason: reason)
        trackedCalls.remove(uuid)
    }

    /// The user pressed hang up inside this app.
    func requestEndCall(uuid: UUID) {
        // ⛔ DISARMED FIRST, AND ONLY THIS CALL. See the ⛔ on ``trackedCalls``.
        trackedCalls.remove(uuid)
        request(CXTransaction(action: CXEndCallAction(call: uuid)))
    }

    /// The user pressed mute inside this app.
    ///
    /// ⚠️ SENT THROUGH A TRANSACTION RATHER THAN APPLIED DIRECTLY, so the system's own
    /// call UI agrees with the app's. It comes straight back as
    /// ``CallKitRequest/muteRequested(uuid:muted:)`` and the engine is muted there, which
    /// keeps ONE path to the microphone whichever surface was pressed.
    func requestMuted(uuid: UUID, muted: Bool) {
        request(CXTransaction(action: CXSetMutedCallAction(call: uuid, muted: muted)))
    }

    // ── CXProviderDelegate ───────────────────────────────────────────────────────

    // ⛔ `nonisolated(unsafe) let action = action` IN THE FOUR ACTION HANDLERS IS NOT
    // A SHORTCUT, IT IS THE ONE FORM SWIFT 6 ACCEPTS HERE. `CXCallAction` is not
    // `Sendable`, and passing it into the `MainActor.assumeIsolated` block is a
    // region transfer the compiler refuses ("sending 'action' risks causing data
    // races"). It is sound for the same reason the `assumeIsolated` is: the
    // delegate queue is `nil`, so this method already runs on the main queue and
    // the action never leaves it. Keep the two facts together.

    nonisolated func providerDidReset(_ provider: CXProvider) {
        MainActor.assumeIsolated {
            // ⛔ EVERYTHING IS GONE. The provider has torn down its calls without asking,
            // so the app must release the audio session and end its own call rather than
            // keep reporting against a call the system no longer has.
            trackedCalls.removeAll()
            audio.deactivate()
            onSystemRequest?(.reset)
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        nonisolated(unsafe) let action = action
        MainActor.assumeIsolated {
            // ⛔ CONFIGURE, THEN FULFIL, THEN NOTIFY. Apple's ordering: the category has
            // to be set while the action is being handled, because the system activates
            // the session immediately after the fulfilment.
            audio.configureForCall()
            action.fulfill()
            onSystemRequest?(.dialRequested(uuid: action.callUUID))
        }
    }

    /// ⛔ IT CONFIGURES AND FULFILS EVEN THOUGH THE ANSWER SCREEN LIVES ELSEWHERE, AND IT
    /// NEVER FAILS SILENTLY. An answer action that is neither fulfilled nor failed leaves the
    /// system waiting until it times out the whole call; an answer that is fulfilled
    /// without configuring the session is a call the OS believes is live with no audio
    /// route. ``onSystemRequest`` is where the answer goes, and an owner that has not
    /// set it drops the answer knowingly.
    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        nonisolated(unsafe) let action = action
        MainActor.assumeIsolated {
            audio.configureForCall()
            action.fulfill()
            onSystemRequest?(.answerRequested(uuid: action.callUUID))
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        nonisolated(unsafe) let action = action
        MainActor.assumeIsolated {
            let uuid = action.callUUID
            // ⚠️ FULFILLED WHETHER OR NOT IT IS OURS. The system needs an answer for
            // every action it performs; only the NOTIFICATION is conditional.
            //
            // ⛔ MATCHED AGAINST THE CALL THE ACTION NAMES, NEVER AGAINST WHICHEVER CALL
            // WAS REPORTED LAST. `Set.remove` answers the
            // membership and the removal in one step, which is what makes "ours, and
            // ours exactly once" true even if the OS delivers an end twice.
            let isOurs = trackedCalls.remove(uuid) != nil
            action.fulfill()
            guard isOurs else { return }
            onSystemRequest?(.endRequested(uuid: uuid))
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        nonisolated(unsafe) let action = action
        MainActor.assumeIsolated {
            action.fulfill()
            onSystemRequest?(.muteRequested(uuid: action.callUUID, muted: action.isMuted))
        }
    }

    /// ⛔ THE SYSTEM ACTIVATED THE SESSION; THIS APP NEVER DOES. See the ⛔ on
    /// ``AudioSessionCoordinator``.
    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated { audio.activate(audioSession) }
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated { audio.deactivate() }
    }

    // ── Internals ────────────────────────────────────────────────────────────────

    /// ⚠️ A REFUSED TRANSACTION IS RECORDED, AND RAISED ONLY TO A CALLER THAT ASKS. See the ⚠️ on
    /// the type: for an end or a mute the media flows regardless, and a call lost because the OS
    /// declined to be told about it would be the worse outcome. A refused START is the exception;
    /// see ``startOutgoingCall(uuid:handle:onRefused:)``.
    private func request(_ transaction: CXTransaction, onRefused: (@MainActor @Sendable () -> Void)? = nil) {
        controller.request(transaction) { [weak self] error in
            guard let error else { return }
            let description = String(describing: error)
            Task { @MainActor in
                self?.lastTransactionFailure = description
                onRefused?()
            }
        }
    }
}
