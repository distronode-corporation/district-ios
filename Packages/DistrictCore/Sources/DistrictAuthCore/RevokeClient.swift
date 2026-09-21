import Foundation

/// The network seam a sign-out revokes through.
///
/// ⛔ A SEAM RATHER THAN A DIRECT CALL, FOR THE SAME REASON AS ``RefreshClient``:
/// `POST /api/auth/native/revoke` carries no bearer — the refresh token IS the
/// credential it authenticates with — so it cannot ride the authenticated
/// client. It sits under the server's public `/api/auth/` prefix alongside
/// `token` and `refresh`. The implementation lives in DistrictNetwork.
///
/// ⚠️ IT CANNOT REPORT A FAILURE THE USER SHOULD HEAR ABOUT, AND THAT IS BY
/// CONSTRUCTION. The local wipe is unconditional (see ``SignOutCoordinator``),
/// so the only question this answers is whether the credential still needs
/// chasing on a later launch.
public protocol RevokeClient: Sendable {
    func revoke(refreshToken: String) async -> RevokeOutcome
}

/// What a sign-out learned about the server.
///
/// ⛔ ONLY A 200 IS ``accepted``, AND EVERYTHING ELSE KEEPS THE CREDENTIAL. The
/// route's header is the authority: it answers 200 for an unknown token ON
/// PURPOSE ("sign-out has one job: end the session and leave the client certain
/// it may discard its credential"), and it split the 503 out specifically so a
/// failed database write stops being reported as a completed sign-out. Nothing
/// in either answer confirms whether a token existed, so a 200 is the ONLY
/// evidence that the server will not honour the token again.
///
/// | status | route behaviour                                | case                          |
/// |--------|------------------------------------------------|-------------------------------|
/// | 200    | revoked, or there was nothing to revoke        | `accepted`                    |
/// | 503    | the database write THREW — may still be live  | `deferred(.serverUnavailable)`|
/// | 429    | rate-limited before the write                  | `deferred(.rateLimited)`      |
/// | I/O    | never got an answer                            | `deferred(.notSent)`          |
/// | other  | anything unmodelled, including a 4xx or a 5xx  | `deferred(.unexpected)`       |
///
/// ⛔ THIS IS DELIBERATELY STRICTER THAN `NativeAuthApi.kt`, WHICH MAPS EVERY 4xx
/// TO ITS `Done`. That client's own argument for the asymmetry is real — a 400
/// is a body this client sent and a 429 is a throttle, and neither resolves by
/// being retried with the same token, so chasing them forever is an outbox entry
/// that can never drain. The trade is taken the other way here because the two
/// failures are not equal: a stuck outbox entry costs one store read per cold
/// start and nothing else (``SignOutCoordinator/drainPendingRevoke()`` makes no
/// network call when the slot is empty and one when it is not), while dropping a
/// credential the server is still honouring strands it, untracked, for up to 60
/// days — which is the exact fail-open the route was changed to stop reporting
/// as success. ⚠️ A 429 in particular expires in about a minute, so a later
/// launch is very likely to drain it; Kotlin's reasoning is weakest on precisely
/// the status it names.
public enum RevokeOutcome: Equatable, Sendable {
    /// The server will not honour that token again — either it just revoked it,
    /// or it never knew it.
    ///
    /// ⚠️ DELIBERATELY DOES NOT DISTINGUISH THOSE. The route declines to confirm
    /// whether a presented token existed (it is unauthenticated by necessity),
    /// so the client could not tell them apart even if it wanted to.
    case accepted

    /// The server did not say the token is gone. ⛔ KEEP THE CREDENTIAL: it goes
    /// into ``TokenStore/pendingRevokeToken()`` so a later launch can finish the
    /// job.
    case deferred(RevokeDeferral)
}

/// Why a revoke must be retried.
///
/// ⚠️ THE PAYLOAD IS DIAGNOSTIC, NOT A BRANCH. Every case means the same thing
/// to ``SignOutCoordinator`` — keep the token — and it is modelled rather than
/// collapsed to a bare `deferred` so a Sentry breadcrumb can say WHICH answer
/// the server gave. ⛔ Do not grow a case that the coordinator is expected to
/// treat differently without revisiting the ⛔ on ``RevokeOutcome``: the moment
/// one deferral drops the credential, this enum has become the place the
/// fail-open lives.
public enum RevokeDeferral: Equatable, Sendable {
    /// HTTP 503. The route's write threw, so the row may be untouched and the
    /// token live for the rest of its 60-day window. The response carries a
    /// `Retry-After`; nothing here reads it, because the retry schedule is "the
    /// next cold start" and that is already slower.
    case serverUnavailable

    /// HTTP 429. The route rate-limits before it writes, so nothing was
    /// revoked.
    case rateLimited

    /// The request never reached the server at all — offline, DNS, a refused
    /// connection, a lost response.
    ///
    /// ⚠️ UNLIKE THE REFRESH PATH, `ProvablyUnsentError` IS NOT CONSULTED. That
    /// distinction exists so a refresh can tell an unspent token from a
    /// possibly-spent one; a revoke has no such distinction, because every
    /// failure to get an answer means the same thing here.
    case notSent

    /// A status this client does not model. Carried so it can be reported.
    case unexpected(status: Int)
}
