@testable import DistrictAuthCore
import Foundation
import XCTest

/// A sign-out that lands while a refresh is on the wire.
///
/// ⛔ THE PROPERTY UNDER TEST IS "SIGNED OUT STAYS SIGNED OUT". The refresh was
/// sent with the old session's token and the server will answer with a live
/// successor whatever the device did in the meantime. Before the generation
/// fence, that answer was written back to the store and its access token cached,
/// so a device the user had just signed out of was signed in again on its next
/// cold start, with a refresh token nothing would ever revoke.
final class SignOutDuringRefreshTests: XCTestCase {
    private struct Harness {
        let store: SpyTokenStore
        let refresh: ScriptedRefreshClient
        let revoke: ScriptedRevokeClient
        let coordinator: TokenRefreshCoordinator
        let signOut: SignOutCoordinator
    }

    private func makeHarness(revokeScript: [RevokeOutcome] = []) -> Harness {
        let store = SpyTokenStore(session: AuthFixtures.session())
        let refresh = ScriptedRefreshClient(script: [.success(AuthFixtures.tokens(index: 2))], open: false)
        let revoke = ScriptedRevokeClient(script: revokeScript)
        let coordinator = TokenRefreshCoordinator(
            store: store,
            refreshClient: refresh,
            revokeClient: revoke,
            now: { AuthFixtures.now }
        )
        let signOut = SignOutCoordinator(coordinator: coordinator, store: store, revokeClient: revoke)
        return Harness(store: store, refresh: refresh, revoke: revoke, coordinator: coordinator, signOut: signOut)
    }

    func testARefreshLandingAfterSignOutWritesNothingAndRevokesItsSuccessor() async {
        let harness = makeHarness()
        let request = Task { await harness.coordinator.accessToken() }
        await waitUntil { await harness.refresh.callCount >= 1 }

        await harness.signOut.signOut()
        await harness.refresh.open()

        await expectEqual(AccessTokenOutcome.reauthRequired(.noSession)) { await request.value }
        await expectNil("the successor must not reach the store") { await harness.store.session }
        await expectEqual(AccessTokenOutcome.reauthRequired(.noSession), "nor the cache") {
            await harness.coordinator.accessToken()
        }
        await expectEqual(["refresh-1", "refresh-2"], "the successor is revoked, not stranded") {
            await harness.revoke.presented
        }
        await expectNil { await harness.store.revokePending }
    }

    /// ⚠️ A DEFERRED REVOKE OF THE SUCCESSOR GOES TO THE OUTBOX, so the next
    /// launch's drain chases it like any other sign-out's credential.
    func testADeferredSuccessorRevokeIsLeftInTheOutbox() async {
        let harness = makeHarness(revokeScript: [.accepted, .deferred(.serverUnavailable)])
        let request = Task { await harness.coordinator.accessToken() }
        await waitUntil { await harness.refresh.callCount >= 1 }

        await harness.signOut.signOut()
        await harness.refresh.open()
        _ = await request.value

        await expectEqual("refresh-2") { await harness.store.revokePending }
        await expectNil { await harness.store.session }
    }

    /// ⛔ THE SINGLE-FLIGHT GATE IS RELEASED BY THE SIGN-OUT, AND THE ABANDONED
    /// TASK MUST NOT RELEASE A SUCCESSOR'S. A login after the sign-out is a new
    /// session; a caller that latched onto the old refresh would be handed the
    /// abandoned outcome, and the old task clearing `inFlight` on its way out
    /// would let two refreshes of the NEW session run at once.
    func testANewSessionDoesNotWaitOnOrLoseItsGateToTheAbandonedRefresh() async {
        let store = SpyTokenStore(session: AuthFixtures.session())
        let refresh = ScriptedRefreshClient(
            script: [.success(AuthFixtures.tokens(index: 2)), .success(AuthFixtures.tokens(index: 4))],
            open: false
        )
        let coordinator = TokenRefreshCoordinator(store: store, refreshClient: refresh, now: { AuthFixtures.now })
        let stale = Task { await coordinator.accessToken() }
        await waitUntil { await refresh.callCount >= 1 }

        await coordinator.forget()
        // A new login whose access token is already due, so the next call refreshes.
        await coordinator.adopt(AuthFixtures.tokens(index: 3, accessLifetime: 0), deviceId: "device-abc")
        let fresh = Task { await coordinator.accessToken() }
        await waitUntil { await refresh.callCount >= 2 }
        await refresh.open()

        await expectEqual(AccessTokenOutcome.reauthRequired(.noSession)) { await stale.value }
        await expectEqual(AccessTokenOutcome.available("access-4")) { await fresh.value }
        await expectEqual(["refresh-1", "refresh-3"]) { await refresh.presented }
        await expectEqual("refresh-4") { await store.session?.refreshToken }
    }

    /// ⛔ A STALE ANSWER OF ANY KIND LEAVES THE STORE ALONE. A rejection used to
    /// clear it, which after a sign-out and a fresh login would wipe the session
    /// that replaced the one the refresh was sent for.
    func testAStaleRejectionDoesNotWipeTheSessionThatReplacedIt() async {
        let store = SpyTokenStore(session: AuthFixtures.session())
        let refresh = ScriptedRefreshClient(script: [.rejected], open: false)
        let coordinator = TokenRefreshCoordinator(store: store, refreshClient: refresh, now: { AuthFixtures.now })
        let request = Task { await coordinator.accessToken() }
        await waitUntil { await refresh.callCount >= 1 }

        await coordinator.forget()
        await coordinator.adopt(AuthFixtures.tokens(index: 5), deviceId: "device-abc")
        await refresh.open()

        await expectEqual(AccessTokenOutcome.reauthRequired(.noSession)) { await request.value }
        await expectEqual("refresh-5", "a stale rejection must not wipe the session that replaced it") {
            await store.session?.refreshToken
        }
    }

    /// ⚠️ WITH NO REVOKE CLIENT THE SUCCESSOR STILL GOES TO THE OUTBOX. The default
    /// defers every revoke, which is the conservative answer: the launch drain,
    /// which does have a client, finishes the job.
    func testWithoutARevokeClientALateSuccessorIsQueuedForTheDrain() async {
        let store = SpyTokenStore(session: AuthFixtures.session())
        let refresh = ScriptedRefreshClient(script: [.success(AuthFixtures.tokens(index: 2))], open: false)
        let coordinator = TokenRefreshCoordinator(store: store, refreshClient: refresh, now: { AuthFixtures.now })
        let request = Task { await coordinator.accessToken() }
        await waitUntil { await refresh.callCount >= 1 }

        await coordinator.forget()
        await refresh.open()
        _ = await request.value

        await expectEqual("refresh-2") { await store.revokePending }
        await expectNil { await store.session }
    }
}

/// A second sign-out in one process while the first one's revoke is still owed.
///
/// ⛔ THE OUTBOX IS ONE SLOT. Before the drain-first rule, the second sign-out's
/// outbox write replaced the first one's entry, and that token (still live on
/// the server, which is why it was in the outbox) was never presented again.
final class SignOutOutboxOverwriteTests: XCTestCase {
    func testASecondSignOutChasesTheHeldEntryBeforeReplacingIt() async {
        let store = InMemoryTokenStore(session: AuthFixtures.session(refreshToken: "X"))
        let refresh = TokenRefreshCoordinator(
            store: store,
            refreshClient: NeverRefreshClient(),
            now: { AuthFixtures.now }
        )
        let revoke = ScriptedRevokeClient(script: [.deferred(.serverUnavailable), .accepted, .accepted])
        let signOut = SignOutCoordinator(coordinator: refresh, store: store, revokeClient: revoke)

        await signOut.signOut()
        await expectEqual("X") { try? await store.pendingRevokeToken() }
        await refresh.adopt(AuthFixtures.tokens(index: 9), deviceId: "device-abc")
        await signOut.signOut()

        await expectEqual(["X", "X", "refresh-9"]) { await revoke.presented }
        await expectNil { try? await store.pendingRevokeToken() }
    }

    /// ⚠️ WHEN THE HELD ENTRY STILL WILL NOT DRAIN, THE NEWER TOKEN TAKES THE SLOT.
    /// One slot cannot hold two live credentials; the newer one has the longer
    /// remaining life on the server's sliding 60-day window, so it is the one
    /// worth keeping.
    func testWhenBothDeferTheNewerTokenIsKept() async {
        let store = SpyTokenStore(session: AuthFixtures.session(refreshToken: "newer"), revokePending: "older")
        let refresh = TokenRefreshCoordinator(
            store: store,
            refreshClient: NeverRefreshClient(),
            now: { AuthFixtures.now }
        )
        let revoke = ScriptedRevokeClient(fallback: .deferred(.serverUnavailable))
        let signOut = SignOutCoordinator(coordinator: refresh, store: store, revokeClient: revoke)

        await signOut.signOut()

        await expectEqual(["older", "newer"]) { await revoke.presented }
        await expectEqual("newer") { await store.revokePending }
    }
}
