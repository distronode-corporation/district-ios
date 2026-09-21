import DistrictModel
import Foundation
import PushKit

/// The PushKit adapter: a VoIP push in, a reported call out.
///
/// ⛔ IT DECIDES ALMOST NOTHING, WHICH IS THE POINT. `App/` is the one tier with
/// no test lane, so the parse lives in ``PushPayload`` (DistrictModel, exercised
/// on Linux) and every rule about what a ring MEANS lives in
/// ``IncomingCallModel`` and the reducer behind it. What is genuinely here is the
/// three things PushKit gives nobody else: the token, the payload, and the
/// completion handler.
///
/// ⛔ A VoIP PUSH THAT DOES NOT REPORT A CALL TERMINATES THE APP. Apple's rule for
/// an app declaring the `voip` background mode is absolute, and repeated offences
/// stop the pushes being delivered at all — so ``IncomingCallModel/incomingPush(uuid:event:)``
/// reports the call BEFORE it looks at what the push said, and every other outcome
/// (a payload this build cannot read, a call already in progress, a signed-out
/// handset) is expressed by ending the call that was reported.
///
/// ⛔ THE PUSHKIT TOKEN IS A SECOND, SEPARATE TOKEN AND NOT A REPLACEMENT FOR THE
/// APNs ONE. `UIApplication.registerForRemoteNotifications()` issues the alert
/// token and this issues the ring token; a VoIP payload sent to the alert token is
/// rejected and an alert sent to this one is not delivered. They are registered
/// against different `kind` rows — see ``PushTokenKind``.
///
/// ⚠️ THE REGISTRY IS CREATED AT LAUNCH BUT THE OWNER ARRIVES WITH THE FIRST
/// RENDER, so a push can land before there is anywhere to send it. That window is
/// tiny (a cold launch builds the scene before the run loop is idle enough to
/// deliver) and it is buffered rather than trusted: ``pending`` holds what arrives
/// early and ``adopt(incoming:)`` drains it. ⛔ Nothing in that window can report a
/// call, because the one `CXProvider` lives on ``AppContainer``; if a device proof
/// ever shows a termination here, the fix is to move the registry's creation to
/// the adoption rather than to widen the buffer.
///
/// ⚠️ `@MainActor` WITH THE REGISTRY'S QUEUE SET TO `.main`, which is what makes
/// `MainActor.assumeIsolated` in each callback sound. The two lines move together.
/// The callbacks are declared `nonisolated` for the reason ``CallKitBridge``'s are:
/// `PKPushRegistryDelegate` is not annotated in every SDK, and a main-actor method
/// cannot satisfy a nonisolated requirement under Swift 6.
@MainActor
final class VoIPPushHandler: NSObject, PKPushRegistryDelegate {
    /// A push that arrived before an owner did. ⚠️ See the ⚠️ on the type.
    private struct PendingPush {
        let uuid: UUID
        let event: PushEvent?
        let completion: () -> Void
    }

    private weak var incoming: IncomingCallModel?
    private weak var registrar: PushRegistrar?

    private var pending: [PendingPush] = []

    /// The last PushKit token, held until an owner can register it.
    ///
    /// ⛔ PushKit ISSUES ITS CREDENTIAL AS SOON AS `desiredPushTypes` IS SET, i.e.
    /// AT LAUNCH, WHICH IS BEFORE ANY SIGN-IN. A register sent then spends a 401
    /// against a 20/min per-account ceiling and records nothing, so the token is
    /// held here and handed over when a ``PushRegistrar`` exists — which itself
    /// holds it again until the session gate resolves.
    private var pendingToken: String?

    // MARK: - Adoption

    /// Learn about the one ``IncomingCallModel``, and hand it anything already
    /// ringing.
    func adopt(incoming: IncomingCallModel) {
        self.incoming = incoming
        let buffered = pending
        pending = []
        for push in buffered {
            deliver(push, to: incoming)
        }
    }

    /// Learn about the one ``PushRegistrar``, and hand it a token that arrived
    /// first.
    func adopt(registrar: PushRegistrar) {
        self.registrar = registrar
        guard let token = pendingToken else { return }
        registrar.voipTokenReceived(token)
    }

    // MARK: - PKPushRegistryDelegate

    /// ⛔ HEX, LOWERCASE, ZERO-PADDED PER BYTE, exactly as the APNs device token
    /// is encoded in ``AppDelegate``. The server stores the string it is given and
    /// replays it to APNs verbatim; a formatting that dropped a leading zero
    /// produces a token that is accepted here, written to the row, and rejected by
    /// APNs forever after, with nothing anywhere reporting a fault.
    nonisolated func pushRegistry(
        _ registry: PKPushRegistry,
        didUpdate pushCredentials: PKPushCredentials,
        for type: PKPushType
    ) {
        // ⚠️ `nonisolated(unsafe)` FOR THE REASON ``CallKitBridge``'S ACTION
        // HANDLERS USE IT: `PKPushCredentials` is not `Sendable`, and this method
        // already runs on the main queue because the registry was built with one.
        nonisolated(unsafe) let credentials = pushCredentials
        // ⚠️ THE TYPE IS COMPARED OUT HERE AND CROSSES AS A `Bool`. `PKPushType` is
        // an ObjC string-backed struct whose `Sendable`-ness is an SDK detail
        // rather than something this file should depend on, and a `Bool` cannot be
        // wrong about it.
        let isVoIP = type == .voIP
        MainActor.assumeIsolated {
            guard isVoIP else { return }
            let hex = credentials.token.map { String(format: "%02x", $0) }.joined()
            tokenReceived(hex)
        }
    }

    /// ⛔ THE TOKEN IS GONE AND MUST NOT BE RE-REGISTERED. PushKit invalidates a
    /// credential when the system decides this installation may no longer receive
    /// VoIP pushes; a held copy would be handed to the next sign-in and written
    /// onto a row that can never be delivered to, which is the silent way push
    /// stays off.
    nonisolated func pushRegistry(
        _ registry: PKPushRegistry,
        didInvalidatePushTokenFor type: PKPushType
    ) {
        let isVoIP = type == .voIP
        MainActor.assumeIsolated {
            guard isVoIP else { return }
            pendingToken = nil
            registrar?.voipTokenInvalidated()
        }
    }

    nonisolated func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        nonisolated(unsafe) let payload = payload
        nonisolated(unsafe) let completion = completion
        let isVoIP = type == .voIP
        MainActor.assumeIsolated {
            receive(payload: payload, isVoIP: isVoIP, completion: completion)
        }
    }

    // MARK: - Internals

    private func tokenReceived(_ token: String) {
        pendingToken = token
        registrar?.voipTokenReceived(token)
    }

    /// ⚠️ THE PAYLOAD IS PARSED BEFORE THE CALL IS REPORTED, WHICH IS NOT A
    /// VIOLATION OF THE "REPORT FIRST" RULE. ``PushPayload/parse(userInfo:)`` is a
    /// pure dictionary walk with no I/O and no suspension point; what the rule
    /// forbids is doing WORK — a request, a database read, a wait — before the
    /// report, and there is none here. It buys two things: the non-`Sendable`
    /// `[AnyHashable: Any]` never has to cross into a `Task`, and the flattening
    /// rule stays in the module that has tests for it.
    private func receive(payload: PKPushPayload, isVoIP: Bool, completion: @escaping () -> Void) {
        // ⚠️ RE-DECLARED so the capture below is checked the same way the delegate
        // method's was; a parameter is a fresh binding.
        nonisolated(unsafe) let completion = completion
        guard isVoIP else {
            // ⚠️ NOT OURS, AND THE COMPLETION IS STILL CALLED. PushKit expects one
            // for every delivery.
            completion()
            return
        }
        let push = PendingPush(
            uuid: UUID(),
            event: PushPayload.parse(userInfo: payload.dictionaryPayload),
            completion: completion
        )
        guard let incoming else {
            pending.append(push)
            return
        }
        deliver(push, to: incoming)
    }

    private func deliver(_ push: PendingPush, to incoming: IncomingCallModel) {
        nonisolated(unsafe) let push = push
        Task { @MainActor in
            await incoming.incomingPush(uuid: push.uuid, event: push.event)
            // ⚠️ AFTER THE REPORT, NEVER BEFORE. Calling it first tells iOS this
            // app is done with a push it has not acted on yet.
            push.completion()
        }
    }
}
