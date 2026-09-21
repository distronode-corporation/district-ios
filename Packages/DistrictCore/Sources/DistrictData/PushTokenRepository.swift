import DistrictModel
import DistrictNetwork
import Foundation

/// Where the last token this installation successfully registered is kept.
///
/// ⛔ A PROTOCOL BECAUSE THE ONLY SENSIBLE STORE IS `UserDefaults`, WHICH THIS
/// TIER CANNOT SEE. The implementation is `UserDefaultsPushTokenMemory` in
/// `App/Sources/Platform/`; everything that decides ANYTHING from the value lives
/// here, where it is tested on Linux.
///
/// ⛔ `UserDefaults` RATHER THAN THE KEYCHAIN, AND FOR THE SAME REASON
/// ``DeviceIdentity`` uses it: a Keychain item survives app deletion, so a
/// reinstall would come back claiming to have already registered a token that the
/// fresh install does not have. Defaults are wiped with the app, which is exactly
/// what "this is a new installation" should mean.
///
/// ⚠️ NOT A SECRET, BUT NOT NOTHING EITHER. An APNs device token authorises
/// sending TO one installation and is useless without our Firebase service
/// account, so it is stored as issued. It still identifies one handset, so it is
/// never logged.
/// ⛔ SIX MEMBERS RATHER THAN THREE, BECAUSE ONE HANDSET HOLDS **TWO** PUSH
/// TOKENS AND THEY ROTATE INDEPENDENTLY. APNs issues the alert token to
/// `UIApplication.registerForRemoteNotifications()`; PushKit issues an entirely
/// separate one to `PKPushRegistry`. A single remembered value would make the
/// VoIP register skip because the ALERT token was unchanged, and the phone would
/// then be reachable for notifications and unreachable for ringing — which is the
/// half nobody notices until a call is missed. ⚠️ Two named pairs rather than one
/// pair taking a ``PushTokenKind``: the kind is a `DistrictNetwork` type and this
/// protocol's implementation lives in `App/`, where the fewer types it has to
/// know about the better. See ``UserDefaultsPushTokenMemory``.
public protocol PushTokenMemory: Sendable {
    /// The last alert token the server AFFIRMED, or nil if there is none.
    func lastRegisteredToken() -> String?
    func rememberRegisteredToken(_ token: String)
    func forgetRegisteredToken()

    /// The last PushKit token the server AFFIRMED, or nil if there is none.
    ///
    /// ⛔ A SEPARATE KEY, NOT A SECOND USE OF THE ONE ABOVE. See the ⛔ on the
    /// protocol.
    func lastRegisteredVoipToken() -> String?
    func rememberRegisteredVoipToken(_ token: String)
    func forgetRegisteredVoipToken()
}

/// What a register call did.
///
/// ⛔ THREE OUTCOMES AND ALL THREE ARE SUCCESSES, WHICH IS THE POINT OF THE TYPE.
/// Collapsing them into `Void` would lose the only two facts a caller can act on:
/// whether a request was actually spent against a 20/min per-account ceiling, and
/// whether there was a token to spend it on at all. Collapsing "nothing to
/// register" into a FAILURE would be worse — a handset with no APNs token is an
/// ordinary state (the user declined notifications, or the simulator has no push
/// service), not a fault to report.
public enum PushRegistrationOutcome: Equatable, Sendable {
    /// The server affirmed the registration, and the token was remembered.
    case registered
    /// Byte-identical to the last token the server affirmed for this
    /// installation, so no request was sent. See ``PushTokenRepository/register(token:)``.
    case alreadyRegistered
    /// There was no token to register. No request was sent.
    case noTokenToRegister
}

/// This installation's push registration: on after sign-in, off before sign-out.
///
/// ⛔ EVERY FUNCTION HERE RETURNS AND NONE THROWS, AND THAT IS THE CONTRACT RATHER
/// THAN DEFENSIVE HABIT. Push is a courtesy channel layered on paths that already
/// work without it (the inbox has a poll; an unanswered ring falls through to
/// PSTN), so a registration failure must never fail the thing it was attached to.
/// The two call sites make that concrete: one runs during sign-IN, where throwing
/// would turn a completed login into a failed one, and the other runs during
/// sign-OUT, where throwing would abandon the token revoke that follows it.
///
/// ⛔ IT DOES NOT DECIDE **WHEN** TO REGISTER. Sequencing (after a sign-in, on a
/// token rotation, before the revoke and never on a timer) lives in
/// `PushRegistrar` in the app target, because it needs `UNUserNotificationCenter`
/// and `UIApplication`. What crosses into here is a `String`.
///
/// ⛔ AND THE ORDER AROUND SIGN-OUT IS UNREGISTER, THEN REVOKE, THEN FORGET.
/// ``unregister()`` authenticates with the ACCESS token; once
/// `SignOutCoordinator` has revoked the refresh token and wiped the store there is
/// no credential left to make the call with, and the row would sit registered
/// until APNs eventually reported the token gone.
///
/// ⚠️ IT REMEMBERS THE LAST REGISTERED TOKEN, WHICH IS A DELIBERATE DIVERGENCE
/// FROM THE KOTLIN CLIENT, AND THE DIVERGENCE IS SAFE ONLY BECAUSE OF WHAT IS
/// REMEMBERED. `PushTokenRepository.kt` caches nothing, and its reasoning is
/// worth reading before touching this: a local "already done" FLAG is wrong
/// exactly after the case it exists to optimise (a rotation) and survives into a
/// session belonging to a different account. Neither hazard applies to a
/// remembered TOKEN VALUE:
///
///   - a rotated token is a different string, so it is never skipped;
///   - the value is cleared by ``unregister()`` and by ``forgetRegistration()``,
///     and the app clears it on EVERY transition into signed-out rather than only
///     on the sign-out button, so it cannot survive into another account's
///     session. That last clearing is the load-bearing half: the server's upsert
///     is keyed on the INSTALLATION, so a handset that skipped its register would
///     keep delivering the PREVIOUS account's notifications.
///
/// ⚠️ WHAT IT BUYS is one fewer request per foreground sign-in against a 20/min
/// per-account ceiling. That is small, and the rule above is what keeps it from
/// being expensive.
public struct PushTokenRepository: Sendable {
    private let client: ApiClient
    private let memory: any PushTokenMemory

    public init(client: ApiClient, memory: any PushTokenMemory) {
        self.client = client
        self.memory = memory
    }

    /// Tell the server this installation can be pushed to at `token`.
    ///
    /// ⛔ AN EMPTY TOKEN IS REFUSED WITHOUT A REQUEST, AND IT IS A REAL CASE
    /// RATHER THAN A GUARD FOR TIDINESS. Sending one spends a request against the
    /// 20/min ceiling to be told 400 — and a client that read that 400 as
    /// "registration failed" would retry it.
    ///
    /// ⛔ `platform` IS SENT EXPLICITLY AS `"ios"` BY THE ENDPOINT, AND IT IS
    /// MANDATORY. The route's schema DEFAULTS it to `"android"`, so omitting it
    /// works and silently mislabels every row this client writes — and the
    /// server's push sender selects the APNs payload from exactly that column.
    /// See ``DistrictEndpoints/registerPushToken(token:)``.
    ///
    /// ⚠️ IDEMPOTENT SERVER-SIDE: the row is upserted on the installation id the
    /// bearer names, so registering an unchanged token is free and registering a
    /// new one replaces the old. The skip below is a courtesy to the rate limit,
    /// never a correctness requirement.
    public func register(token: String) async -> Result<PushRegistrationOutcome, ApiError> {
        await send(token: token, kind: .alert)
    }

    /// Tell the server this installation can be RUNG at `token`.
    ///
    /// ⛔ A SECOND ROW ON THE SAME ROUTE, NOT A REPLACEMENT FOR
    /// ``register(token:)``, AND SENDING ONE WITHOUT THE SERVER HALF OVERWRITES
    /// THE OTHER. The server needs a `kind` column on `DevicePushToken` and a
    /// `@@unique([deviceId, kind])`; without them the route's upsert is keyed on
    /// `deviceId` ALONE and its schema drops the unknown `kind` key silently, so
    /// this call would move the installation's one row onto the VoIP
    /// token and every ALERT push would stop arriving. ⚠️ The failure is invisible
    /// from here: the register answers 200 and the row is written. See
    /// ``PushTokenKind``.
    ///
    /// ⛔ AND IT MUST NOT BE CALLED BEFORE A SIGN-IN. PushKit issues its
    /// credential as soon as `desiredPushTypes` is set, which is at LAUNCH — long
    /// before there is a bearer — so the sequencing (hold the token, register it
    /// when the session gate reaches signed-in) belongs to `PushRegistrar` in the
    /// app target. Called early this spends a 401 against a 20/min per-account
    /// ceiling and records nothing.
    ///
    /// ⚠️ IDEMPOTENT SERVER-SIDE and skipped locally on an unchanged token, the
    /// same way the alert register is, against its own remembered value.
    public func registerVoip(token: String) async -> Result<PushRegistrationOutcome, ApiError> {
        await send(token: token, kind: .voip)
    }

    /// ⛔ ONE BODY FOR BOTH TOKENS, PARAMETERISED BY KIND RATHER THAN COPIED. The
    /// envelope check, the empty-token refusal, the skip and the
    /// remember-only-after-affirming rule are the same four decisions for each,
    /// and a second copy is what would drift.
    private func send(token: String, kind: PushTokenKind) async -> Result<PushRegistrationOutcome, ApiError> {
        guard !token.isEmpty else { return .success(.noTokenToRegister) }
        guard remembered(kind) != token else { return .success(.alreadyRegistered) }

        let descriptor = DistrictEndpoints.registerPushToken(token: token, kind: kind)
        let outcome = await client.send(descriptor, as: SuccessResponse.self)
        let affirmed = outcome.flatMap { ResponseEnvelope.affirm("PushRegisterResponse", $0.success, $0) }
        switch affirmed {
        case .success:
            // ⚠️ WRITTEN ONLY AFTER THE ENVELOPE AFFIRMED, never merely because a
            // 200 arrived. A `{success:false}` body is contract drift, and
            // remembering a token the server may not hold would make the next
            // register skip and leave push silently off.
            remember(token, kind)
            return .success(.registered)
        case let .failure(error):
            return .failure(error)
        }
    }

    private func remembered(_ kind: PushTokenKind) -> String? {
        switch kind {
        case .alert: memory.lastRegisteredToken()
        case .voip: memory.lastRegisteredVoipToken()
        }
    }

    private func remember(_ token: String, _ kind: PushTokenKind) {
        switch kind {
        case .alert: memory.rememberRegisteredToken(token)
        case .voip: memory.rememberRegisteredVoipToken(token)
        }
    }

    /// Stop pushing to this installation.
    ///
    /// ⛔ THE MEMORY IS CLEARED WHATEVER THE SERVER SAYS, AND THAT ASYMMETRY IS
    /// THE POINT. After an attempted unregister this client can no longer claim
    /// the server holds its token; recording "we do not know" as "still
    /// registered" would make the NEXT register skip, and push would then stay off
    /// with nothing anywhere reporting a problem. Clearing an entry that turns out
    /// to have been fine costs one request.
    ///
    /// ⛔ A `{success:true}` HERE DOES NOT MEAN THERE WAS A ROW. The server
    /// answers it either way, deliberately, so the route is not an existence
    /// oracle over the device-id space. A delete that THREW answers 500, and that
    /// is the case a caller must not report as "push is off": the row may still be
    /// live and this handset may still receive another person's notifications
    /// after they sign in on it.
    ///
    /// ⚠️ A FAILURE MUST NOT BLOCK A SIGN-OUT. The caller proceeds to the revoke
    /// regardless; the server retires a stale row on its own once APNs reports the
    /// token gone.
    ///
    /// ⛔ ONE REQUEST WITHDRAWS **BOTH** TOKENS, AND THAT IS THE SERVER'S SHAPE
    /// RATHER THAN AN OPTIMISATION HERE. The route runs `deleteMany` scoped on
    /// `{userId, deviceId}` and names no kind, so every row this installation
    /// holds goes at once. Both remembered values are therefore cleared: leaving
    /// the VoIP one behind would make the next `registerVoip` skip against a row
    /// the server no longer has, and the phone would stop ringing with nothing
    /// anywhere reporting it.
    public func unregister() async -> Result<Void, ApiError> {
        memory.forgetRegisteredToken()
        memory.forgetRegisteredVoipToken()
        let outcome = await client.send(DistrictEndpoints.unregisterPushToken(), as: SuccessResponse.self)
        return outcome
            .flatMap { ResponseEnvelope.affirm("PushUnregisterResponse", $0.success, $0) }
            .map { _ in () }
    }

    /// Forget the remembered token without telling the server anything.
    ///
    /// ⛔ THE LOCAL HALF OF SIGN-OUT, AND IT RUNS AFTER THE REVOKE RATHER THAN
    /// INSTEAD OF ``unregister()``. It exists for the paths where no unregister
    /// was attempted at all — a session ended by the SERVER (revoked from another
    /// device, or a refresh rejected), where nothing local ever ran. Without it
    /// the next account to sign in on this handset would find its own token
    /// remembered, skip the register, and never claim the installation row.
    ///
    /// ⛔ BOTH TOKENS, FOR THE SAME REASON ``unregister()`` CLEARS BOTH. A VoIP
    /// token left remembered across a server-ended session would make the next
    /// account's `registerVoip` skip, and the previous account's calls would keep
    /// ringing a handset somebody else is now holding — the loudest possible
    /// version of the failure this method exists to prevent.
    public func forgetRegistration() {
        memory.forgetRegisteredToken()
        memory.forgetRegisteredVoipToken()
    }
}
