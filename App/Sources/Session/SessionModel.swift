import AuthenticationServices
import DistrictAuthCore
import Foundation
import Observation

/// What the shell knows about the session right now.
///
/// ⛔ FOUR CASES, NOT TWO, AND THE FOURTH IS THE ONE THAT MATTERS. "We could not
/// check" is not "you are signed out": ``TokenRefreshCoordinator`` reports
/// ``AccessTokenOutcome/retryLater(_:)`` for a locked Keychain, a throttled refresh
/// and a request that never left the device, and in all three the session is intact.
/// Collapsing that into a sign-out screen is the same class of mistake as rendering
/// `workspace/list`'s 503 `REGIONS_DEGRADED` as an empty list: "we could not look"
/// and "there is nothing" read to a paying customer as account loss.
enum AuthPhase: Equatable {
    case checking
    case signedIn
    /// Terminal for this session: the user must log in again.
    case signedOut(String)
    /// Transient. The session is intact; try again.
    case unavailable(String)
}

/// The session gate's model: what phase the app is in, and the actions that
/// change it — the browser sign-in, the Apple sign-in, and the sign-out.
///
/// ⚠️ `@Observable` AND `@State`, NOT `ObservableObject`. iOS 17 is the deployment
/// floor, so the macro's per-property tracking applies: a view that reads only
/// ``epoch`` is not invalidated when ``isBusy`` flips. New models in this app must
/// not reach for `@Published`.
///
/// ⛔ IT OWNS NOTHING BUT THE PHASE. Feature state belongs to the feature's own
/// model; this one exists so that ``RootView`` can decide between the shell and the
/// sign-in screen, and so that every feature model can react to a completed sign-in
/// through ``epoch``.
@MainActor
@Observable
final class SessionModel {
    private(set) var phase: AuthPhase = .checking
    private(set) var isBusy = false

    /// Bumped once for every COMPLETED sign-in.
    ///
    /// ⛔ THE MECHANISM THAT STOPS A SIGNED-IN USER STARING AT "your session has
    /// ended". Without it, a session that expires mid-use leaves every screen holding
    /// a terminal failure state, and signing back in reloads a model nobody is looking
    /// at, so the only way out is killing the app. Feature models attach `.task(id: session.epoch)` and re-read when it
    /// changes. Mirrors `OnSessionChanged` / `SessionSignal`.
    ///
    /// ⚠️ IT COUNTS SIGN-INS, NOT PHASE CHANGES. A failed attempt and a sign-out
    /// must not bump it: a screen that re-read on a sign-out would issue a request
    /// with no credential and render its own 401.
    private(set) var epoch = 0

    private let container: AppContainer
    private let selection: WorkspaceSelectionStore

    /// ⚠️ HELD ONLY TO ORDER THE PUSH SIDE OF A SIGN-OUT. This model does not turn
    /// push ON — that is the session gate's job, once it renders the shell — but it
    /// is the one place that observes a session ENDING, in either of the two ways
    /// that can happen. See ``refreshPhase()`` and ``signOut()``.
    private let push: PushRegistrar

    init(
        container: AppContainer,
        push: PushRegistrar,
        selection: WorkspaceSelectionStore = WorkspaceSelectionStore()
    ) {
        self.container = container
        self.push = push
        self.selection = selection
    }

    /// Ask the coordinator where we stand.
    ///
    /// ⚠️ THIS CAN SPEND A REFRESH ROTATION, which is correct: the access token is
    /// memory-only by design, so a cold start has nothing cached and the answer to
    /// "am I signed in" genuinely requires asking the server.
    ///
    /// ⛔ THE PUSH MEMORY IS FORGOTTEN ON THE `reauthRequired` BRANCH, AND THIS IS
    /// THE SIGN-OUT NOBODY THINKS ABOUT. ``signOut()`` is the button; this is the
    /// session the SERVER ended — revoked from another device, expired at 60 days,
    /// a refresh rejected — where no local sign-out sequence ever runs. Without the
    /// clear here, the next account to sign in on this handset would find its own
    /// APNs token already remembered, skip the register, and never claim the
    /// installation row. The server's upsert is keyed on the INSTALLATION, so the
    /// PREVIOUS account would go on receiving this device's notifications.
    ///
    /// ⚠️ `retryLater` IS DELIBERATELY NOT THIS BRANCH. The session is intact
    /// there (a locked Keychain, a throttled refresh); forgetting would cost a
    /// pointless re-register the next time it succeeds.
    func refreshPhase() async {
        switch await container.coordinator.accessToken() {
        case .available:
            phase = .signedIn
        case let .reauthRequired(reason):
            phase = .signedOut(Self.text(for: reason))
            push.forget()
        case let .retryLater(reason):
            phase = .unavailable(Self.text(for: reason))
        }
    }

    func signIn() async {
        isBusy = true
        defer { isBusy = false }
        await settle(container.login.signIn())
    }

    /// The Guideline 4.8 door.
    ///
    /// ⛔ IT ENDS AT THE SAME ``settle(_:)`` AS THE BROWSER DOOR, AND THAT IS THE
    /// WHOLE POINT. `POST /api/auth/native/apple` returns the five keys
    /// `/api/auth/native/token` returns, ``AppleSignInController`` answers with
    /// the same ``LoginOutcome``, and the same coordinator adopts the pair — so
    /// nothing above this line can tell which door a session came through, and
    /// there is exactly one place a refusal is worded.
    ///
    /// ⚠️ THE RESULT ARRIVES FROM `SignInWithAppleButton`'s COMPLETION, so this
    /// takes it rather than starting anything: the sheet has already been
    /// presented and dismissed by the time this runs.
    func signInWithApple(_ result: Result<ASAuthorization, any Error>) async {
        isBusy = true
        defer { isBusy = false }
        await settle(container.appleLogin.complete(result))
    }

    /// ⚠️ ONE SWITCH FOR BOTH DOORS. A second copy would be a second place to
    /// get `cancelled` wrong — which is the case that must stay a silent no-op.
    private func settle(_ outcome: LoginOutcome) async {
        switch outcome {
        case .success:
            await refreshPhase()
            // ⚠️ AFTER the phase is settled, so a model woken by the change reads a
            // coordinator that already holds a token rather than racing the refresh.
            epoch += 1
        case .cancelled, .noAttemptInProgress:
            // ⚠️ NOT AN ERROR AND NOT A STATE CHANGE. Dismissing the sheet is the
            // second commonest outcome of tapping sign in.
            break
        case .stateMismatch:
            phase = .signedOut("That sign-in could not be verified. Please try again.")
        case let .denied(reason):
            phase = .signedOut("Sign-in was not completed (\(reason)).")
        case .rejected:
            phase = .signedOut("That sign-in expired. Please try again.")
        case .rateLimited:
            phase = .unavailable("Too many attempts. Please try again shortly.")
        case .noAccount:
            // ⛔ `signedOut`, SO THE SCREEN KEEPS BOTH DOORS: the invited email
            // signs in through the browser door. The sentence is informational,
            // not a retry prompt; see ``SignInCopy/noAccount``.
            phase = .signedOut(SignInCopy.noAccount)
        case .unreachable:
            phase = .unavailable("We could not reach District AI. Check your connection.")
        }
    }

    /// Local sign-out.
    ///
    /// ⛔ CLEARS THE WORKSPACE SELECTION TOO, AND IT IS NOT A SECRECY MEASURE. A
    /// workspace id is not a credential; leaving it means the next user of a shared
    /// device lands in the previous user's workspace by default. The Android client
    /// does the same in its own container and asserts it.
    ///
    /// ⛔ UNREGISTER, THEN REVOKE, THEN FORGET, IN THAT ORDER. The unregister
    /// authenticates with the ACCESS token, so it goes in as `beforeRevoke` and
    /// runs while the session is still alive; reversing it strands a live push row
    /// against a dead session. ``PushRegistrar/forget()`` runs after, because it is
    /// purely local and must happen whether or not the unregister reached the
    /// server.
    ///
    /// ⛔ THE UNREGISTER CANNOT FAIL THIS. It is bounded by its own short timeout
    /// and reports nothing back: a sign-out that hung, or refused, because a
    /// courtesy channel could not be withdrawn would leave a live refresh token
    /// behind, which is much the worse outcome.
    func signOut() async {
        isBusy = true
        defer { isBusy = false }
        await container.signOut(beforeRevoke: { await push.unregisterForSignOut() })
        push.forget()
        selection.setSelectedWorkspaceId(nil)
        phase = .signedOut("You are signed out.")
    }

    // ── Wording ──────────────────────────────────────────────────────────────

    /// ⚠️ ONE MAPPING, IN ONE PLACE. What must survive any rewrite is that every
    /// reason that IS a reason has a sentence and that none of them accuses the
    /// user of anything.
    ///
    /// ⚠️ A COLD START HAS NOTHING TO EXPLAIN, SO `.noSession` IS EMPTY. The
    /// sign-in screen already says "Sign in to your workspace." above its one
    /// button; a second instruction underneath reads as a duplicated line. The
    /// status slot exists to carry
    /// a REASON ("signed out after 60 days", "could not be verified"), and
    /// Android's `SignInScreen` likewise shows no status on a cold start.
    /// `SignInView` renders the panel only for a non-empty reason.
    private static func text(for reason: ReauthReason) -> String {
        switch reason {
        case .noSession:
            ""
        case .interruptedRefresh:
            // ⛔ NOT A SECURITY EVENT, AND MUST NEVER BE WORDED AS ONE. It means the
            // app was killed mid-refresh, so the stored token is presumed spent. The
            // server accepts that this costs a re-login; the wording should too.
            "Your session ended unexpectedly. Please sign in again."
        case .refreshTokenExpired:
            "You have been signed out after 60 days. Please sign in again."
        case .refreshRejected:
            "Your session is no longer valid. Please sign in again."
        case .refreshUnreachable:
            "We could not confirm your session. Please sign in again."
        }
    }

    private static func text(for reason: RetryReason) -> String {
        switch reason {
        case .refreshThrottled:
            "Too many requests. Please try again shortly."
        case .refreshNotSent:
            "You appear to be offline. Your session is still active."
        case .storeUnavailable:
            // The Keychain read failed, typically because the device is locked.
            "We could not read your saved session. Please try again."
        case .markerNotDurable:
            "We could not safely refresh your session. Please try again."
        }
    }
}
