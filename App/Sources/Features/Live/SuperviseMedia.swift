import CallKit
import DistrictCall
import Foundation

/// What a live supervision asks of the device: the one system call, and one engine per leg.
///
/// ⛔ A SEAM SO ``SuperviseModel``'S ORDER IS TESTED WITHOUT CALLKIT OR LIVEKIT. The reducer
/// (`SuperviseSession`, district-core-swift) decides; the model performs its commands in
/// order through this, and `SuperviseModelTests` records what reached it. The one
/// conformance the app ships is ``CallStackSuperviseMedia``.
///
/// ⛔ ONE SYSTEM CALL FOR THE WHOLE SUPERVISION (Sean, 2026-11-05, Q3). Listen starts a
/// CallKit call, so the system holds the audio session, the lock screen shows the call and
/// Recents lists it; a takeover is a second ROOM inside that same call, never a second call,
/// which is what lets it work with the phone locked.
@MainActor
protocol SuperviseMedia: AnyObject {
    /// Whether a phone call or a meeting room already holds this device. ⚠️ Two answers,
    /// because the sentence differs: ``SuperviseCopy/busyWithCall`` or
    /// ``SuperviseCopy/busyInRoom``.
    var hasLiveCall: Bool { get }
    var hasLiveRoom: Bool { get }

    /// The microphone permission. ⛔ Asked before a takeover only: a listener publishes
    /// nothing, so listening needs no permission at all.
    var microphone: any MicrophoneAccess { get }

    /// Take the device's call for `owner`. ⛔ Before the first CallKit transaction, never
    /// after (see ``CallKitBridge/onSystemRequest``), and `handler` is held strongly: it is
    /// what keeps the supervision alive while no screen shows it.
    func claim(_ owner: AnyObject, handler: @escaping (CallKitRequest) -> Void)
    /// Give the claim back. ⛔ Only `owner`'s.
    func release(_ owner: AnyObject)

    /// Ask the OS for the listen-in's call. `onRefused` runs if iOS says no.
    func startCall(uuid: UUID, handle: String, onRefused: @escaping @MainActor @Sendable () -> Void)
    /// The OS performed the start: its "connecting", and the name its call surfaces show.
    func reportConnecting(uuid: UUID, callerName: String)
    /// The person can hear the call: the OS starts its duration counter.
    func reportConnected(uuid: UUID)
    /// The person pressed Stop listening or Hand back inside this app.
    func requestEnd(uuid: UUID)
    /// The supervision ended for a reason CallKit did not perform.
    func reportEnded(uuid: UUID)
    /// The in-app mute control: through CallKit, so the system's own call UI agrees.
    func requestMuted(uuid: UUID, muted: Bool)

    /// Build a fresh engine for one leg and hand back its events. ⛔ The previous leg's
    /// engine is torn down first.
    func beginLeg(_ leg: SuperviseLeg) async -> AsyncStream<CallEngineEvent>
    /// One command for the engine that exists. ⚠️ Dropped when there is none.
    func perform(_ command: CallCommand) async
    /// Drop the engine, if any. ⛔ Not a hang-up; the reducer has already disconnected.
    func endLeg()
}

/// ``SuperviseMedia`` over the process's one ``CallStack``.
///
/// ⛔ THE SAME `CXProvider`, THE SAME ``AudioSessionCoordinator`` AND THE SAME ONE-ENGINE SLOT
/// AS THE DIALLER AND THE ANSWERED CALL. So the overlap rules are the ones those already
/// keep: a supervision holds ``CallStack/hasLiveCall`` while it is up, a dial or a room join
/// is refused during it, and a ring arriving falls back the way it does over any call.
@MainActor
final class CallStackSuperviseMedia: SuperviseMedia {
    private let stack: CallStack

    init(stack: CallStack) {
        self.stack = stack
    }

    var hasLiveCall: Bool {
        stack.hasLiveCall
    }

    var hasLiveRoom: Bool {
        stack.hasLiveRoom
    }

    var microphone: any MicrophoneAccess {
        stack.microphone
    }

    func claim(_ owner: AnyObject, handler: @escaping (CallKitRequest) -> Void) {
        stack.supervisor = owner
        // ⛔ `assumeIsolated` FOR THE REASON ``DialerModel/placeCall()`` GIVES: the bridge calls
        // this from inside its own main-queue callback, and a hop would defer a hang-up.
        stack.onSystemRequest = { request in
            MainActor.assumeIsolated { handler(request) }
        }
    }

    func release(_ owner: AnyObject) {
        guard stack.supervisor === owner else { return }
        stack.supervisor = nil
        stack.onSystemRequest = nil
    }

    func startCall(uuid: UUID, handle: String, onRefused: @escaping @MainActor @Sendable () -> Void) {
        stack.callKit.startOutgoingCall(uuid: uuid, handle: handle, onRefused: onRefused)
    }

    func reportConnecting(uuid: UUID, callerName: String) {
        stack.callKit.reportOutgoingCall(uuid: uuid, startedConnectingAt: Date())
        // ⚠️ THE NAME THE LOCK SCREEN AND RECENTS SHOW: the call log's own label for the caller.
        // ⛔ AFTER THE START WAS PERFORMED, never with the request: an update for a call the
        // OS does not hold yet is dropped.
        stack.callKit.updateCall(uuid: uuid, handle: nil, callerName: callerName)
    }

    func reportConnected(uuid: UUID) {
        stack.callKit.reportOutgoingCall(uuid: uuid, connectedAt: Date())
    }

    func requestEnd(uuid: UUID) {
        stack.callKit.requestEndCall(uuid: uuid)
    }

    func reportEnded(uuid: UUID) {
        // ⚠️ `.remoteEnded` FOR EVERY ENDING CALLKIT DID NOT PERFORM: the call ending, a room
        // that dropped or a refusal. iOS draws nothing different between them for a call
        // that is already on screen, and the Live screen says which it was.
        stack.callKit.reportCallEnded(uuid: uuid, reason: .remoteEnded)
    }

    func requestMuted(uuid: UUID, muted: Bool) {
        stack.callKit.requestMuted(uuid: uuid, muted: muted)
    }

    func beginLeg(_ leg: SuperviseLeg) async -> AsyncStream<CallEngineEvent> {
        await stack.beginCall(publishingMicrophone: leg == .takeover)
    }

    func perform(_ command: CallCommand) async {
        await stack.perform(command)
    }

    func endLeg() {
        stack.endCall()
    }
}
