import Foundation

/// The network seam ``TokenRefreshCoordinator`` refreshes through.
///
/// ⛔ IT IS A SEAM RATHER THAN A DIRECT CALL BECAUSE THE REFRESH ROUTE CANNOT
/// RIDE THE AUTHENTICATED CLIENT. Getting an access token is what this call is
/// FOR, so routing it through something that acquires one first deadlocks. The
/// implementation lives in DistrictNetwork alongside the other two
/// unauthenticated native-auth routes (`token`, `revoke`), all of which sit
/// under the server's public `/api/auth/` prefix precisely because the caller
/// has no usable session.
public protocol RefreshClient: Sendable {
    func refresh(refreshToken: String) async -> RefreshResult
}

/// What a refresh attempt learned.
///
/// ⛔ THE STATUS MAPPING IS SECURITY-RELEVANT, NOT PLUMBING. Getting it wrong
/// either signs users out needlessly or, far worse, re-presents a spent refresh
/// token and revokes their whole family. The mapping is derived from the
/// server's refresh route, not guessed, and is the same one the Android
/// client's `NativeAuthApi` documents:
///
/// | status | route behaviour                                   | case               |
/// |--------|---------------------------------------------------|--------------------|
/// | 200    | rotated successfully                              | `success`          |
/// | 401    | `invalid_grant` — the credential is dead          | `rejected`         |
/// | 429    | limited BEFORE rotation, token NOT consumed       | `rateLimited`      |
/// | 400    | malformed body; never reached rotation            | `rateLimited`      |
/// | 5xx    | may have rotated before failing — AMBIGUOUS       | `transportFailure` |
/// | I/O    | no answer — AMBIGUOUS                             | `transportFailure` |
/// | connect| the request provably never left the device        | `notSent`          |
public enum RefreshResult: Sendable, Equatable {
    case success(NativeTokens)

    /// A definite 401 `invalid_grant`. Unknown, expired, revoked or replayed —
    /// the server collapses all four into one opaque answer on purpose, so
    /// there is nothing to distinguish here. Any of them means this credential
    /// is dead.
    case rejected

    /// HTTP 429, or a 400 the route rejected before touching
    /// `rotateNativeSession`.
    ///
    /// ⛔ NOT A DEAD CREDENTIAL, AND CONFLATING IT WITH ONE LOGS THE USER OUT
    /// FOR NOTHING. The refresh route runs its rate-limit check BEFORE
    /// `rotateNativeSession`, so on a 429 the token was provably never consumed
    /// and is still valid. The server's own comment sizes the limit to allow
    /// "several devices behind one NAT", which is exactly when this fires in the
    /// field.
    case rateLimited

    /// No usable answer — a timeout, a 5xx, an unreadable 200.
    ///
    /// ⚠️ AMBIGUOUS: the server may have processed the rotation anyway, which is
    /// why the coordinator deliberately LEAVES the pending marker set here.
    case transportFailure

    /// The request PROVABLY never left the device — DNS failure, connection
    /// refused, no route, a TLS handshake that never completed.
    ///
    /// ⛔ DISTINCT FROM ``transportFailure`` BECAUSE CONFLATING THEM SIGNED
    /// PEOPLE OUT FOR BEING OFFLINE. Both were once mapped together, which
    /// leaves the marker set because the token *might* have been spent. For a
    /// connect-phase failure it provably was not: no byte reached the server. So
    /// opening the app in airplane mode — any cold start more than ten minutes
    /// after last use, since the access token is memory-only — marked the token
    /// pending, failed to send it, and the next attempt saw marker == stored
    /// token and cleared the session. One offline app-open cost a re-login.
    ///
    /// ⚠️ A READ TIMEOUT IS NOT THIS. A connect timeout and a read timeout are
    /// often the same error type, and a read timeout means the request was
    /// already sent — so it stays ambiguous.
    case notSent
}
