import Foundation

/// Durable storage for the native session.
///
/// ⛔ THE REFRESH TOKEN IS THE ONLY THING WORTH PERSISTING, AND THE ACCESS TOKEN
/// MUST NOT BE. The access token lives 10 minutes; writing it to disk buys
/// nothing and widens the window in which a stolen backup or a device dump
/// yields a usable credential. ``TokenRefreshCoordinator`` holds it in memory
/// and re-mints it after a process restart.
///
/// ⛔ THE `pendingRefreshToken` MARKER IS NOT AN OPTIMISATION — IT PREVENTS A
/// FALSE SECURITY ALARM. The server's rotation is mandatory and a replayed
/// refresh token revokes the whole family. If the process dies between sending a
/// refresh and persisting its response, the disk still holds a token the server
/// has already rotated. Presenting it on next launch is indistinguishable from
/// theft: the server revokes the family and logs
/// `[auth] Native refresh replay detected`. Recording which token is in flight
/// BEFORE sending it lets the client recognise that state on the next launch and
/// go straight to a clean re-login instead — same user-visible outcome, but no
/// bogus replay alarm and no revocation of a family that was never compromised.
///
/// ⛔ EVERY MEMBER THROWS, AND `read` THROWING IS THE ONE THAT MATTERS. The
/// production implementation is a Keychain store in `App/` carrying
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (AfterFirstUnlock rather
/// than WhenUnlocked so a push-triggered background wake can read the
/// session on a locked phone). Before first unlock, a read on a locked device
/// fails TRANSIENTLY. Modelling that as "no session" — the obvious shape, and
/// what a non-throwing optional would force — signs the user out for having
/// locked their phone. The coordinator maps a thrown read to
/// ``RetryReason/storeUnavailable`` and keeps the session.
///
/// ⛔ THERE ARE NOW TWO PENDING SLOTS AND THEY ARE NOT SYMMETRIC, WHICH IS THE
/// ONE THING TO CARRY AWAY FROM THIS TYPE. ``pendingRefreshToken()`` describes
/// THIS session — a refresh in flight whose outcome is unknown — so it dies with
/// the session and ``clear()`` takes it. ``pendingRevokeToken()`` describes a
/// server-side ROW that OUTLIVES the session, so ``clear()`` must spare it. They
/// look like the same mechanism written twice and they are not; see the ⛔ on
/// ``clear()`` and on ``pendingRevokeToken()``.
public protocol TokenStore: Sendable {
    /// The persisted session, or nil when there is none.
    ///
    /// ⚠️ Throwing and returning nil are DIFFERENT ANSWERS. See the type note.
    func read() async throws -> PersistedSession?

    /// Replace the persisted session. Implementations must write DURABLY before
    /// returning.
    func write(_ session: PersistedSession) async throws

    /// Forget the session, including any pending-refresh marker.
    ///
    /// ⛔ AND DELIBERATELY **NOT** THE REVOKE OUTBOX. The outbox names a
    /// credential the SERVER IS STILL HONOURING, and the sign-out that wrote it
    /// calls this method microseconds later — so a `clear()` that took the
    /// outbox with it would erase the only record of the very token the outbox
    /// exists to chase, which is precisely the stranding it was added to
    /// prevent. The two slots LOOK symmetric and are not: the refresh marker
    /// describes THIS session and dies with it, the revoke outbox describes a
    /// server-side row that outlives it. See ``pendingRevokeToken()``.
    func clear() async throws

    /// The refresh token currently in flight, if a refresh was started and never
    /// observed to complete. Nil in the normal case.
    func pendingRefreshToken() async throws -> String?

    /// Record that `refreshToken` is about to be sent.
    ///
    /// ⛔ MUST BE DURABLE BEFORE RETURNING. If this write is buffered, it is
    /// exactly as lost as the response it exists to detect — and the coordinator
    /// treats a THROWN marker write as a reason to abort the refresh entirely
    /// rather than send one unprotected.
    func markRefreshPending(_ refreshToken: String) async throws

    /// Clear the marker once the rotated token has been durably persisted.
    func clearRefreshPending() async throws

    // ── The revoke outbox ────────────────────────────────────────────────────

    /// A refresh token this device has SIGNED OUT OF LOCALLY but has not yet
    /// been able to revoke server-side. Nil in the normal case.
    ///
    /// ⛔ AN OUTBOX, NOT A MARKER, AND THAT IS WHY IT IS A SECOND SLOT RATHER
    /// THAN A REUSE OF ``pendingRefreshToken()``. That one means "a refresh is
    /// in flight and its outcome is unknown", and ``TokenRefreshCoordinator``
    /// reads it to decide whether the stored token is already spent. Writing a
    /// sign-out into it would make the next launch report
    /// ``ReauthReason/interruptedRefresh`` for a session that was deliberately
    /// ended, and would make a genuine interrupted refresh indistinguishable
    /// from a sign-out.
    ///
    /// ⛔ WHY IT EXISTS AT ALL. `POST /api/auth/native/revoke` answers **503**
    /// when its database write threw, and the route's own header spells out the
    /// client's obligation: KEEP the credential and try again, because the
    /// server may honour that refresh token for the rest of its 60-day life.
    /// But the user asked to sign out NOW, so the local wipe cannot wait — a
    /// device that still looks signed in is the worse of the two failures, and
    /// it is the one the user can see. Keeping the token HERE satisfies both:
    /// the session is gone from the user's point of view, and the credential is
    /// still tracked well enough to be killed on a later launch.
    ///
    /// ⚠️ SCOPED TO ONE ROW SERVER-SIDE, SO A STALE ENTRY IS HARMLESS.
    /// `revokeNativeSession` matches on the presented token's hash alone — not
    /// on its family and not on the user — so draining an entry written before a
    /// re-login cannot touch the new session.
    func pendingRevokeToken() async throws -> String?

    /// Record that `refreshToken` still needs revoking server-side.
    ///
    /// ⛔ MUST BE DURABLE BEFORE RETURNING, for the same reason
    /// ``markRefreshPending(_:)`` must be: a buffered write is lost in exactly
    /// the process death it exists to survive. Here the window is the one
    /// between the outbox write and ``clear()``.
    func markRevokePending(_ refreshToken: String) async throws

    /// Clear the outbox once the server has accepted the token (or was never
    /// holding it — the route answers 200 for both and declines to say which).
    func clearRevokePending() async throws
}

/// What actually goes to disk.
///
/// Note the absence of an access token — see the ⛔ on ``TokenStore``.
public struct PersistedSession: Sendable, Equatable {
    public let refreshToken: String
    /// Epoch MILLISECONDS.
    public let refreshTokenExpiresAt: Int64
    /// Opaque installation id, sent on token exchange so the server can scope
    /// per-device sign-outs.
    public let deviceId: String

    public init(refreshToken: String, refreshTokenExpiresAt: Int64, deviceId: String) {
        self.refreshToken = refreshToken
        self.refreshTokenExpiresAt = refreshTokenExpiresAt
        self.deviceId = deviceId
    }
}

/// A ``TokenStore`` that forgets everything when the process ends.
///
/// ⛔ TESTS AND SWIFTUI PREVIEWS ONLY. It ships in `Sources/` rather than in a
/// test target because DistrictNetwork and DistrictData will both need to
/// construct a coordinator in their own suites, and a fake that lives in one
/// test target cannot be reached from another. ⚠️ Wiring it into `AppContainer`
/// would produce an app that silently signs the user out on every cold start;
/// the real implementation is `KeychainTokenStore` in `App/`, where
/// `kSecAttrSynchronizable = false` is load-bearing (an iCloud-synced refresh
/// token lands on a second device, both present the same token, and the server
/// revokes the entire family as theft).
///
/// ⚠️ NO FAILURE-INJECTION KNOBS, ON PURPOSE. A test that needs `write` to throw
/// declares its own conforming type — one that always fails is three lines. A
/// shared fake with a `failNextWrite` flag becomes a second implementation of
/// the coordinator's own state machine and drifts from it.
public actor InMemoryTokenStore: TokenStore {
    private var session: PersistedSession?
    private var pending: String?
    private var revokePending: String?

    public init(session: PersistedSession? = nil) {
        self.session = session
    }

    public func read() async throws -> PersistedSession? {
        session
    }

    public func write(_ session: PersistedSession) async throws {
        self.session = session
    }

    /// ⛔ `revokePending` IS DELIBERATELY UNTOUCHED HERE. See the ⛔ on
    /// ``TokenStore/clear()``: the outbox outlives the session it was written
    /// during, and this fake has to behave like the real store or a
    /// ``SignOutCoordinator`` test would pass against a store that loses the
    /// entry the production one keeps.
    public func clear() async throws {
        session = nil
        pending = nil
    }

    public func pendingRefreshToken() async throws -> String? {
        pending
    }

    public func markRefreshPending(_ refreshToken: String) async throws {
        pending = refreshToken
    }

    public func clearRefreshPending() async throws {
        pending = nil
    }

    public func pendingRevokeToken() async throws -> String? {
        revokePending
    }

    public func markRevokePending(_ refreshToken: String) async throws {
        revokePending = refreshToken
    }

    public func clearRevokePending() async throws {
        revokePending = nil
    }
}
