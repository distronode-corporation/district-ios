import DistrictData
import DistrictModel
import Foundation

/// Keeps the notify-read token the notification service extension spends on a sender's name.
///
/// ⛔ THE APP MINTS AND STORES IT; THE EXTENSION ONLY SPENDS IT. The mint runs under the app's
/// own session bearer (`POST /api/auth/native/notify-token`, the core's
/// `NotifyTokenRepository.mint()`), and the token goes in the shared Keychain group
/// (``NotifyTokenKeychain``), never the session's.
///
/// ⚠️ WHEN: ``PushRegistrar/enableAfterSignIn()`` asks on every signed-in appearance, which is
/// the sign-in and every launch with a session, and a mint happens only when
/// ``NotifyToken/needsRenewal(_:at:)`` says so (missing, expired or within seven days of
/// expiry). A 401 in the extension clears the token, so the next launch mints again.
///
/// ⛔ ONE MINT AT A TIME, AND NONE WRITTEN AFTER A SIGN-OUT. The route allows 10 mints a
/// minute per account and the appearance can recur, so a second ask joins the first. A
/// sign-out (``forget()``) clears the token and turns a mint still on the wire into one that
/// writes nothing: it would name the family that just ended, for the next account to inherit.
@MainActor
final class NotifyTokenRenewal {
    typealias Mint = @Sendable () async -> Result<NotifyTokenResponse, ApiError>

    private let mint: Mint
    private let store: any NotifyTokenStoring
    private let now: @MainActor () -> Date
    private var running: Task<Void, Never>?
    /// Moved by ``forget()``, so a mint begun before it is recognised when it lands.
    private var generation = 0

    convenience init(repository: NotifyTokenRepository) {
        self.init(mint: { await repository.mint() }, store: NotifyTokenKeychain(), now: { Date() })
    }

    init(mint: @escaping Mint, store: any NotifyTokenStoring, now: @escaping @MainActor () -> Date) {
        self.mint = mint
        self.store = store
        self.now = now
    }

    /// Mint and store a fresh token if the stored one needs it. Returns the mint in flight, if
    /// any, for a test to await.
    ///
    /// ⚠️ NOTHING IS MINTED WHERE NOTHING CAN BE KEPT: an unsigned build (no group), or a
    /// Keychain that cannot answer (a phone not unlocked since it restarted). The next launch
    /// asks again.
    @discardableResult
    func renewIfNeeded() -> Task<Void, Never>? {
        if let running {
            return running
        }
        guard store.canStore else { return nil }
        let current: NotifyToken?
        do {
            current = try store.read()
        } catch {
            return nil
        }
        guard NotifyToken.needsRenewal(current, at: now()) else { return nil }
        let started = generation
        let task = Task { [self] in
            let outcome = await mint()
            guard started == generation else { return }
            running = nil
            // ⚠️ A FAILED MINT KEEPS WHATEVER WAS STORED: the server is the authority on expiry,
            // and the extension degrades to the alert as sent. So does an expiry this build
            // cannot read, rather than storing a token with an invented lifetime.
            guard case let .success(response) = outcome, let expiresAt = WireInstant.parse(response.expiresAt) else {
                return
            }
            try? store.write(NotifyToken(token: response.token, expiresAt: expiresAt))
        }
        running = task
        return task
    }

    /// Signed out: clear the token, and make any mint in flight write nothing.
    func forget() {
        generation += 1
        running = nil
        try? store.clear()
    }
}
