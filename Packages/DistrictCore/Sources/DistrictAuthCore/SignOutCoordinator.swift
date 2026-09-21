import Foundation

/// Sign-out: end the session on the server, then locally, and never lose the
/// credential in between.
///
/// ⛔ THE LOCAL WIPE HAPPENS REGARDLESS OF THE REVOKE'S RESULT. Those are two
/// separate decisions and both are deliberate. The server is asked FIRST because
/// the refresh token is the credential the revoke route authenticates with, so
/// it has to be read before ``TokenRefreshCoordinator/forget()`` destroys it —
/// afterwards there is nothing left to revoke WITH. It is wiped ANYWAY because
/// the user asked to sign out now: a device left looking signed in because a
/// server could not be reached is the worse of the two failures, and it is the
/// one the user can see.
///
/// ⛔ SO A FAILED REVOKE IS NOT DROPPED, IT IS DEFERRED. `POST
/// /api/auth/native/revoke` answers 503 when its database write threw, and the
/// route's header states the client's obligation plainly: keep the credential
/// and try again, because the server may honour that refresh token for the rest
/// of its 60-day life. Discarding it would strand a live credential nobody is
/// tracking, which is the exact fail-open that route was changed to stop
/// reporting as success.
///
/// ⛔ THE OUTBOX WRITE PRECEDES THE WIPE, AND `clear()` MUST SPARE THE OUTBOX.
/// Both halves are load-bearing and neither works alone. Writing the outbox
/// AFTER the revoke returns would leave a window in which process death loses
/// the only record of a live credential; writing it BEFORE only works because
/// ``TokenStore/clear()`` deliberately carries the slot across. See the ⛔ on
/// that method.
/// ⚠️ THIS IS ONE STEP STRICTER THAN `AppContainer.kt`, WHICH WRITES THE OUTBOX
/// ONLY ON A FAILED REVOKE. That leaves the crash window above open for the
/// duration of the network call, which is the longest part of a sign-out.
public struct SignOutCoordinator: Sendable {
    private let coordinator: TokenRefreshCoordinator
    private let store: any TokenStore
    private let revokeClient: any RevokeClient

    /// ⚠️ TAKES THE ONE ``TokenRefreshCoordinator``, NEVER BUILDS ONE. Two
    /// coordinators means two single-flight gates, either of which can present
    /// the same refresh token — see the ⛔ on that type.
    public init(
        coordinator: TokenRefreshCoordinator,
        store: any TokenStore,
        revokeClient: any RevokeClient
    ) {
        self.coordinator = coordinator
        self.store = store
        self.revokeClient = revokeClient
    }

    /// End the session: revoke server-side if possible, wipe locally always.
    ///
    /// ⚠️ A DEVICE WITH NO STORED SESSION IS A NO-OP FOR THE REVOKE HALF, NOT AN
    /// ERROR. Sign-out is reachable from a settings screen in states where the
    /// store is empty — after a Keychain failure, or a session the coordinator
    /// already cleared — and there is nothing to revoke with. The wipe still
    /// runs.
    ///
    /// ⛔ A THROWN STORE READ SKIPS THE REVOKE RATHER THAN ABORTING THE
    /// SIGN-OUT. A locked device cannot hand over the credential, so there is
    /// nothing to revoke WITH; refusing to sign out on that basis would leave
    /// the user staring at a signed-in app because their phone was locked a
    /// moment ago. ⚠️ The cost is real and is accepted: that session is not
    /// revoked and not recorded in the outbox either, because the token to
    /// record is exactly what could not be read. It expires on the server's own
    /// 60-day schedule.
    public func signOut() async {
        await revokeCurrentSession()
        await coordinator.forget()
    }

    /// Finish a sign-out whose revoke never reached the server.
    ///
    /// ⛔ CALLED ONCE PER LAUNCH, SIGNED IN OR NOT, AND EVERY OTHER TRIGGER IS
    /// WRONG. Something has to come back for a deferred entry, and each
    /// alternative hook is conditional on state a signed-out user no longer has:
    /// hanging it off login only fires if someone signs in again, and hanging it
    /// off the first token acquisition only fires when there IS a session, which
    /// is exactly what a signed-out device does not have. The token would sit
    /// there until a sign-in that may never come.
    ///
    /// ⚠️ COSTS ONE STORE READ IN THE NORMAL CASE. No network call is made
    /// unless there is genuinely a token to chase.
    ///
    /// ⚠️ NEVER THROWS AND MUST NEVER BLOCK THE UI. Every failure is a reason to
    /// try again on the next launch, and there is nothing a user could do with
    /// the news.
    ///
    /// ⚠️ IT CANNOT TOUCH THE CURRENT SESSION, WHICH IS WHAT MAKES RUNNING IT
    /// UNCONDITIONALLY SAFE. `revokeNativeSession` matches on the presented
    /// token's hash alone — not on its family and not on the user — so an entry
    /// written before a re-login revokes exactly the one dead row it names.
    ///
    /// ⚠️ ON A DEFERRAL THE ENTRY IS LEFT EXACTLY AS IT WAS. There is no attempt
    /// counter and no backoff: once per process start is already the slowest
    /// retry schedule available, and a counter would only add a way for the
    /// entry to be discarded while the credential is still live.
    public func drainPendingRevoke() async {
        guard let pending = try? await store.pendingRevokeToken(), !pending.isEmpty else { return }

        if await revokeClient.revoke(refreshToken: pending) == .accepted {
            try? await store.clearRevokePending()
        }
    }

    // ── Internals ────────────────────────────────────────────────────────────

    private func revokeCurrentSession() async {
        // ⛔ READ BEFORE ANYTHING WIPES IT. `forget()` clears the store, so this
        // is the last moment the credential exists on this device.
        guard let session = try? await store.read() else { return }

        // ⛔ DURABLE FIRST, THEN THE NETWORK. See the ⛔ on the type: the window
        // this closes is a process death between the revoke and the wipe.
        // ⚠️ A THROWN OUTBOX WRITE STILL SENDS THE REVOKE. This is the opposite
        // of `performRefresh`'s marker rule, and the asymmetry is the point: a
        // refresh sent without a durable marker can end in a family revocation,
        // so it must abort. A revoke sent without a durable outbox entry is
        // strictly better than not sending one — the worst case is the entry is
        // lost, which is exactly where the credential would be if we had skipped
        // the call.
        try? await store.markRevokePending(session.refreshToken)

        if await revokeClient.revoke(refreshToken: session.refreshToken) == .accepted {
            try? await store.clearRevokePending()
        }
        // ⚠️ ON A DEFERRAL THE OUTBOX IS LEFT SET, WHICH IS THE WHOLE MECHANISM.
        // No branch is needed to write it: it is already there.
    }
}
