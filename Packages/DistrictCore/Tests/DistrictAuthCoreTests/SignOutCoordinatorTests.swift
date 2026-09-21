@testable import DistrictAuthCore
import Foundation
import XCTest

/// The sign-out path, and the outbox that makes it survive a 503.
///
/// ⛔ THE PROPERTY UNDER TEST IS "NO LIVE CREDENTIAL IS EVER UNTRACKED". Every
/// case here is one way that could go wrong: the wipe running before the read,
/// the outbox being written after the wipe, `clear()` taking the outbox with it,
/// or a deferral being mistaken for a success.
final class SignOutCoordinatorTests: XCTestCase {
    private func makeCoordinator(
        store: some TokenStore,
        revoke: some RevokeClient
    ) -> (SignOutCoordinator, TokenRefreshCoordinator) {
        let refresh = TokenRefreshCoordinator(
            store: store,
            refreshClient: NeverRefreshClient(),
            now: { AuthFixtures.now }
        )
        let signOut = SignOutCoordinator(coordinator: refresh, store: store, revokeClient: revoke)
        return (signOut, refresh)
    }

    // MARK: - signOut

    /// The happy path: the server accepted, so nothing is left to chase.
    func testAnAcceptedRevokeClearsTheOutboxAndForgets() async {
        let store = SpyTokenStore(session: AuthFixtures.session())
        let client = ScriptedRevokeClient(script: [.accepted])
        let (signOut, _) = makeCoordinator(store: store, revoke: client)

        await signOut.signOut()

        await expectEqual(["refresh-1"]) { await client.presented }
        await expectNil { await store.revokePending }
        await expectNil { await store.session }
        await expectEqual(1) { await store.clears }
    }

    /// ⛔ A 503 LEAVES THE OUTBOX AND STILL WIPES. Both halves matter: the user
    /// asked to sign out now (a device that still looks signed in is the worse,
    /// and the visible, failure), and the server may honour that refresh token
    /// for the rest of its 60-day window, so the credential has to stay tracked.
    func testA503LeavesTheOutboxAndStillForgets() async {
        let store = SpyTokenStore(session: AuthFixtures.session())
        let client = ScriptedRevokeClient(script: [.deferred(.serverUnavailable)])
        let (signOut, refresh) = makeCoordinator(store: store, revoke: client)

        await signOut.signOut()

        await expectEqual("refresh-1") { await store.revokePending }
        await expectNil { await store.session }
        await expectEqual(1) { await store.clears }
        // The session really is over: the coordinator has nothing left to hand out.
        await expectEqual(AccessTokenOutcome.reauthRequired(.noSession)) { await refresh.accessToken() }
    }

    /// ⚠️ EVERY DEFERRAL BEHAVES THE SAME WAY, which is what makes
    /// ``RevokeDeferral`` diagnostic rather than a branch. A case that started
    /// dropping the credential would be the fail-open this whole path exists to
    /// prevent, so all four are walked rather than one being taken as
    /// representative.
    func testEveryDeferralKeepsTheCredential() async {
        let deferrals: [RevokeDeferral] = [
            .serverUnavailable,
            .rateLimited,
            .notSent,
            .unexpected(status: 418),
        ]

        for deferral in deferrals {
            let store = SpyTokenStore(session: AuthFixtures.session())
            let client = ScriptedRevokeClient(script: [.deferred(deferral)])
            let (signOut, _) = makeCoordinator(store: store, revoke: client)

            await signOut.signOut()

            await expectEqual("refresh-1", "\(deferral)") { await store.revokePending }
            await expectNil("\(deferral)") { await store.session }
        }
    }

    /// ⛔ THE ORDERING ASSERTION, AND IT CANNOT BE MADE FROM END STATE ALONE.
    /// "Outbox written, session gone" is true whichever order the two happened
    /// in; only the sequence distinguishes them, and the wrong sequence leaves a
    /// window in which process death loses the only record of a live credential.
    ///
    /// ⚠️ THE READ IS FIRST FOR A SEPARATE REASON: `clear()` destroys the
    /// credential the revoke route authenticates WITH, so a wipe-first sign-out
    /// has nothing left to revoke.
    func testTheOutboxWriteHappensBeforeTheWipe() async {
        let store = SpyTokenStore(session: AuthFixtures.session())
        let client = ScriptedRevokeClient(script: [.deferred(.serverUnavailable)])
        let (signOut, _) = makeCoordinator(store: store, revoke: client)

        await signOut.signOut()

        await expectEqual([.read, .markRevokePending, .clear]) { await store.operations }
    }

    /// ⛔ AND ON THE ACCEPTED PATH THE OUTBOX IS CLEARED BEFORE THE WIPE TOO, so
    /// there is no moment at which a crash would leave an entry for a token the
    /// server has already forgotten. ⚠️ A stale entry is harmless (the drain
    /// would get one 200 and clear it), but an unnecessary network call on a
    /// later launch is still worth not making.
    func testTheAcceptedPathClearsTheOutboxBeforeTheWipe() async {
        let store = SpyTokenStore(session: AuthFixtures.session())
        let client = ScriptedRevokeClient(script: [.accepted])
        let (signOut, _) = makeCoordinator(store: store, revoke: client)

        await signOut.signOut()

        await expectEqual([.read, .markRevokePending, .clearRevokePending, .clear]) {
            await store.operations
        }
    }

    /// ⛔ A THROWN READ SKIPS THE REVOKE AND STILL FORGETS. A locked device
    /// cannot hand over the credential, so there is nothing to revoke WITH;
    /// refusing to sign out on that basis would leave the user staring at a
    /// signed-in app because their phone was locked a moment ago.
    ///
    /// ⚠️ NOTHING IS WRITTEN TO THE OUTBOX EITHER, and that is not an oversight:
    /// the token to record is exactly what could not be read.
    func testAThrowingReadSkipsTheRevokeAndStillForgets() async {
        let store = SpyTokenStore(session: AuthFixtures.session())
        await store.failReads(true)
        let client = NeverRevokeClient()
        let (signOut, _) = makeCoordinator(store: store, revoke: client)

        await signOut.signOut()

        await expectEqual(0) { await client.callCount }
        await expectEqual(1) { await store.clears }
        await expectNil { await store.revokePending }
    }

    /// ⚠️ A DEVICE WITH NO STORED SESSION IS A NO-OP FOR THE REVOKE HALF, NOT AN
    /// ERROR. Sign-out is reachable from a settings screen in states where the
    /// store is already empty, and the wipe still has to run.
    func testAnEmptyStoreSignsOutWithoutCallingTheServer() async {
        let store = SpyTokenStore()
        let client = NeverRevokeClient()
        let (signOut, _) = makeCoordinator(store: store, revoke: client)

        await signOut.signOut()

        await expectEqual(0) { await client.callCount }
        await expectEqual(1) { await store.clears }
    }

    /// ⛔ A FAILED OUTBOX WRITE STILL SENDS THE REVOKE, which is the OPPOSITE of
    /// `performRefresh`'s marker rule, and the asymmetry is deliberate. A
    /// refresh sent without a durable marker can end in a family revocation, so
    /// it must abort. A revoke sent without a durable outbox entry is strictly
    /// better than not sending one: the worst case is the entry is lost, which
    /// is exactly where the credential would be if the call had been skipped.
    func testAFailedOutboxWriteStillSendsTheRevoke() async {
        let store = SpyTokenStore(session: AuthFixtures.session())
        await store.failRevokeMarkerWrites(true)
        let client = ScriptedRevokeClient(script: [.accepted])
        let (signOut, _) = makeCoordinator(store: store, revoke: client)

        await signOut.signOut()

        await expectEqual(["refresh-1"]) { await client.presented }
        await expectEqual(1) { await store.clears }
    }

    // MARK: - drainPendingRevoke

    /// The drain's happy path: the entry is chased and cleared.
    func testDrainingAnAcceptedEntryClearsIt() async {
        let store = SpyTokenStore(revokePending: "stranded-token")
        let client = ScriptedRevokeClient(script: [.accepted])
        let (signOut, _) = makeCoordinator(store: store, revoke: client)

        await signOut.drainPendingRevoke()

        await expectEqual(["stranded-token"]) { await client.presented }
        await expectNil { await store.revokePending }
    }

    /// ⚠️ ON A DEFERRAL THE ENTRY IS LEFT EXACTLY AS IT WAS. No attempt counter
    /// and no backoff: once per process start is already the slowest retry
    /// schedule available, and a counter would only add a way for the entry to
    /// be discarded while the credential is still live.
    func testDrainingADeferredEntryLeavesIt() async {
        let store = SpyTokenStore(revokePending: "stranded-token")
        let client = ScriptedRevokeClient(script: [.deferred(.serverUnavailable)])
        let (signOut, _) = makeCoordinator(store: store, revoke: client)

        await signOut.drainPendingRevoke()

        await expectEqual("stranded-token") { await store.revokePending }
    }

    /// ⚠️ THE NORMAL CASE COSTS ONE STORE READ AND MAKES NO NETWORK CALL. This
    /// runs on every cold start, signed in or not, so "empty is free" is what
    /// makes that affordable.
    func testDrainingAnEmptyOutboxMakesNoCall() async {
        let store = SpyTokenStore()
        let client = NeverRevokeClient()
        let (signOut, _) = makeCoordinator(store: store, revoke: client)

        await signOut.drainPendingRevoke()

        await expectEqual(0) { await client.callCount }
        await expectEqual([.readRevoke]) { await store.operations }
    }

    /// ⛔ NEVER THROWS. A store that cannot be read is a reason to try again on
    /// the next launch, not a reason to propagate — there is nothing a user
    /// could do with the news, and this runs behind the first render.
    func testDrainingSwallowsAThrownRead() async {
        let store = SpyTokenStore(revokePending: "stranded-token")
        await store.failReads(true)
        let client = NeverRevokeClient()
        let (signOut, _) = makeCoordinator(store: store, revoke: client)

        await signOut.drainPendingRevoke()

        await expectEqual(0) { await client.callCount }
        await expectEqual("stranded-token") { await store.revokePending }
    }

    /// ⚠️ AN EMPTY STRING IS NOT AN ENTRY. `RevokeSchema` is
    /// `z.string().min(1)`, so posting one would be a guaranteed 400 that the
    /// strict status map turns into a permanent outbox entry.
    func testAnEmptyOutboxStringIsNotChased() async {
        let store = SpyTokenStore(revokePending: "")
        let client = NeverRevokeClient()
        let (signOut, _) = makeCoordinator(store: store, revoke: client)

        await signOut.drainPendingRevoke()

        await expectEqual(0) { await client.callCount }
    }

    /// ⛔ A STALE ENTRY CANNOT TOUCH THE CURRENT SESSION, which is what makes
    /// running the drain unconditionally at launch safe. `revokeNativeSession`
    /// matches on the presented token's hash alone — not on its family and not
    /// on the user — so an entry written before a re-login revokes exactly the
    /// one dead row it names. Asserted from this side as: the drain presents the
    /// OUTBOX token, never the session's, and never touches the session.
    func testTheDrainNeverPresentsOrDisturbsTheCurrentSession() async {
        let live = AuthFixtures.session(refreshToken: "new-session-token")
        let store = SpyTokenStore(session: live, revokePending: "old-dead-token")
        let client = ScriptedRevokeClient(script: [.accepted])
        let (signOut, _) = makeCoordinator(store: store, revoke: client)

        await signOut.drainPendingRevoke()

        await expectEqual(["old-dead-token"]) { await client.presented }
        await expectEqual(Optional(live)) { await store.session }
        await expectEqual(0) { await store.clears }
    }
}

/// The invariant the whole outbox rests on, asserted on the shipped fake.
///
/// ⛔ `InMemoryTokenStore` SHIPS IN `Sources/` AND IS THE STORE OTHER MODULES'
/// SUITES BUILD A COORDINATOR WITH, so if its `clear()` took the outbox with it,
/// every one of those suites would be rehearsing a store that loses what the
/// production one keeps. See the ⛔ on ``TokenStore/clear()``.
final class InMemoryTokenStoreOutboxTests: XCTestCase {
    func testClearSparesTheRevokeOutbox() async throws {
        let store = InMemoryTokenStore(session: AuthFixtures.session())
        try await store.markRefreshPending("refresh-1")
        try await store.markRevokePending("to-be-revoked")

        try await store.clear()

        await expectNil("the session goes") { try? await store.read() }
        await expectNil("the refresh marker goes with it") { try? await store.pendingRefreshToken() }
        await expectEqual("to-be-revoked", "the outbox SURVIVES") {
            try? await store.pendingRevokeToken()
        }
    }

    /// The mirror: an accepted revoke really does empty it.
    func testClearRevokePendingEmptiesTheOutbox() async throws {
        let store = InMemoryTokenStore()
        try await store.markRevokePending("to-be-revoked")

        try await store.clearRevokePending()

        await expectNil { try? await store.pendingRevokeToken() }
    }

    /// ⚠️ A FRESH STORE HAS NO OUTBOX ENTRY, which is the state every launch
    /// that has never signed out is in.
    func testAFreshStoreHasNoOutboxEntry() async {
        let store = InMemoryTokenStore()

        await expectNil { try? await store.pendingRevokeToken() }
    }
}
