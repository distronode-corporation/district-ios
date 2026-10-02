import DistrictData
import DistrictModel
import Foundation
import Observation
import UIKit
import UserNotifications

/// Whether this installation may show notifications, as last observed.
///
/// ⛔ `denied` IS A STATE, NOT AN ERROR, AND THE DIFFERENCE IS THE WHOLE TYPE.
/// Declining the system prompt is an ordinary, reversible choice a person made;
/// rendering it as a failure would put an alarm on a preference. ``unavailable``
/// is the genuinely different case — the request itself did not complete — and it
/// is separated so a later Account screen can offer "try again" for one and "open
/// Settings" for the other.
///
/// ⚠️ FILE SCOPE RATHER THAN NESTED IN ``PushRegistrar``, following
/// `DistrictButtonVariant`: a helper type nested inside a type that conforms to a
/// protocol with associated types can be silently picked up as the witness, and
/// the resulting error surfaces somewhere else entirely.
enum PushAuthorization: Equatable, Sendable {
    /// Nothing has been asked. The session gate has not reached signed-in yet.
    case notAsked
    /// The prompt was answered yes.
    case authorized
    /// Answered no, or switched off later in Settings. ⛔ Not an error.
    case denied
    /// The authorization request itself failed. Distinct from ``denied``.
    case unavailable(String)
}

/// What the LAST registration attempt actually did.
///
/// ⛔ IT EXISTS BECAUSE THE PREVIOUS ANSWER WAS "nothing, silently". `deviceTokenReceived`
/// discarded the repository's result and `remoteRegistrationFailed` wrote a string no view
/// read, so when the delegate cast broke and every device token was dropped, the app had
/// four regions of empty `DevicePushToken` and not one surface that could say so. A state
/// nobody can read is the same as a state nobody records.
///
/// ⚠️ IT IS THE ATTEMPT'S OUTCOME, NOT A PERMISSION. ``PushAuthorization`` answers "may we
/// show anything"; this answers "did this installation get registered". Both are needed to
/// say something true: authorised-and-refused and denied-and-never-tried look identical
/// from either one alone.
enum PushRegistrationStatus: Equatable, Sendable {
    /// No token has come back from APNs yet, so nothing has been sent.
    case notAttempted
    /// The server holds this installation.
    case registered
    /// The server answered and said no. ⚠️ The status is carried because 401 (session
    /// gone), 429 (the 20/min ceiling) and 5xx are different problems with different
    /// remedies, and "registration failed" hides which one happened.
    case refused(status: Int)
    /// The request never reached the server.
    case unreachable
    /// APNs itself declined to issue a device token, so there was nothing to send.
    case apnsRefused
}

/// When this installation's push token is registered, and when it is withdrawn.
///
/// ⛔ ``PushTokenRepository`` OWNS THE TWO CALLS; THIS OWNS THE **ORDERING**, WHICH
/// IS THE PART WITH RULES. There are three moments and each has a constraint that
/// is invisible from the repository:
///
///   1. **After the session gate reaches signed-in.** Not at launch: before a
///      sign-in there is no bearer, so a register would spend a 401 against a
///      20/min per-account ceiling and record nothing. And not merely tidy — the
///      server's upsert is keyed on the INSTALLATION, so a handset previously
///      signed in as somebody else keeps delivering THEIR notifications until this
///      account claims the row.
///   2. **On every token rotation.** APNs reissues a device token on its own
///      schedule (a restore to a new device, a reinstall), and
///      `didRegisterForRemoteNotificationsWithDeviceToken` is the only notice of
///      it. A missed rotation is silent: our server keeps accepting the old token
///      and APNs keeps rejecting it, so push stops with nothing reporting a fault.
///   3. **Before the sign-out revoke, never after.** The unregister authenticates
///      with the ACCESS token; once the refresh token is revoked and the store
///      wiped there is no credential left to make the call with.
///
/// ⛔ NOTHING HERE MAY BLOCK OR FAIL THE THING IT IS ATTACHED TO. A sign-in that
/// failed because a courtesy channel could not be registered, or a sign-out that
/// hung on an unreachable server while the user watched, are both worse outcomes
/// than no push. So (1) and (2) are fire-and-forget, and (3) — which the sign-out
/// sequence genuinely has to WAIT for, because it must precede the revoke — is
/// bounded by ``unregisterTimeout`` rather than by URLSession's own timeout. A
/// sign-out is a button somebody pressed; thirty seconds of nothing is a broken
/// app. The Kotlin `PushRegistrar` makes the identical three points.
///
/// ⛔ ONE PER PROCESS, BUILT IN `DistrictApp` ALONGSIDE THE ONE ``AppContainer``
/// AND THREADED DOWN. A second one would hold a second `hasAskedThisLaunch`, so
/// the system prompt could be raised twice in one launch, and its
/// ``pendingTapPayload`` would be the one nothing was reading.
@MainActor
@Observable
final class PushRegistrar {
    /// Five seconds. Named because a bare literal in the timeout race below reads
    /// as a magic number, and because the value is a product decision (how long a
    /// sign-out may pause for a courtesy call) rather than a network one.
    static let unregisterTimeout: Double = 5

    /// The last authorization answer, for a later Account screen to show.
    private(set) var authorization: PushAuthorization = .notAsked

    /// The most recent APNs registration failure, if any.
    ///
    /// ⛔ DIAGNOSTIC ONLY AND NEVER USER-FACING. `didFailToRegisterForRemote
    /// Notifications` fires for a simulator with no push service, a device with no
    /// network at launch, and a provisioning profile without the `aps-environment`
    /// entitlement. None of those is something a person can act on, and all three
    /// are ordinary. It is stored rather than logged because this app has no
    /// logging surface anyone can read: `App/` ships no `Logger` and the estate
    /// collects no device logs, so a `print` here would go nowhere at all.
    private(set) var lastRegistrationFailure: String?

    /// The outcome of the last registration attempt. See ``PushRegistrationStatus``.
    private(set) var registration: PushRegistrationStatus = .notAttempted

    /// The payload of the notification the user last tapped, un-parsed.
    ///
    /// ⛔ FLAT `[String: String]`, AND NOTHING HERE ROUTES IT. `PushPayload` and
    /// `PushDeepLink` live in `DistrictModel` (where they are testable on Linux) and
    /// the shell does the routing; parsing it here would put the parser on the one
    /// tier with no tests.
    var pendingTapPayload: [String: String]?

    private let container: AppContainer

    /// ⚠️ ONCE PER LAUNCH, NOT ONCE PER SIGN-IN. The system prompt is a one-shot
    /// per install, and `UNUserNotificationCenter` answers the stored decision
    /// silently afterwards — but ``enableAfterSignIn()`` is attached to a view's
    /// appearance, which can recur, and a rebuilt shell must not queue a second
    /// authorization request behind the first.
    private var hasAskedThisLaunch = false

    /// The PushKit token, held until there is a session to register it against.
    ///
    /// ⛔ IT IS NOT CLEARED ONCE REGISTERED, AND THAT IS WHAT MAKES A SECOND
    /// SIGN-IN WORK. PushKit issues its credential once per launch; a sign-out
    /// clears ``PushTokenRepository``'s remembered value (see ``forget()``), so the
    /// next account has to register the SAME token again and there is no callback
    /// left to deliver it. The register is idempotent server-side and skipped
    /// locally when the remembered value already matches, so keeping it costs
    /// nothing.
    ///
    /// ⚠️ nil ON A SIMULATOR AND ON A BUILD WITH NO `aps-environment`, which is
    /// ordinary rather than a fault.
    private var pendingVoipToken: String?

    /// ⚠️ ITS OWN FLAG RATHER THAN A READ OF ``authorization``. The VoIP register
    /// has nothing to do with the notification prompt: a person who declined
    /// alerts still gets telephone calls, because CallKit draws the ring rather
    /// than `UNUserNotificationCenter`.
    private var sessionIsLive = false

    /// Which workspace this device is working in, for the badge read below.
    ///
    /// ⚠️ INJECTED WITH A DEFAULT, exactly as ``SessionModel`` and
    /// ``WorkspaceSessionModel`` take the same store. It is a struct over
    /// `UserDefaults.standard` rather than state of its own, so a second one is not a
    /// second source of truth; the default keeps the one construction site in
    /// `DistrictApp` unchanged.
    private let selection: WorkspaceSelectionStore

    init(container: AppContainer, selection: WorkspaceSelectionStore = WorkspaceSelectionStore()) {
        self.container = container
        self.selection = selection
    }

    /// The session gate has reached signed-in: claim this installation.
    ///
    /// ⛔ THE ATTACH HAPPENS FIRST AND UNCONDITIONALLY, BEFORE THE AUTHORIZATION
    /// BRANCH. Two things depend on it: the device-token callback needs somewhere
    /// to land, and `PushTapRelay` needs draining of any notification tapped at
    /// cold launch — which happens even when authorization is denied, because the
    /// grant may have been withdrawn after the notification was delivered.
    ///
    /// ⚠️ SAFE TO CALL AGAIN. A repeat re-attaches (idempotent) and then returns,
    /// because the prompt is already asked; the register itself is idempotent
    /// server-side and skipped locally by the remembered token.
    func enableAfterSignIn() {
        // ⚠️ NO DELEGATE WIRING HERE. Casting `UIApplication.shared.delegate` fails on
        // device; see the ⛔ in `DistrictApp.body`. Adoption happens once, there,
        // through the adaptor's own instance, and BEFORE any sign-in, so there is
        // nothing left to attach at this point.
        // ⛔ BEFORE THE `hasAskedThisLaunch` GUARD, NOT AFTER IT. A returning
        // appearance takes the early exit below, and the VoIP token frequently
        // arrives on exactly one of those: PushKit issues its credential at launch,
        // asynchronously, so the token can land after the first sign-in and be
        // waiting at the second appearance. Behind the guard it would never be
        // registered and the phone would never ring.
        sessionIsLive = true
        registerVoipTokenIfPossible()
        guard !hasAskedThisLaunch else { return }
        hasAskedThisLaunch = true
        Task { await requestAuthorizationThenRegister() }
    }

    /// PushKit issued this installation's VoIP token.
    ///
    /// ⛔ IT IS NOT REGISTERED ON ARRIVAL. `PKPushRegistry` hands the credential
    /// over as soon as `desiredPushTypes` is set, which is at LAUNCH — before any
    /// sign-in — so registering here would spend a 401 against a 20/min
    /// per-account ceiling and record nothing. The token is held and sent when the
    /// session gate reaches signed-in, which is the same ordering rule the alert
    /// token follows for the same reason.
    func voipTokenReceived(_ token: String) {
        pendingVoipToken = token
        registerVoipTokenIfPossible()
    }

    /// PushKit withdrew the token. ⛔ It must not be re-registered on the next
    /// sign-in: a row pointing at a dead credential is push that is silently off.
    func voipTokenInvalidated() {
        pendingVoipToken = nil
    }

    /// APNs issued a device token for this installation.
    ///
    /// ⚠️ THE TOKEN IS HANDED IN RATHER THAN FETCHED. The delegate callback already
    /// holds the new value, and asking the system again would be a second source of
    /// truth that can disagree with the callback that woke us — which is the exact
    /// moment a disagreement is most likely.
    ///
    /// ⚠️ FIRE AND FORGET. There is nothing to offer a person here: a failed
    /// registration means push may not work, which every path in this app already
    /// tolerates. The result is still recorded; see below.
    func deviceTokenReceived(_ token: String) {
        let repository = container.pushTokens
        // ⛔ THE RESULT IS READ, NOT DISCARDED. "Nothing to offer a person" is true of
        // an ALERT and false of a RECORD: without it the app could not distinguish
        // "registered" from "the server refused every attempt".
        Task {
            registration = await Self.status(for: repository.register(token: token))
        }
    }

    /// Map the repository's answer onto something a row can say.
    ///
    /// ⚠️ `alreadyRegistered` AND `noTokenToRegister` ARE BOTH `registered`-ADJACENT BUT
    /// ONLY ONE IS. A skip means the server already holds this token, so the installation
    /// IS registered; an empty token means nothing was ever sent and the honest answer is
    /// that no attempt has happened.
    static func status(
        for result: Result<PushRegistrationOutcome, ApiError>
    ) -> PushRegistrationStatus {
        switch result {
        case let .success(outcome):
            switch outcome {
            case .registered, .alreadyRegistered: .registered
            case .noTokenToRegister: .notAttempted
            }
        case let .failure(error):
            switch error {
            case let .http(status, _): .refused(status: status)
            case .transport: .unreachable
            // ⚠️ CONTRACT DRIFT READS AS A REFUSAL, because from this device's side it
            // is one: the server answered and the answer could not be honoured.
            case .decoding: .refused(status: 200)
            }
        }
    }

    /// APNs refused to issue a token.
    ///
    /// ⛔ NOT LOG-ONLY. Log-only, a handset which APNs had declined looks exactly like one
    /// that had registered. It is not an ALERT — nothing interrupts anybody — but it is
    /// readable on the Account screen, because "notifications will not arrive" is a
    /// fact the person holding the phone is entitled to.
    func remoteRegistrationFailed(_ error: Error) {
        lastRegistrationFailure = String(describing: error)
        registration = .apnsRefused
    }

    /// Withdraw this installation, BEFORE the session is revoked.
    ///
    /// ⛔ AWAITED, UNLIKE THE OTHER TWO, BECAUSE THE ORDER IS THE POINT: it needs
    /// the live bearer that the next step of `AppContainer.signOut()` destroys.
    ///
    /// ⚠️ BOUNDED BY ``unregisterTimeout``, AND THE TIMEOUT CANCELS THE WORK RATHER
    /// THAN ABANDONING IT. On expiry the sign-out proceeds regardless, leaving a
    /// registered row the server retires on its own once APNs reports the token
    /// gone. A device left looking signed in because a courtesy call hung is the
    /// worse failure, and it is the one the user can see.
    ///
    /// ⚠️ THE REPOSITORY IS HOISTED INTO A LOCAL BEFORE THE TASKS. It is a
    /// `Sendable` struct, so copying it lets the child tasks run without reaching
    /// back into this main-actor object for `container` — which under Swift 6 is a
    /// cross-actor read rather than a style preference.
    func unregisterForSignOut() async {
        let repository = container.pushTokens
        let work = Task { await repository.unregister() }
        let deadline = Task {
            try? await Task.sleep(for: .seconds(Self.unregisterTimeout))
            work.cancel()
        }
        _ = await work.value
        deadline.cancel()
    }

    /// Forget the remembered token. ⛔ AFTER the revoke, and on any sign-out.
    ///
    /// ⛔ IT RUNS ON EVERY TRANSITION INTO SIGNED-OUT, NOT ONLY ON THE BUTTON, and
    /// that is the load-bearing half rather than tidiness. A session ended by the
    /// SERVER — revoked from another device, or a refresh rejected — never reaches
    /// ``unregisterForSignOut()`` at all. Without this, the next account to sign in
    /// on the handset would find its own device token already remembered, skip the
    /// register, and never claim the installation row: the server's upsert is keyed
    /// on the INSTALLATION, so the previous account would keep receiving this
    /// device's notifications. See ``SessionModel/refreshPhase()``.
    func forget() {
        // ⛔ THE FLAG GOES WITH THE MEMORY. Leaving it set would let a VoIP token
        // arriving during the signed-out window be registered against a session
        // that no longer exists, and the 401 would look like a broken route.
        sessionIsLive = false
        container.pushTokens.forgetRegistration()
        // ⛔ AND THE BADGE GOES WITH BOTH, FOR A REASON THE OTHER TWO LINES DO NOT
        // COVER. A number left on the icon is a count of the previous account's
        // unread messages, still on the home screen of a handset that may now be
        // somebody else's. This is the right place for it precisely because of the
        // ⛔ above: this method runs on EVERY transition into signed-out, including
        // the one the server ends, where no local sign-out sequence runs at all.
        UnreadBadge.clear()
    }

    /// A `content-available` push woke this app. Refresh the badge, and nothing else.
    ///
    /// ⛔ THE CALLER MUST REPORT THIS RESULT TO iOS EXACTLY ONCE, on every path. See
    /// ``AppDelegate/application(_:didReceiveRemoteNotification:fetchCompletionHandler:)``,
    /// which is the only caller and owns that half of the contract.
    ///
    /// ⚠️ IT LIVES ON THE REGISTRAR BECAUSE THE DELEGATE HOLDS NOTHING ELSE.
    /// ``AppDelegate`` builds no object graph by design, so the one ``AppContainer``
    /// reaches a background wake through this object or not at all. What is here is
    /// the decision; the badge itself is ``UnreadBadge``.
    ///
    /// ⛔ ONE SMALL READ, INSIDE A BUDGET OF ROUGHLY THIRTY SECONDS, AFTER WHICH THE
    /// APP IS SUSPENDED MID-REQUEST. `messages/unread-count` is the cheap route by
    /// construction: ``InboxRepository/unreadCount(workspaceId:)`` exists so that a
    /// badge can be had without paying for the 500-message scan the conversation list
    /// costs. ⛔ Nothing else may be added here. A timeline, a contact sync or a
    /// conversation fetch spends the budget, and an app that overruns it is woken for
    /// fewer of the pushes it is sent afterwards.
    ///
    /// ⚠️ A SIGNED-OUT APP ANSWERS `.noData` QUIETLY RATHER THAN ERRORING, AND
    /// ``sessionIsLive`` IS THE ANSWER ALREADY IN HAND. It is set when the session
    /// gate reaches signed-in and cleared by ``forget()`` on every transition out.
    /// Asking ``TokenRefreshCoordinator`` instead would spend a refresh rotation, in
    /// the background, to decide whether to draw a number on an icon.
    ///
    /// ⚠️ A COLD BACKGROUND LAUNCH ANSWERS `.noData` FOR THE SAME REASON, which is
    /// accepted rather than worked around: nothing has signed in yet in that process,
    /// so there is no session to trust. The ordinary case is a resident app iOS wakes,
    /// where the flag is set and the read happens.
    ///
    /// ⛔ `.failed` RATHER THAN `.newData` WHEN THE READ FAILS, AND THE BADGE IS LEFT
    /// EXACTLY AS IT WAS. Zeroing it would say "nothing unread" on the strength of a
    /// request that never answered.
    ///
    /// ⚠️ THIS METHOD IS WHY THIS FILE IMPORTS `DistrictModel`, AND NOTHING BELOW
    /// SPELLS THE TYPE. Nothing in `DistrictCore` is `@_exported`, so the members read
    /// off the ``UnreadCountResponse`` that ``InboxRepository`` hands back need their
    /// own import. Leaning on the transitive load compiles today and is exactly what
    /// `MemberImportVisibility` turns into an error, so do not tidy the import away.
    func handleSilentPush() async -> UIBackgroundFetchResult {
        guard sessionIsLive else { return .noData }
        guard let workspaceId = selection.selectedWorkspaceId() else { return .noData }
        // ⚠️ HOISTED INTO A LOCAL, as in ``unregisterForSignOut()``: the repository is
        // a `Sendable` struct, so the await below does not reach back into this
        // main-actor object for `container`.
        let repository = container.inbox
        switch await repository.unreadCount(workspaceId: workspaceId) {
        case let .success(response):
            // ⚠️ ALREADY AFFIRMED: ``InboxRepository/unreadCount(workspaceId:)`` turns a
            // `{"success": false}` into a failure, so a success here is a real count.
            UnreadBadge.set(response.count)
            return .newData
        case .failure:
            return .failed
        }
    }

    // ── Internals ────────────────────────────────────────────────────────────

    /// ⚠️ FIRE AND FORGET, AND THE RESULT IS DISCARDED FOR THE REASON
    /// ``deviceTokenReceived(_:)``'S IS: there is nothing to offer a person here,
    /// and every path in this app already tolerates push not working.
    private func registerVoipTokenIfPossible() {
        guard sessionIsLive, let token = pendingVoipToken else { return }
        let repository = container.pushTokens
        Task { _ = await repository.registerVoip(token: token) }
    }

    private func requestAuthorizationThenRegister() async {
        do {
            let center = UNUserNotificationCenter.current()
            let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            authorization = granted ? .authorized : .denied
            guard granted else { return }
        } catch {
            // ⛔ NOT `denied`. "We could not ask" and "they said no" offer
            // different next steps, and conflating them would tell somebody they
            // had refused something they were never shown.
            authorization = .unavailable(String(describing: error))
            return
        }
        // ⚠️ REGISTERING FOR REMOTE NOTIFICATIONS IS SEPARATE FROM THE PROMPT.
        // Authorization governs what may be SHOWN; this is what asks APNs for a
        // device token, and it is the call whose callback lands on `AppDelegate`.
        UIApplication.shared.registerForRemoteNotifications()
    }
}
