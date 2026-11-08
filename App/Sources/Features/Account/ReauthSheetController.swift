import AuthenticationServices
import DistrictAuthCore
import DistrictData
import DistrictModel
import Foundation
import UIKit

/// The providers a fresh re-authentication can go through, by their wire names.
///
/// ⛔ THE SERVICE'S `LINKABLE_PROVIDERS`, NOT A GUESS ABOUT THIS ACCOUNT. The app does not know
/// which providers an account has linked, so it offers all three and the service decides: a
/// provider the account does not use is refused on the sheet itself.
enum ReauthProvider: String, CaseIterable, Sendable {
    case google
    case microsoft = "azure-ad"
    case apple

    /// ⛔ PROPER NOUNS, THE SAME IN BOTH LANGUAGES (the service's `PROVIDER_LABEL`).
    var displayName: String {
        switch self {
        case .google: "Google"
        case .microsoft: "Microsoft"
        case .apple: "Apple"
        }
    }
}

/// How one fresh sign-in at a provider ended.
enum SSOReauthOutcome: Equatable, Sendable {
    /// The service holds a proof for this installation, for this many seconds.
    case proved(expiresInSeconds: Int)
    /// The person closed the sheet. ⚠️ Benign: nothing is shown for it.
    case cancelled
    /// ⛔ The callback's `state` was not the one this attempt made. Never exchanged.
    case stateMismatch
    /// The sheet came back without a code.
    case noCode
    /// The sheet could not be presented.
    case couldNotOpen
    /// The service refused the code, or could not be reached.
    case refused(ApiError)
}

/// The SSO leg of a fresh re-authentication before a sensitive action (account deletion).
///
/// ⛔ THE SAME TWO LEGS AS SIGN-IN, WITH THE SAME GUARDS. Leg one is
/// `ASWebAuthenticationSession` on `/auth/native/reauth`, which relays to the provider with a
/// forced fresh sign-in and hands back a one-time code; leg two spends that code with this
/// attempt's PKCE verifier (`POST /api/auth/native/reauth/sso`). `state` is checked before the
/// code is spent, and the verifier lives in memory only. See ``WebAuthLoginController``.
///
/// ⛔ NOT EPHEMERAL. The sheet's `reauth/authorize` reads the browser's own session cookie, the
/// one the fresh provider sign-in just stamped; an ephemeral session has none.
///
/// ⚠️ THE SERVICE BINDS THE CODE FOUR WAYS (this account, this installation by
/// `SHA-256(deviceId)`, this action, and the PKCE verifier), so the app adds no check of its own
/// beyond `state`.
@MainActor
final class ReauthSheetController {
    typealias Presenter = @MainActor (URL) async -> Result<URL, any Error>

    /// ⚠️ A PAGE, NOT AN API ROUTE, like the sign-in sheet's `/auth/native`.
    static let sheetPath = "/auth/native/reauth"

    private let baseURL: URL
    private let repository: NativeReauthRepository
    private let deviceId: String
    private let presenter: Presenter

    /// In flight, and single-slot: a second attempt abandons the first.
    private var pending: PKCEChallenge?

    init(baseURL: URL, repository: NativeReauthRepository, deviceId: String, presenter: Presenter? = nil) {
        self.baseURL = baseURL
        self.repository = repository
        self.deviceId = deviceId
        self.presenter = presenter ?? WebAuthSheet.present
    }

    func reauthenticate(provider: ReauthProvider, action: NativeReauthAction) async -> SSOReauthOutcome {
        let challenge = PKCE.newChallenge()
        pending = challenge
        guard let url = Self.sheetURL(
            baseURL: baseURL,
            challenge: challenge,
            provider: provider,
            deviceHash: AppleNonce.sha256Hex(deviceId),
            action: action
        ) else {
            pending = nil
            return .couldNotOpen
        }

        switch await presenter(url) {
        case let .success(callback):
            return await complete(callback, action: action)
        case let .failure(error):
            pending = nil
            return WebAuthSheet.isUserCancellation(error) ? .cancelled : .couldNotOpen
        }
    }

    /// The sheet's address.
    ///
    /// ⚠️ `snake_case` QUERY NAMES, the page's own (`code_challenge`, `redirect_uri`); the
    /// exchange's body is `camelCase`. `device` is the installation id's SHA-256 in hex, never
    /// the id itself.
    static func sheetURL(
        baseURL: URL,
        challenge: PKCEChallenge,
        provider: ReauthProvider,
        deviceHash: String,
        action: NativeReauthAction
    ) -> URL? {
        let base = baseURL.absoluteString.hasSuffix("/")
            ? String(baseURL.absoluteString.dropLast())
            : baseURL.absoluteString
        guard var components = URLComponents(string: base + sheetPath) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "code_challenge", value: challenge.challenge),
            URLQueryItem(name: "state", value: challenge.state),
            URLQueryItem(name: "redirect_uri", value: WebAuthLoginController.redirectURI),
            URLQueryItem(name: "provider", value: provider.rawValue),
            URLQueryItem(name: "device", value: deviceHash),
            URLQueryItem(name: "action", value: action.rawValue),
        ]
        return components.url
    }

    private func complete(_ callback: URL, action: NativeReauthAction) async -> SSOReauthOutcome {
        guard let attempt = pending else { return .stateMismatch }
        // Spent whatever happens: a second callback must not reuse the verifier.
        pending = nil

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        guard let state = value("state"), state == attempt.state else { return .stateMismatch }
        guard let code = value("code"), !code.isEmpty else { return .noCode }

        let result = await repository.reauthenticate(
            action: action,
            code: code,
            codeVerifier: attempt.verifier,
            redirectUri: WebAuthLoginController.redirectURI
        )
        switch result {
        case let .success(seconds):
            return .proved(expiresInSeconds: seconds)
        case let .failure(error):
            return .refused(error)
        }
    }
}

/// One `ASWebAuthenticationSession`, presented and awaited.
///
/// ⚠️ THE SAME CHOICES AS ``WebAuthLoginController``'s sheet, for the same reasons: the
/// deprecated initialiser (the deployment floor is iOS 17.0), not ephemeral, and a single
/// resume. Kept separate so the sign-in path is not touched by the re-authentication one.
@MainActor
enum WebAuthSheet {
    static func present(_ url: URL) async -> Result<URL, any Error> {
        let anchor = AnchorProvider()
        return await withCheckedContinuation { continuation in
            let resumer = ContinuationOnce(continuation)
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: WebAuthLoginController.callbackScheme
            ) { callback, error in
                if let callback {
                    resumer.finish(.success(callback))
                } else {
                    resumer.finish(.failure(error ?? WebAuthLoginError.noCallback))
                }
            }
            // ⚠️ `presentationContextProvider` IS WEAK: the closure below keeps `anchor` alive
            // until the session ends.
            session.presentationContextProvider = anchor
            session.prefersEphemeralWebBrowserSession = false
            resumer.onFinish { _ = anchor; _ = session }
            if !session.start() {
                resumer.finish(.failure(WebAuthLoginError.couldNotStart))
            }
        }
    }

    static func isUserCancellation(_ error: any Error) -> Bool {
        (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
    }

    private final class AnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            MainActor.assumeIsolated {
                let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                let window = scenes.first { $0.activationState == .foregroundActive }?.keyWindow
                    ?? scenes.first?.keyWindow
                return window ?? ASPresentationAnchor()
            }
        }
    }
}

/// Resumes a `CheckedContinuation` exactly once, and holds what must outlive the sheet.
///
/// ⛔ A SECOND RESUME TRAPS, and `start()` returning false is documented not to call the
/// completion handler, so either path may be the one that finishes.
private final class ContinuationOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<URL, any Error>, Never>?
    private var retained: (() -> Void)?

    init(_ continuation: CheckedContinuation<Result<URL, any Error>, Never>) {
        self.continuation = continuation
    }

    func onFinish(_ retain: @escaping () -> Void) {
        lock.withLock { retained = retain }
    }

    func finish(_ result: Result<URL, any Error>) {
        let pending: CheckedContinuation<Result<URL, any Error>, Never>? = lock.withLock {
            let held = continuation
            continuation = nil
            retained = nil
            return held
        }
        pending?.resume(returning: result)
    }
}
