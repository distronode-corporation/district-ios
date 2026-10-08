import AuthenticationServices
import DistrictAuthCore
import DistrictNetwork
import Foundation
import UIKit

/// Drives the two-leg native login.
///
/// ⛔ LEG ONE HAPPENS IN `ASWebAuthenticationSession`, NOT A `WKWebView`, AND
/// THAT IS THE POINT. It reuses the server's EXISTING login surface — Google SSO,
/// Microsoft SSO and the argon2id password route — instead of reimplementing
/// three flows and their rate limits natively. A web view would additionally be
/// refused by Google's OAuth policy for embedded user agents, and would hand this
/// app the user's Google password.
///
/// ⛔ LEG TWO IS A DIRECT POST NO OTHER PROCESS OBSERVED. The browser can only
/// hand back a URL, and URLs are observable — logs, history, another app claiming
/// the scheme. So it carries a single-use code, worthless without the PKCE
/// verifier this object kept in memory.
///
/// ⚠️ THE VERIFIER IS DELIBERATELY NEVER PERSISTED. A login interrupted by
/// process death is simply restarted, costing one tap, rather than writing a live
/// exchange secret to disk. Do not "fix" ``pending`` by storing it.
///
/// ⚠️ `ASWebAuthenticationSession` NARROWS THE CUSTOM-SCHEME WINDOW BUT DOES NOT
/// CLOSE IT. It intercepts the callback in-session rather than relying on OS
/// scheme routing, so a second app registering `districtai://` does not receive
/// this callback. The redirect is still a custom scheme, so PKCE plus `state` is
/// what makes an intercepted code worthless.
@MainActor
final class WebAuthLoginController: NSObject {
    /// ⛔ BYTE-FOR-BYTE THE SERVER'S NATIVE REDIRECT ALLOWLIST, WHICH IS A
    /// LITERAL-EQUALITY CHECK THAT MUST NEVER BE RELAXED. It is compared twice
    /// server-side — once at authorize time and once at exchange time against
    /// the value the code was minted for — so a trailing slash here fails login
    /// with an opaque `invalid_grant`.
    static let redirectURI = "districtai://auth"

    /// The scheme half of ``redirectURI``, which is what
    /// `ASWebAuthenticationSession` matches on.
    ///
    /// ⚠️ NO `://`, NO PATH. The API takes a bare scheme and a value carrying
    /// either fails to match the callback, which presents as the browser sheet
    /// never closing.
    static let callbackScheme = "districtai"

    /// ⚠️ A PAGE, NOT AN API ROUTE. `/auth/native` bounces an unauthenticated
    /// visitor through `/login?redirect=…`, and Next's client router cannot
    /// navigate to an API route — pointing this at one would break the password
    /// path specifically while SSO appeared to work.
    private static let authorizePath = "/auth/native"

    private let baseURL: URL
    private let auth: AppNativeAuthClient
    private let coordinator: TokenRefreshCoordinator
    private let deviceId: String
    private let deviceName: String?

    /// The in-flight attempt, in memory and single-slot: starting a new login
    /// abandons any previous one, which is correct — the user tapped sign in
    /// again.
    private var pending: PKCEChallenge?

    /// Held only so the session outlives `start()`. ⚠️ Without a strong
    /// reference the sheet can be torn down before the user finishes.
    private var session: ASWebAuthenticationSession?

    init(
        baseURL: URL,
        auth: AppNativeAuthClient,
        coordinator: TokenRefreshCoordinator,
        deviceId: String,
        deviceName: String?
    ) {
        self.baseURL = baseURL
        self.auth = auth
        self.coordinator = coordinator
        self.deviceId = deviceId
        self.deviceName = deviceName
        super.init()
    }

    /// Run one complete login.
    func signIn() async -> LoginOutcome {
        let challenge = PKCE.newChallenge()
        pending = challenge

        guard let url = authorizeURL(for: challenge) else {
            pending = nil
            return .denied("unbuildable_authorize_url")
        }

        switch await present(url) {
        case let .success(callback):
            return await complete(callback)
        case let .failure(error):
            pending = nil
            return Self.isUserCancellation(error) ? .cancelled : .unreachable
        }
    }

    /// Abandon an in-flight attempt.
    func cancel() {
        pending = nil
        session?.cancel()
        session = nil
    }

    // ── Leg one ──────────────────────────────────────────────────────────────

    /// The URL the system browser opens.
    ///
    /// ⚠️ THE THREE PARAMETER NAMES ARE THE SERVER'S, IN `snake_case`, AND THEY
    /// DIFFER FROM THE `camelCase` BODY KEYS OF THE EXCHANGE. The authorize page reads
    /// `code_challenge`, `state` and `redirect_uri`; the token route's schema
    /// reads `codeVerifier` and `redirectUri`. Mixing them up fails at authorize
    /// time with "The sign-in request was malformed", before any code exists.
    func authorizeURL(for challenge: PKCEChallenge) -> URL? {
        // ⚠️ Assembled as a STRING rather than with `appendingPathComponent`,
        // which percent-encodes a multi-segment component and would produce
        // `/auth%2Fnative`.
        let text = baseURL.absoluteString.trimmedTrailingSlash + Self.authorizePath
        guard var components = URLComponents(string: text) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "code_challenge", value: challenge.challenge),
            URLQueryItem(name: "state", value: challenge.state),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
        ]
        return components.url
    }

    private func present(_ url: URL) async -> Result<URL, any Error> {
        await withCheckedContinuation { continuation in
            let resumer = SingleResume(continuation)
            // ⚠️ THE DEPRECATED INITIALISER, DELIBERATELY. Its replacement takes
            // an `ASWebAuthenticationSession.Callback` and `.customScheme(_:)` is
            // iOS 17.4+, while this target deploys to 17.0 — so the modern form
            // would be a hard availability error rather than the deprecation
            // WARNING this produces. Swap both together if the floor ever moves.
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: Self.callbackScheme
            ) { callback, error in
                if let callback {
                    resumer.finish(.success(callback))
                } else {
                    resumer.finish(.failure(error ?? WebAuthLoginError.noCallback))
                }
            }
            session.presentationContextProvider = self
            // ⛔ FALSE, AND THAT IS THE WHOLE REASON THIS FLOW IS WORTH HAVING.
            // An ephemeral session carries no cookies, so a user already signed
            // in to distronode.com in Safari would have to re-authenticate to
            // Google or Microsoft inside the sheet every single time. The
            // credential the app ends up with is bound by PKCE either way.
            session.prefersEphemeralWebBrowserSession = false
            self.session = session

            // ⚠️ `start()` RETURNING FALSE DOES NOT CALL THE COMPLETION HANDLER,
            // so this branch is the only report of that failure — and `resumer`
            // is what keeps a double resume from trapping if that ever stops
            // being true.
            if !session.start() {
                resumer.finish(.failure(WebAuthLoginError.couldNotStart))
            }
        }
    }

    // ── Leg two ──────────────────────────────────────────────────────────────

    /// Validate the callback and exchange its code.
    ///
    /// ⛔ `state` IS CHECKED BEFORE THE CODE IS SPENT. Any app on the device can
    /// register `districtai://`, so a callback can arrive that this app never
    /// initiated — an injected code, or an old callback replayed from history.
    /// Exchanging one would bind this app's session to an attacker-chosen
    /// account.
    private func complete(_ callback: URL) async -> LoginOutcome {
        guard let attempt = pending else { return .noAttemptInProgress }
        // Cleared up front: this attempt is spent whatever happens, and leaving
        // it set would let a second callback reuse the same verifier.
        pending = nil
        session = nil

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }

        guard let state = value("state"), state == attempt.state else {
            return .stateMismatch
        }
        // The handoff page surfaces its own refusals as an `error` parameter
        // rather than a code.
        if let error = value("error") {
            return .denied(error)
        }
        guard let code = value("code") else {
            return .denied("missing_code")
        }

        let request = CodeExchangeRequest(
            code: code,
            codeVerifier: attempt.verifier,
            redirectUri: Self.redirectURI,
            deviceId: deviceId,
            deviceName: deviceName
        )

        switch await auth.exchangeCode(request) {
        case let .success(tokens):
            // ⛔ THE COORDINATOR ADOPTS, NOTHING ELSE WRITES. It persists the
            // refresh token BEFORE the access token becomes visible to any
            // caller — the same ordering rule the rotation path obeys, and the
            // reason there is exactly one of it.
            await coordinator.adopt(tokens, deviceId: deviceId)
            return .success
        case .rejected:
            return .rejected
        case .rateLimited:
            return .rateLimited
        case .noAccount:
            // ⚠️ UNREACHABLE TODAY: `exchangeCode` maps no status to it, because
            // the PKCE route signs in an account the web login already resolved.
            // Passed through rather than folded into `unreachable` so that, if the
            // token route ever answers it, the user reads the true sentence.
            return .noAccount
        case .transportFailure, .mfaRequired:
            // ⚠️ `mfaRequired` IS UNREACHABLE HERE: `exchangeCode` never produces it,
            // since the web page asks for the code before a PKCE code exists. Should
            // it ever arrive, there is no ticket this door could spend, so it is the
            // ambiguous answer it was before the case existed.
            return .unreachable
        }
    }

    private static func isUserCancellation(_ error: any Error) -> Bool {
        (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
    }
}

/// ⚠️ REQUIRED, NOT OPTIONAL. `ASWebAuthenticationSession` refuses to start on iOS
/// without a presentation context provider, and the failure arrives as a generic
/// start failure rather than as anything naming this protocol.
extension WebAuthLoginController: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.first { $0.activationState == .foregroundActive }?.keyWindow
            ?? scenes.first?.keyWindow
        // ⚠️ The fallback is an EMPTY window rather than a crash. Reaching it
        // means the app has no window at all, in which case the sheet fails to
        // present and `signIn()` reports `.unreachable` — which is wrong but
        // recoverable, unlike a force unwrap on a launch-time race.
        return window ?? ASPresentationAnchor()
    }
}

/// How one login attempt ended.
enum LoginOutcome: Sendable, Equatable {
    case success

    /// The user dismissed the browser sheet. ⚠️ Benign, and must not be rendered
    /// as a failure — it is the commonest outcome after "success".
    case cancelled

    /// A callback arrived with no attempt in flight — a stale deep link,
    /// typically. Benign on its own, and deliberately distinguished from
    /// ``stateMismatch``, which is not.
    case noAttemptInProgress

    /// ⛔ The callback's `state` did not match the one this app generated. Treat
    /// as hostile: a code was injected, or a callback replayed. Never exchanged.
    case stateMismatch

    /// The handoff page refused, with its own reason.
    case denied(String)

    /// Expired (codes live 120 seconds), replayed, or a PKCE mismatch. The server
    /// collapses all of them into one opaque answer on purpose. Start over.
    case rejected

    case rateLimited

    /// ⛔ The Apple door's 403: a verified Apple ID that no District AI account
    /// uses. Sign-in never creates an account, so this is an invitation problem
    /// the user cannot fix by retrying, and it is worded calmly rather than as a
    /// failure. See ``SignInCopy/noAccount``.
    case noAccount

    /// ⛔ The Apple door's 401 `mfa_required`: the Apple ID is verified and the account
    /// has an authenticator enrolled, so nothing is signed in until a code is entered.
    /// Not a failure, and not worded as one: ``SessionModel`` opens the code step. The
    /// browser door never produces it (the web page asks for the code itself).
    case mfaRequired(NativeMfaChallenge)

    /// The exchange never got a usable answer.
    case unreachable
}

enum WebAuthLoginError: Error {
    case couldNotStart
    case noCallback
}

/// Drop one trailing `/`, if there is one.
///
/// ⚠️ The base URL is written without one, but a configured value could carry
/// it and `//auth/native` addresses a different path.
///
/// ⚠️ THIS IS ITS ONLY CALLER. ``NativeAuthClient`` in `DistrictNetwork` does not
/// need it: it appends its path one SEGMENT at a time, which absorbs a trailing
/// slash on the way. This leg still assembles a string, because the authorize
/// path is multi-segment and `appendingPathComponent` would percent-encode
/// `/auth/native` whole.
private extension String {
    var trimmedTrailingSlash: String {
        hasSuffix("/") ? String(dropLast()) : self
    }
}

/// Guarantees a `CheckedContinuation` is resumed exactly once.
///
/// ⛔ A CHECKED CONTINUATION TRAPS ON A SECOND RESUME, AND THE PATH THAT COULD
/// CAUSE ONE IS NOT UNDER OUR CONTROL. `ASWebAuthenticationSession.start()` is
/// documented to return false without invoking the completion handler; if a
/// future SDK ever does both, the app would crash at the moment a user tried to
/// sign in. Eleven lines of lock is cheaper than that class of report from a
/// release build nobody can attach a debugger to.
private final class SingleResume: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<URL, any Error>, Never>?

    init(_ continuation: CheckedContinuation<Result<URL, any Error>, Never>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<URL, any Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: result)
    }
}
