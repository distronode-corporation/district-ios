import AuthenticationServices
import DistrictAuthCore
import DistrictNetwork
import Foundation

/// The second sign-in door: Sign in with Apple, in process.
///
/// ⛔ IT EXISTS BECAUSE OF APP STORE REVIEW GUIDELINE 4.8, NOT BECAUSE ANYONE
/// ASKED FOR A SECOND BUTTON. The other door reuses the server's login surface,
/// which offers Google and Microsoft SSO; 4.8 says an app that offers a
/// third-party sign-in service must ALSO offer an equivalent privacy-preserving
/// option, which in practice means this one. The rule is about what is OFFERED,
/// so removing the Apple button while the web surface keeps its Google and
/// Microsoft buttons puts the binary back in violation.
///
/// ⛔ NO BROWSER LEG AND THEREFORE NO PKCE. `ASAuthorizationController` talks to
/// the OS, not to a web page, so there is no redirect, no `state` to bind a
/// callback to, and no authorization code travelling over a custom scheme. What
/// takes PKCE's place is the NONCE: the app puts the SHA-256 of a random value
/// on the request, Apple signs that digest into the identity token, and the app
/// hands our server the RAW value to hash and compare. A token intercepted on
/// the way to Apple cannot be replayed against a different session. See
/// ``AppleNonce`` for which half goes where — getting it backwards is refused
/// and presents as an opaque `invalid_grant`.
///
/// ⛔ `authorizationCode` IS DELIBERATELY NOT SENT. The credential carries one,
/// and the WEB leg spends it against Apple's token endpoint with a minted ES256
/// client secret. `POST /api/auth/native/apple` verifies the identity token
/// against Apple's published JWKS instead and its schema has no such field, so
/// including it is a 400 indistinguishable from a rejected token.
///
/// ⚠️ THE OUTCOME TYPE IS ``LoginOutcome``, THE OTHER DOOR'S. Nothing above this
/// object may be able to tell which door was used: ``SessionModel`` runs one
/// switch, the coordinator adopts one credential pair, and the five keys this
/// route returns are the five `/api/auth/native/token` returns. A second outcome
/// enum would be a second place to word a refusal.
///
/// ⚠️ A SEPARATE OBJECT FROM ``WebAuthLoginController`` RATHER THAN A METHOD ON
/// IT. They share no state — no verifier, no `state`, no session — and the two
/// failure vocabularies are genuinely different (`ASAuthorizationError` against
/// `ASWebAuthenticationSessionError`). What they must share is the COORDINATOR,
/// and they do: ``AppContainer`` hands both the same one.
@MainActor
final class AppleSignInController {
    private let auth: AppNativeAuthClient
    private let coordinator: TokenRefreshCoordinator
    private let deviceId: String
    private let deviceName: String?

    /// The in-flight attempt's nonce, in memory and single-slot.
    ///
    /// ⛔ NEVER PERSISTED, for ``PKCEChallenge``'s reason: an attempt interrupted
    /// by process death is restarted, costing one tap, rather than writing a
    /// live exchange secret to disk. ⚠️ And single-slot means a second tap
    /// abandons the first attempt, which is correct — the user tapped again.
    ///
    /// ⚠️ `private(set)` RATHER THAN `private`, WHICH IS A TESTING SEAM AND
    /// NOTHING ELSE. The pairing this whole file exists to get right — stamped
    /// digest here, raw value in the body — is only assertable if a test can see
    /// which nonce the attempt is holding; deriving it from the request would be
    /// the test reimplementing the bug. Nothing in the app reads it.
    private(set) var pending: AppleNonce?

    init(
        auth: AppNativeAuthClient,
        coordinator: TokenRefreshCoordinator,
        deviceId: String,
        deviceName: String?
    ) {
        self.auth = auth
        self.coordinator = coordinator
        self.deviceId = deviceId
        self.deviceName = deviceName
    }

    // ── Leg one: the request ─────────────────────────────────────────────────

    /// Stamp the request `SignInWithAppleButton` is about to present.
    ///
    /// ⛔ `request.nonce` IS THE **HASHED** HALF. Apple echoes this value back
    /// verbatim as the token's `nonce` claim, and the server compares that claim
    /// to the SHA-256 of what arrives in the request body — so the raw value
    /// goes in the body and this digest goes here. Sending the same value in
    /// both places is refused, by design, on the route.
    ///
    /// ⚠️ `[.fullName, .email]` ARE ASKED FOR AND THEN LARGELY IGNORED, WHICH IS
    /// NOT AN OVERSIGHT. Apple returns them EXACTLY ONCE, on the first
    /// authorisation for this app, and only inside the credential — never again,
    /// and never on a later sign-in. The server does not read them at all: it
    /// takes the address from the identity token's own verified claims and keys
    /// the account on the `sub`. ⛔ AND IT NEVER CREATES ONE: an Apple ID that no
    /// existing account uses is answered 403 (``LoginOutcome/noAccount``), because
    /// creating accounts in-app is "account registration" under Guideline 3.1.1.
    /// Treating the once-only values as the source of truth is the mistake that
    /// makes a second sign-in look like a different person.
    func prepare(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = AppleNonce.new()
        pending = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = nonce.hashed
    }

    /// Abandon an in-flight attempt.
    func cancel() {
        pending = nil
    }

    // ── Leg two: the exchange ────────────────────────────────────────────────

    /// Turn what `SignInWithAppleButton` reported into one ``LoginOutcome``.
    ///
    /// ⛔ THE NONCE IS TAKEN FROM `pending`, NOT FROM THE TOKEN. A client that
    /// read the `nonce` claim out of the identity token and sent a value derived
    /// from it would be handing the server a self-consistent pair and proving
    /// nothing — the comparison only means something because this process chose
    /// the value before Apple ever saw it.
    ///
    /// ⚠️ IT IS CLEARED UP FRONT. This attempt is spent whatever happens, and
    /// leaving it set would let a second, later result reuse the same nonce.
    func complete(_ result: Result<ASAuthorization, any Error>) async -> LoginOutcome {
        guard let nonce = pending else { return .noAttemptInProgress }
        pending = nil

        switch result {
        case let .success(authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                // ⚠️ REACHABLE ONLY IF THE REQUEST TYPE CHANGES. An Apple ID
                // request answers with an Apple ID credential; a password
                // credential arrives only from an `ASAuthorizationPasswordProvider`
                // request, which this controller never makes.
                return .denied("apple_unexpected_credential")
            }
            return await exchange(identityToken: credential.identityToken, nonce: nonce)
        case let .failure(error):
            return Self.outcome(for: error)
        }
    }

    /// Spend the identity token.
    ///
    /// ⚠️ IT TAKES THE RAW `Data` RATHER THAN THE CREDENTIAL so that everything
    /// below the `ASAuthorization` unwrap can be driven by a test. Nothing can
    /// construct an `ASAuthorization` — it has no public initialiser — so the
    /// success path would otherwise be unreachable on every tier, and the first
    /// time anyone exercised it would be a signed device install.
    func exchange(identityToken: Data?, nonce: AppleNonce) async -> LoginOutcome {
        // ⛔ UTF-8, AND A DECODE FAILURE IS A REFUSAL RATHER THAN AN EMPTY BODY.
        // Apple hands the token over as `Data`; the route's schema is
        // `z.string().min(1).max(8192)`. A compact JWS is ASCII by construction,
        // so this cannot fire in practice — which is exactly why it must not
        // fall through to sending `""` and reading the 400 as a rejected sign-in.
        guard let data = identityToken, let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            return .denied("apple_no_identity_token")
        }

        let request = AppleNativeSignInRequest(
            identityToken: token,
            // ⛔ THE RAW HALF. See ``prepare(_:)``.
            nonce: nonce.raw,
            deviceId: deviceId,
            deviceName: deviceName
        )

        switch await auth.exchangeAppleIdentityToken(request) {
        case let .success(tokens):
            // ⛔ THE COORDINATOR ADOPTS, NOTHING ELSE WRITES — the same rule the
            // other door obeys and the same single instance. It persists the
            // refresh token BEFORE the access token becomes visible to any
            // caller, which is the ordering the rotation path depends on.
            await coordinator.adopt(tokens, deviceId: deviceId)
            return .success
        case .rejected:
            return .rejected
        case .rateLimited:
            return .rateLimited
        case .noAccount:
            // ⛔ NOT `rejected` AND NOT `unreachable`. Both tell the user to try
            // again, and no retry can help: this Apple ID has no account, and
            // sign-in never creates one (Guideline 3.1.1).
            return .noAccount
        case let .mfaRequired(challenge):
            // ⛔ NOTHING IS SIGNED IN YET. The Apple ID is verified and the account
            // has an authenticator on, so the server holds the grant until a code is
            // entered. The ticket goes up to the session gate, which opens the code
            // step and spends it through ``submitCode(_:for:now:)``.
            return .mfaRequired(challenge)
        case .transportFailure:
            return .unreachable
        }
    }

    // ── Leg three: the authenticator code ───────────────────────────────────

    /// Spend the MFA ticket with a code the person typed, already shape-checked by
    /// `NativeMfaCode`.
    ///
    /// ⛔ THE SAME `deviceId` AND PLATFORM AS THE APPLE LEG. The ticket is bound to both,
    /// and a mismatch is the opaque 400 that sends the person back to the Apple sheet.
    /// They come from this controller's own fields, which is why the call lives here.
    ///
    /// ⚠️ A TICKET THAT HAS CERTAINLY EXPIRED IS NOT SENT. The answer would be the same
    /// 400, and every request with a code is counted server-side. An expiry this build
    /// could not read is not "expired"; the server decides.
    func submitCode(_ code: String, for challenge: NativeMfaChallenge, now: Date = Date()) async -> MfaCodeOutcome {
        if challenge.isExpired(at: now) {
            return .expired
        }
        let request = NativeMfaRequest(
            challenge: challenge,
            code: code,
            deviceId: deviceId,
            deviceName: deviceName
        )
        switch await auth.submitMfaCode(request) {
        case let .success(tokens):
            // ⛔ The same single adopter as both doors; see ``exchange(identityToken:nonce:)``.
            await coordinator.adopt(tokens, deviceId: deviceId)
            return .success
        case .invalidCode:
            return .wrongCode
        case .ticketRejected:
            return .expired
        case .rateLimited:
            return .rateLimited
        case .transportFailure:
            return .unreachable
        }
    }

    // ── Failures ─────────────────────────────────────────────────────────────

    /// What an `ASAuthorizationController` failure means to the session gate.
    ///
    /// ⛔ A CANCELLATION IS A QUIET NO-OP, NOT A FAILURE, and it is the commonest
    /// outcome after success — a user who opens the sheet and changes their mind
    /// must not be told their sign-in failed. It is the exact counterpart of
    /// `ASWebAuthenticationSessionError.canceledLogin` on the other door.
    ///
    /// ⛔ EVERYTHING ELSE IS `denied`, WITH THE CODE, RATHER THAN `unreachable`.
    /// None of the other `ASAuthorizationError` codes is a network condition:
    /// `.unknown` (1000) is what a missing `com.apple.developer.applesignin`
    /// entitlement produces, `.failed` (1004) is Apple's own refusal, and
    /// `.notHandled`/`.invalidResponse` are the OS declining. Reporting any of
    /// them as "check your connection" sends the user to fix their wifi. The
    /// sentence ``SessionModel`` builds for `denied` names the code, so a support
    /// conversation has something to go on.
    ///
    /// ⚠️ THE CODE IS PREFIXED `apple_` BECAUSE THE NUMBERS COLLIDE WITH NOTHING
    /// AND MEAN NOTHING ON THEIR OWN. "Sign-in was not completed (1000)." reads
    /// like an HTTP status.
    static func outcome(for error: any Error) -> LoginOutcome {
        // ⚠️ THE CONCRETE CAST IS WHAT WORKS. `ASAuthorizationError` is a
        // `_BridgedStoredNSError`, so it bridges to `NSError` the moment it
        // enters an `any Error` existential and `type(of:)` reports `NSError`;
        // the runtime special-cases `as? ASAuthorizationError` and gets it
        // right. Same shape as the `URLError` note in `NativeAuthClient.refresh`.
        guard let authError = error as? ASAuthorizationError else {
            return .denied("apple_failed")
        }
        return authError.code == .canceled ? .cancelled : .denied("apple_\(authError.code.rawValue)")
    }
}

/// The two callbacks `SignInWithAppleButton` needs, bundled so ``SignInView``
/// takes ONE optional value rather than two that must be supplied together.
///
/// ⛔ OPTIONAL, AND THE `unavailable` BRANCH PASSES NIL. That branch renders the
/// same screen to say "we could not CHECK your session" and offers "Try again",
/// which re-reads the coordinator rather than signing anyone in. An Apple button
/// there would offer a fresh sign-in to a user whose session is intact, and the
/// server would mint a second device session for the same handset. Guideline 4.8
/// is satisfied by the button being offered wherever sign-in is, and that branch
/// is not one of those places.
///
/// ⚠️ A STRUCT RATHER THAN THE VIEW OWNING AN ``AppleSignInController``. The
/// controller is a container-lifetime object; a view that built one would build
/// a new one on every render and lose the pending nonce between the request and
/// the completion.
struct AppleSignInHandlers {
    /// Stamp the request. See ``AppleSignInController/prepare(_:)``.
    let prepare: (ASAuthorizationAppleIDRequest) -> Void

    /// Spend the result. See ``AppleSignInController/complete(_:)``.
    let finish: (Result<ASAuthorization, any Error>) -> Void
}
