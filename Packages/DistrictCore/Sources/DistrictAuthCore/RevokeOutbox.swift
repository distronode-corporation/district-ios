import Foundation

/// The one way a refresh token is handed to the server for revocation.
///
/// ⛔ SHARED BY ``SignOutCoordinator`` AND ``TokenRefreshCoordinator`` SO THE
/// OUTBOX RULES EXIST ONCE. A sign-out revokes the session it is ending; the
/// refresh coordinator revokes a successor that landed after the sign-out it
/// belonged to. Both have to leave a live credential tracked, and both share the
/// store's single outbox slot.
///
/// ⛔ THE SLOT IS DRAINED BEFORE IT IS OVERWRITTEN. ``TokenStore`` holds one
/// entry, and a second sign-out in the same process used to replace a deferred
/// first one, dropping a token the server was still honouring. The held entry is
/// therefore chased first. ⚠️ If it still will not drain, the newer token takes
/// the slot: one slot cannot hold two live credentials, and the newer one has
/// the longer remaining life on the server's sliding 60-day window.
struct RevokeOutbox: Sendable {
    let store: any TokenStore
    let client: any RevokeClient

    /// Chase the held entry, if there is one. See
    /// ``SignOutCoordinator/drainPendingRevoke()`` for why it never throws.
    func drain() async {
        guard let pending = try? await store.pendingRevokeToken(), !pending.isEmpty else { return }

        if await client.revoke(refreshToken: pending) == .accepted {
            try? await store.clearRevokePending()
        }
    }

    /// Revoke `refreshToken`, recording it in the outbox first.
    ///
    /// ⛔ DURABLE FIRST, THEN THE NETWORK: the window this closes is a process
    /// death between the revoke and whatever wipes the session next.
    /// ⚠️ A THROWN OUTBOX WRITE STILL SENDS THE REVOKE. This is the opposite of
    /// `performRefresh`'s marker rule, and the asymmetry is the point: a refresh
    /// sent without a durable marker can end in a family revocation, so it must
    /// abort. A revoke sent without a durable outbox entry is strictly better
    /// than not sending one; the worst case is the entry is lost, which is
    /// exactly where the credential would be if the call had been skipped.
    func revoke(_ refreshToken: String) async {
        await drain()
        try? await store.markRevokePending(refreshToken)

        if await client.revoke(refreshToken: refreshToken) == .accepted {
            try? await store.clearRevokePending()
        }
        // ⚠️ ON A DEFERRAL THE OUTBOX IS LEFT SET, WHICH IS THE WHOLE MECHANISM.
        // No branch is needed to write it: it is already there.
    }
}

/// The revoke client a ``TokenRefreshCoordinator`` uses when none is given.
///
/// ⚠️ IT DEFERS EVERYTHING, WHICH SENDS A LATE SUCCESSOR TO THE OUTBOX rather
/// than dropping it. The launch drain, which is built with a real client, then
/// finishes the job. Nothing goes over the network from here.
struct OutboxOnlyRevokeClient: RevokeClient {
    func revoke(refreshToken _: String) async -> RevokeOutcome {
        .deferred(.notSent)
    }
}
