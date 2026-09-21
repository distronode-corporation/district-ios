import Foundation

/// The single source of a usable access token.
///
/// ⛔ THE INVARIANT THIS ACTOR EXISTS TO PROTECT: A REFRESH TOKEN IS NEVER SENT
/// TWICE. The server's rotation is mandatory — `rotateNativeSession` claims the
/// presented row with an atomic `updateMany(where: { rotatedAt: nil })` and
/// mints a successor — and a token that arrives already-rotated is treated as
/// theft, because the server cannot tell a duplicated credential from a
/// retrying client. Its response is to revoke the entire `familyId` chain and
/// log `[auth] Native refresh replay detected`. Every plausible way of sending
/// the same token twice is closed here:
///
///   1. TWO CONCURRENT CALLERS. Two requests 401 at once, both refresh, both
///      present the same token. Closed by ``inFlight`` below (single-flight),
///      with a fast path so the common case does not serialise.
///   2. REACTING TO EXPIRY INSTEAD OF ANTICIPATING IT. Waiting for a 401
///      guarantees a thundering herd at the 10-minute boundary. Closed by
///      refreshing ``earlyRefreshMarginMilliseconds`` early.
///   3. PROCESS DEATH MID-REFRESH. The response is lost, the disk still holds a
///      token the server has rotated. Closed by the pending marker — see
///      ``TokenStore`` — which turns this into a deliberate re-login instead of
///      a false replay alarm.
///   4. PERSISTING THE SUCCESSOR TOO LATE. Closed by resolving the write BEFORE
///      the new access token becomes visible to any caller.
///   5. A FAILED WRITE DISCARDING THE SUCCESSOR. Closed by ``unpersistedSession``
///      — see ``adoptRotated(_:deviceId:)``.
///
/// ⛔ EXACTLY ONE OF THESE EXISTS PER PROCESS, HELD BY `AppContainer`. Two
/// coordinators means two single-flight gates, either of which can present the
/// same refresh token — failure mode 1 with the guard intact and useless. A test
/// constructs `AppContainer` precisely so this stays asserted.
///
/// ⚠️ THE SERVER ACCEPTS THAT CASE 3 SIGNS THE USER OUT, AND SO MUST THE UI.
/// There is no recovery: the client does not have the successor token and never
/// will. The server states the tradeoff explicitly — the alternative is
/// being unable to distinguish theft from packet loss and resolving it in the
/// attacker's favour. Design the re-login prompt for it rather than treating it
/// as an error.
///
/// ⚠️ AN ACTOR RATHER THAN A LOCK, AND THAT REMOVES A FIELD THE KOTLIN CLIENT
/// NEEDS. `TokenRefreshCoordinator.kt` carries a `refreshInFlight` flag because
/// its interrupted-refresh check runs both outside and inside its mutex, and the
/// outside copy misfires on its own concurrency. Here the check exists ONCE,
/// inside the single-flight task, so there is nothing for it to misfire on. Do
/// not "optimise" it back out to the fast path.
public actor TokenRefreshCoordinator {
    /// Refresh this far before the access token actually expires.
    ///
    /// 60s against a 10-minute TTL. Sized to cover a slow request plus the
    /// server's own clock-skew tolerance, without refreshing so eagerly that the
    /// effective token lifetime shrinks meaningfully.
    public static let earlyRefreshMarginMilliseconds: Int64 = 60000

    private let store: any TokenStore
    private let refreshClient: any RefreshClient
    private let now: @Sendable () -> Int64

    /// The access token, in memory ONLY, deliberately never persisted (see
    /// ``TokenStore``). Nil after a process restart, which simply means the next
    /// call refreshes.
    private var cachedAccessToken: String?
    private var cachedAccessTokenExpiresAt: Int64 = 0

    /// A successor the server has already minted and the store refused to keep.
    ///
    /// ⛔ WHEN THIS IS NON-NIL, THE COPY ON DISK IS THE SPENT PREDECESSOR AND
    /// MUST NOT BE READ. Presenting it is the replay that revokes the family.
    /// ``acquire()`` therefore prefers this over ``TokenStore/read()``.
    private var unpersistedSession: PersistedSession?

    /// The one refresh allowed to be outstanding. Concurrent callers await its
    /// value instead of starting their own.
    private var inFlight: Task<AccessTokenOutcome, Never>?

    public init(
        store: any TokenStore,
        refreshClient: any RefreshClient,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.store = store
        self.refreshClient = refreshClient
        self.now = now
    }

    /// True while a rotated pair exists only in memory. Diagnostic; see
    /// ``unpersistedSession``.
    public var hasUnpersistedSession: Bool {
        unpersistedSession != nil
    }

    /// A valid access token, refreshing if necessary.
    ///
    /// Callers must treat ``AccessTokenOutcome/reauthRequired(_:)`` as terminal:
    /// clear their state and route to login. Retrying will not help, and on
    /// ``ReauthReason/interruptedRefresh`` in particular a retry is exactly what
    /// would trigger the family revocation this avoided.
    ///
    /// ⛔ THE FAST PATH AND THE SINGLE-FLIGHT CHECK RUN WITH NO `await` BETWEEN
    /// THEM, WHICH IS WHAT MAKES THE COALESCING SOUND. An actor suspends at
    /// every `await` and admits another caller; inserting one here would let two
    /// callers both find ``inFlight`` nil and both start a refresh, presenting
    /// the same token twice.
    public func accessToken() async -> AccessTokenOutcome {
        if let token = cachedIfFresh() {
            return .available(token)
        }
        if let existing = inFlight {
            return await existing.value
        }

        let task = Task<AccessTokenOutcome, Never> { [self] in
            let outcome = await acquire()
            // Cleared HERE, inside the task, so it is already nil by the time any
            // awaiting caller resumes. Clearing it after `await task.value` in
            // each caller instead would leave a completed task installed for a
            // later arrival to latch onto.
            inFlight = nil
            return outcome
        }
        inFlight = task
        return await task.value
    }

    /// Adopt the tokens from a completed login or an initial code exchange.
    ///
    /// Resolves the write before the access token becomes visible, for the same
    /// ordering reason as a rotation.
    public func adopt(_ tokens: NativeTokens, deviceId: String) async {
        _ = await adoptRotated(tokens, deviceId: deviceId)
    }

    /// Discard the cached access token if it is still the one the caller used.
    ///
    /// ⛔ WITHOUT THIS, A SERVER-SIDE REVOCATION STRANDS THE APP FOR UP TO THE
    /// FULL ACCESS-TOKEN TTL. An access token is a stateless JWS, but the server
    /// checks revocation on every authenticated request (`requireAuth` →
    /// `isSessionRevoked`), so a password change, a password reset or an account
    /// deletion makes a signature-valid, unexpired token start answering 401.
    /// The fast path only consults the clock, so it would keep handing back that
    /// dead token for the remainder of its 10 minutes.
    ///
    /// ⛔ THE TOKEN ARGUMENT IS NOT DECORATION — it makes this safe under
    /// concurrency. Two requests can 401 together; the first invalidates and
    /// refreshes, the second then calls this with the OLD token and must not
    /// wipe the good one that just replaced it.
    ///
    /// - Returns: true if the cached token was actually discarded.
    @discardableResult
    public func invalidateAccessToken(_ token: String) -> Bool {
        guard cachedAccessToken == token else { return false }
        cachedAccessToken = nil
        cachedAccessTokenExpiresAt = 0
        return true
    }

    /// Local sign-out. The caller is responsible for
    /// `POST /api/auth/native/revoke`.
    ///
    /// ⛔ THE IN-MEMORY CREDENTIALS GO FIRST, BEFORE THE SUSPENDING DISK WIPE.
    /// Doing the disk work first would leave a window in which this actor still
    /// hands a live access token to a request racing the sign-out.
    public func forget() async {
        cachedAccessToken = nil
        cachedAccessTokenExpiresAt = 0
        unpersistedSession = nil
        try? await store.clear()
    }

    // ── Internals ────────────────────────────────────────────────────────────

    private func cachedIfFresh() -> String? {
        guard let token = cachedAccessToken else { return nil }
        return now() + Self.earlyRefreshMarginMilliseconds >= cachedAccessTokenExpiresAt ? nil : token
    }

    private func acquire() async -> AccessTokenOutcome {
        // ⛔ THE RESCUED SESSION WINS OVER THE DISK. See `unpersistedSession`.
        if let rescued = unpersistedSession {
            await repersistRescuedSession(rescued)
            return await performRefresh(rescued)
        }

        let stored: PersistedSession?
        do {
            stored = try await store.read()
        } catch {
            // ⛔ NOT A SIGN-OUT. A Keychain read fails transiently on a locked
            // device; reporting that as "no session" would sign the user out for
            // having locked their phone.
            return .retryLater(.storeUnavailable)
        }
        guard let current = stored else { return .reauthRequired(.noSession) }

        let pending: String?
        do {
            pending = try await store.pendingRefreshToken()
        } catch {
            return .retryLater(.storeUnavailable)
        }

        // ── The interrupted-refresh check ────────────────────────────────────
        // If the marker names the token still on disk, a previous refresh was
        // sent and its response never landed, so this token is already spent
        // server-side. Sending it would revoke the family and produce a security
        // warning describing an attack that did not happen.
        if let pending, pending == current.refreshToken {
            try? await store.clear()
            return .reauthRequired(.interruptedRefresh)
        }

        if now() >= current.refreshTokenExpiresAt {
            try? await store.clear()
            return .reauthRequired(.refreshTokenExpired)
        }

        // ⛔ THE CACHE IS RE-CHECKED HERE, AFTER THE STORE READS, AND NOT BEFORE
        // THEM. The Kotlin client puts its equivalent double-check at the top of
        // the locked section because callers queue on a mutex and each one
        // re-runs the body; here they await one shared task and never re-enter,
        // so a check at the top of this function is dead code. What IS live is
        // the window opened by the two `await`s above: a login completing beside
        // this refresh can `adopt` a freshly minted pair, and refreshing anyway
        // would spend a rotation of a credential seconds old for nothing.
        if let token = cachedIfFresh() {
            return .available(token)
        }

        return await performRefresh(current)
    }

    /// Try again to write a successor an earlier rotation could not persist.
    ///
    /// Best effort: if it still fails, the in-memory copy stays authoritative
    /// and the marker stays set, which is exactly the state
    /// ``adoptRotated(_:deviceId:)`` left behind.
    private func repersistRescuedSession(_ rescued: PersistedSession) async {
        do {
            try await store.write(rescued)
            try? await store.clearRefreshPending()
            unpersistedSession = nil
        } catch {
            // Deliberately silent. The next refresh carries the same rescue.
        }
    }

    private func performRefresh(_ current: PersistedSession) async -> AccessTokenOutcome {
        // ⛔ MARKER BEFORE NETWORK, AND A FAILED MARKER ABORTS RATHER THAN FALLS
        // THROUGH. A refresh sent without a durable marker is precisely the
        // crash window the marker exists to close: the successor would be
        // unrecoverable and the next launch would present a spent token and be
        // told it is a thief. A skipped mutation must abort, never fall through
        // to the action.
        do {
            try await store.markRefreshPending(current.refreshToken)
        } catch {
            return .retryLater(.markerNotDurable)
        }

        switch await refreshClient.refresh(refreshToken: current.refreshToken) {
        case let .success(tokens):
            return await adoptRotated(tokens, deviceId: current.deviceId)

        case .rejected:
            try? await store.clear()
            unpersistedSession = nil
            cachedAccessToken = nil
            cachedAccessTokenExpiresAt = 0
            return .reauthRequired(.refreshRejected)

        case .rateLimited:
            // ⛔ The token was NOT consumed — the server rate-limits before
            // rotating — so the marker MUST be cleared. Leaving it set would
            // make the next attempt report `interruptedRefresh` and sign the
            // user out over a transient 429.
            try? await store.clearRefreshPending()
            return .retryLater(.refreshThrottled)

        case .notSent:
            // ⛔ The request never left the device, so the token is provably
            // unspent. Handled exactly like the 429 above.
            try? await store.clearRefreshPending()
            return .retryLater(.refreshNotSent)

        case .transportFailure:
            // ⚠️ The marker is deliberately LEFT SET. The request may have
            // reached the server and rotated the token even though the response
            // did not arrive — indistinguishable from here. Clearing it would
            // let a later attempt present the possibly-spent token and revoke
            // the family. Leaving it set costs a re-login in the ambiguous case.
            return .reauthRequired(.refreshUnreachable)
        }
    }

    /// Store a freshly minted pair and expose its access token.
    ///
    /// ⛔ THE WRITE IS RESOLVED BEFORE THE ACCESS TOKEN IS EXPOSED. Returning
    /// first and writing after leaves a window where the app makes authenticated
    /// requests against a refresh token that exists only in memory and nothing
    /// has yet tried to save.
    ///
    /// ⛔ A FAILED WRITE DOES NOT DISCARD THE PAIR, AND THAT IS THE WHOLE REASON
    /// THIS IS NOT `try await store.write(...)` WITH THE ERROR PROPAGATED. The
    /// predecessor is already spent server-side, so the successor held here is
    /// the ONLY credential that can still refresh this session — dropping it on
    /// a transient Keychain failure would convert "the device was locked for a
    /// moment" into a permanent sign-out. It is kept in memory, the session
    /// keeps working for the life of the process, and every later refresh
    /// retries the write.
    ///
    /// ⚠️ AND THE MARKER IS LEFT SET ON THAT PATH, WHICH IS WHAT MAKES IT SAFE
    /// ACROSS A CRASH. Disk then holds the spent predecessor plus a marker
    /// naming it, so the next launch takes the `interruptedRefresh` path and
    /// re-logs in cleanly instead of presenting a spent token.
    private func adoptRotated(_ tokens: NativeTokens, deviceId: String) async -> AccessTokenOutcome {
        let successor = PersistedSession(
            refreshToken: tokens.refreshToken,
            refreshTokenExpiresAt: tokens.refreshTokenExpiresAt,
            deviceId: deviceId
        )
        do {
            try await store.write(successor)
            try? await store.clearRefreshPending()
            unpersistedSession = nil
        } catch {
            unpersistedSession = successor
        }
        cachedAccessToken = tokens.accessToken
        cachedAccessTokenExpiresAt = tokens.accessTokenExpiresAt
        return .available(tokens.accessToken)
    }
}

/// The result of asking for an access token.
public enum AccessTokenOutcome: Sendable, Equatable {
    case available(String)

    /// Terminal. Route to login; do not retry.
    case reauthRequired(ReauthReason)

    /// Transient. The session is intact and the stored token is still valid.
    /// Fail the in-flight request, keep the user signed in, try again later.
    ///
    /// ⛔ DO NOT TREAT THIS AS A SIGN-OUT. That is the entire reason it is a
    /// separate case rather than another ``ReauthReason``.
    case retryLater(RetryReason)
}

/// Why the session ended.
public enum ReauthReason: Sendable, Equatable {
    /// Never signed in, or signed out locally.
    case noSession

    /// A refresh was in flight when the process died. The stored token is
    /// presumed spent. ⚠️ NOT A SECURITY EVENT — see ``TokenStore``.
    case interruptedRefresh

    /// The 60-day sliding window elapsed without the app being opened.
    case refreshTokenExpired

    /// The server refused the token: unknown, expired, revoked, or replayed.
    /// Indistinguishable by design.
    case refreshRejected

    /// The refresh could not be delivered, or its response was lost. The next
    /// attempt reports ``interruptedRefresh`` because the marker is
    /// intentionally still set.
    case refreshUnreachable
}

/// Why the caller should try again rather than sign out.
public enum RetryReason: Sendable, Equatable {
    /// HTTP 429 from the refresh route. The token was never consumed.
    case refreshThrottled

    /// The refresh request provably never left the device.
    case refreshNotSent

    /// The token store could not be read — a locked device, typically. The
    /// session is intact; this says nothing about whether one exists.
    case storeUnavailable

    /// The pending-refresh marker could not be written durably, so no refresh
    /// was sent. ⛔ Sending one anyway is the fall-through this case exists to
    /// refuse.
    case markerNotDurable
}
