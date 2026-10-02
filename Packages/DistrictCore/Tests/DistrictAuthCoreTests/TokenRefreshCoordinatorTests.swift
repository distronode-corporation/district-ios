@testable import DistrictAuthCore
import Foundation
import XCTest

/// Rotation semantics, failure classification, and the store-boundary rules.
/// Concurrency lives in `TokenRefreshConcurrencyTests`.
final class TokenRefreshCoordinatorTests: XCTestCase {
    private func makeCoordinator(
        store: SpyTokenStore,
        client: any RefreshClient,
        clock: TestClock
    ) -> TokenRefreshCoordinator {
        TokenRefreshCoordinator(store: store, refreshClient: client, now: clock.now)
    }

    // ── The happy path and its ordering ──────────────────────────────────────

    func testRefreshesAndPersistsTheSuccessorBeforeReturningIt() async {
        let clock = TestClock(AuthFixtures.now)
        let store = SpyTokenStore(session: AuthFixtures.session())
        let client = ScriptedRefreshClient(script: [.success(AuthFixtures.tokens(index: 2))])
        let coordinator = makeCoordinator(store: store, client: client, clock: clock)

        let outcome = await coordinator.accessToken()

        XCTAssertEqual(outcome, .available("access-2"))
        // ⛔ The successor is on disk by the time the access token is visible.
        let persisted = await store.session
        XCTAssertEqual(persisted?.refreshToken, "refresh-2")
        // The device id survives the rotation: the server scopes sign-outs by it
        // and the refresh response does not echo it back.
        XCTAssertEqual(persisted?.deviceId, "device-abc")
        let marker = await store.pending
        XCTAssertNil(marker, "the marker must be cleared once the successor is durable")
    }

    func testMarksThePendingTokenBeforeSendingIt() async {
        let clock = TestClock(AuthFixtures.now)
        let store = SpyTokenStore(session: AuthFixtures.session())
        // Held open so the marker can be observed while the request is in flight.
        let client = ScriptedRefreshClient(script: [.success(AuthFixtures.tokens(index: 2))], open: false)
        let coordinator = makeCoordinator(store: store, client: client, clock: clock)

        let task = Task { await coordinator.accessToken() }
        await waitUntil { await client.callCount == 1 }

        let markerWhileInFlight = await store.pending
        XCTAssertEqual(markerWhileInFlight, "refresh-1", "the marker must be durable BEFORE the network call")

        await client.open()
        _ = await task.value
    }

    func testServesTheCachedTokenWithoutTouchingTheStore() async {
        let clock = TestClock(AuthFixtures.now)
        let store = SpyTokenStore(session: AuthFixtures.session())
        let client = ScriptedRefreshClient(script: [.success(AuthFixtures.tokens(index: 2))])
        let coordinator = makeCoordinator(store: store, client: client, clock: clock)

        _ = await coordinator.accessToken()
        let readsAfterFirst = await store.reads
        _ = await coordinator.accessToken()
        _ = await coordinator.accessToken()

        await expectEqual(readsAfterFirst, "the fast path must not read the store") { await store.reads }
        await expectEqual(1) { await client.callCount }
    }

    func testRefreshesEarlyRatherThanWaitingForExpiry() async {
        let clock = TestClock(AuthFixtures.now)
        let store = SpyTokenStore(session: AuthFixtures.session())
        let client = ScriptedRefreshClient(script: [
            .success(AuthFixtures.tokens(index: 2)),
            .success(AuthFixtures.tokens(index: 3, at: AuthFixtures.now + 9 * 60 * 1000)),
        ])
        let coordinator = makeCoordinator(store: store, client: client, clock: clock)

        await expectEqual(.available("access-2")) { await coordinator.accessToken() }
        // 9 minutes in: 60 seconds of a 10-minute token remain, which is exactly
        // the early margin. ⛔ Waiting for the real expiry guarantees a
        // thundering herd at the boundary.
        clock.advance(by: 9 * 60 * 1000)
        await expectEqual(.available("access-3")) { await coordinator.accessToken() }
        await expectEqual(2) { await client.callCount }
    }

    func testEachRotationPresentsTheSuccessorAndNeverAPredecessor() async {
        let clock = TestClock(AuthFixtures.now)
        let store = SpyTokenStore(session: AuthFixtures.session())
        let client = ScriptedRefreshClient(script: (2 ... 6).map { index in
            .success(AuthFixtures.tokens(index: index, at: AuthFixtures.now + Int64(index) * 20 * 60 * 1000))
        })
        let coordinator = makeCoordinator(store: store, client: client, clock: clock)

        for index in 2 ... 6 {
            clock.millis = AuthFixtures.now + Int64(index) * 20 * 60 * 1000
            await expectEqual(.available("access-\(index)")) { await coordinator.accessToken() }
        }

        // ⛔ THE ASSERTION THE WHOLE MODULE EXISTS FOR: no value appears twice.
        let presented = await client.presented
        XCTAssertEqual(presented, ["refresh-1", "refresh-2", "refresh-3", "refresh-4", "refresh-5"])
        XCTAssertEqual(Set(presented).count, presented.count)
        let finalSession = await store.session
        XCTAssertEqual(finalSession?.refreshToken, "refresh-6")
    }

    // ── Failure classification ───────────────────────────────────────────────

    func testDefinitive401SignsTheUserOutAndDiscardsTheSession() async {
        let clock = TestClock(AuthFixtures.now)
        let store = SpyTokenStore(session: AuthFixtures.session())
        let client = ScriptedRefreshClient(script: [.rejected])
        let coordinator = makeCoordinator(store: store, client: client, clock: clock)

        await expectEqual(.reauthRequired(.refreshRejected)) { await coordinator.accessToken() }
        let session = await store.session
        XCTAssertNil(session, "a rejected credential must not be kept")
    }

    func testRateLimitIsRetryableAndKeepsTheSession() async {
        let clock = TestClock(AuthFixtures.now)
        let store = SpyTokenStore(session: AuthFixtures.session())
        let client = ScriptedRefreshClient(script: [.rateLimited])
        let coordinator = makeCoordinator(store: store, client: client, clock: clock)

        await expectEqual(.retryLater(.refreshThrottled)) { await coordinator.accessToken() }
        // ⛔ The route rate-limits BEFORE rotating, so the token is provably
        // unspent: keeping it, and clearing the marker, is what stops a 429
        // signing the user out.
        let session = await store.session
        XCTAssertEqual(session?.refreshToken, "refresh-1")
        let marker = await store.pending
        XCTAssertNil(marker)
    }

    func testAnUnsentRequestIsRetryableAndClearsTheMarker() async {
        let clock = TestClock(AuthFixtures.now)
        let store = SpyTokenStore(session: AuthFixtures.session())
        let client = ScriptedRefreshClient(script: [.notSent])
        let coordinator = makeCoordinator(store: store, client: client, clock: clock)

        await expectEqual(.retryLater(.refreshNotSent)) { await coordinator.accessToken() }
        let session = await store.session
        XCTAssertEqual(session?.refreshToken, "refresh-1", "opening the app offline must not cost a re-login")
        let marker = await store.pending
        XCTAssertNil(marker)
    }

    func testAnAmbiguousTransportFailureLeavesTheMarkerSet() async {
        let clock = TestClock(AuthFixtures.now)
        let store = SpyTokenStore(session: AuthFixtures.session())
        let client = ScriptedRefreshClient(script: [.transportFailure])
        let coordinator = makeCoordinator(store: store, client: client, clock: clock)

        await expectEqual(.reauthRequired(.refreshUnreachable)) { await coordinator.accessToken() }
        // ⚠️ The server may have rotated anyway. The marker staying set is what
        // turns the next attempt into a clean re-login rather than a replay.
        let marker = await store.pending
        XCTAssertEqual(marker, "refresh-1")
        let session = await store.session
        XCTAssertEqual(session?.refreshToken, "refresh-1")
    }

    func testTheNextAttemptAfterAnAmbiguousFailureReportsAnInterruptedRefresh() async {
        let clock = TestClock(AuthFixtures.now)
        let store = SpyTokenStore(session: AuthFixtures.session())
        let client = ScriptedRefreshClient(script: [.transportFailure])
        let coordinator = makeCoordinator(store: store, client: client, clock: clock)

        _ = await coordinator.accessToken()
        await expectEqual(.reauthRequired(.interruptedRefresh)) { await coordinator.accessToken() }
        // ⛔ AND THE POSSIBLY-SPENT TOKEN IS NEVER RE-PRESENTED. A second
        // presentation is what the server treats as theft.
        await expectEqual(1) { await client.callCount }
        let session = await store.session
        XCTAssertNil(session)
    }

    func testNoSessionIsTerminalAndSendsNothing() async {
        let clock = TestClock(AuthFixtures.now)
        let store = SpyTokenStore()
        let client = ScriptedRefreshClient()
        let coordinator = makeCoordinator(store: store, client: client, clock: clock)

        await expectEqual(.reauthRequired(.noSession)) { await coordinator.accessToken() }
        await expectEqual(0) { await client.callCount }
    }

    func testAnExpiredRefreshTokenIsTerminalAndSendsNothing() async {
        let clock = TestClock(AuthFixtures.now)
        let store = SpyTokenStore(session: AuthFixtures.session(expiresIn: 1000))
        let client = ScriptedRefreshClient()
        let coordinator = makeCoordinator(store: store, client: client, clock: clock)

        clock.advance(by: 2000)
        await expectEqual(.reauthRequired(.refreshTokenExpired)) { await coordinator.accessToken() }
        await expectEqual(0) { await client.callCount }
        let session = await store.session
        XCTAssertNil(session)
    }

    // ── Adoption, invalidation, sign-out ─────────────────────────────────────

    func testAdoptPersistsTheLoginPairAndServesItWithoutARefresh() async {
        let clock = TestClock(AuthFixtures.now)
        let store = SpyTokenStore()
        let client = ScriptedRefreshClient()
        let coordinator = makeCoordinator(store: store, client: client, clock: clock)

        await coordinator.adopt(AuthFixtures.tokens(index: 9), deviceId: "device-xyz")

        await expectEqual(.available("access-9")) { await coordinator.accessToken() }
        await expectEqual(0) { await client.callCount }
        let session = await store.session
        XCTAssertEqual(session?.refreshToken, "refresh-9")
        XCTAssertEqual(session?.deviceId, "device-xyz")
    }

    func testInvalidateOnlyDiscardsTheTokenTheCallerActuallyUsed() async {
        let clock = TestClock(AuthFixtures.now)
        let store = SpyTokenStore(session: AuthFixtures.session())
        let client = ScriptedRefreshClient(script: [.success(AuthFixtures.tokens(index: 2))])
        let coordinator = makeCoordinator(store: store, client: client, clock: clock)

        _ = await coordinator.accessToken()
        // ⛔ The stale-token call is the second of two racing 401s and must be a
        // no-op; an unconditional wipe would throw away the good token that just
        // replaced it and force an extra refresh.
        await expectFalse { await coordinator.invalidateAccessToken("access-stale") }
        await expectEqual(.available("access-2")) { await coordinator.accessToken() }
        await expectEqual(1) { await client.callCount }

        // A real invalidation drops the cache and forces the next acquisition to
        // go to the store, which here has only the exhausted script behind it.
        await expectTrue { await coordinator.invalidateAccessToken("access-2") }
        await expectEqual(.reauthRequired(.refreshUnreachable)) { await coordinator.accessToken() }
        await expectEqual(["refresh-1", "refresh-2"]) { await client.presented }
    }

    func testForgetClearsMemoryAndDisk() async {
        let clock = TestClock(AuthFixtures.now)
        let store = SpyTokenStore(session: AuthFixtures.session())
        let client = ScriptedRefreshClient(script: [.success(AuthFixtures.tokens(index: 2))])
        let coordinator = makeCoordinator(store: store, client: client, clock: clock)

        _ = await coordinator.accessToken()
        await coordinator.forget()

        await expectEqual(.reauthRequired(.noSession)) { await coordinator.accessToken() }
        let session = await store.session
        XCTAssertNil(session)
    }

    func testTheDefaultClockIsTheWallClockInMilliseconds() async {
        // Pins the production default rather than leaving it only ever
        // substituted: a `now` in SECONDS would put every freshly minted token
        // four decades in the past, and the coordinator would refresh on every
        // single request instead of serving the cache.
        let store = SpyTokenStore()
        let client = NeverRefreshClient()
        let coordinator = TokenRefreshCoordinator(store: store, refreshClient: client)
        let wallClockNow = Int64(Date().timeIntervalSince1970 * 1000)
        await coordinator.adopt(
            NativeTokens(
                accessToken: "access-wall",
                accessTokenExpiresAt: wallClockNow + 10 * 60 * 1000,
                refreshToken: "refresh-wall",
                refreshTokenExpiresAt: wallClockNow + 60 * 24 * 60 * 60 * 1000
            ),
            deviceId: "device-abc"
        )

        await expectEqual(.available("access-wall")) { await coordinator.accessToken() }
        await expectEqual(0) { await client.callCount }
    }
}
