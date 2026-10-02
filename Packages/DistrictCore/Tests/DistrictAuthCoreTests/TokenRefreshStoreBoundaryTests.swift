@testable import DistrictAuthCore
import Foundation
import XCTest

/// The ``TokenStore`` boundary: what a failing store may and may not cost the
/// user.
///
/// ⛔ SPLIT OUT OF `TokenRefreshCoordinatorTests` BECAUSE THAT FILE HIT THE
/// 500-LINE `file_length` CEILING, not because these are a lesser tier. Every
/// case here is one where the obvious handling of a store error — treat it as
/// "no session", or let the error propagate — is a PERMANENT sign-out for a
/// user whose device was merely locked for a moment.
final class TokenRefreshStoreBoundaryTests: XCTestCase {
    private func makeCoordinator(
        store: SpyTokenStore,
        client: any RefreshClient,
        clock: TestClock
    ) -> TokenRefreshCoordinator {
        TokenRefreshCoordinator(store: store, refreshClient: client, now: clock.now)
    }

    // ── The store boundary ───────────────────────────────────────────────────

    func testAnUnreadableStoreIsRetryableRatherThanASignOut() async {
        let clock = TestClock(AuthFixtures.now)
        let store = SpyTokenStore(session: AuthFixtures.session())
        let client = ScriptedRefreshClient()
        let coordinator = makeCoordinator(store: store, client: client, clock: clock)
        await store.failReads(true)

        // ⛔ A locked device fails the Keychain read transiently. Reporting that
        // as "no session" signs the user out for locking their phone.
        await expectEqual(.retryLater(.storeUnavailable)) { await coordinator.accessToken() }
        await expectEqual(0) { await client.callCount }
    }

    func testAnUnreadableMarkerIsRetryableRatherThanASignOut() async {
        let clock = TestClock(AuthFixtures.now)
        let store = ReadableSessionUnreadableMarkerStore(session: AuthFixtures.session())
        let client = ScriptedRefreshClient()
        let coordinator = TokenRefreshCoordinator(store: store, refreshClient: client, now: clock.now)

        await expectEqual(.retryLater(.storeUnavailable)) { await coordinator.accessToken() }
        await expectEqual(0) { await client.callCount }
    }

    func testAFailedMarkerWriteAbortsInsteadOfSendingAnUnprotectedRefresh() async {
        let clock = TestClock(AuthFixtures.now)
        let store = SpyTokenStore(session: AuthFixtures.session())
        let client = ScriptedRefreshClient(script: [.success(AuthFixtures.tokens(index: 2))])
        let coordinator = makeCoordinator(store: store, client: client, clock: clock)
        await store.failMarkerWrites(true)

        await expectEqual(.retryLater(.markerNotDurable)) { await coordinator.accessToken() }
        // ⛔ A skipped mutation must abort, never fall through to the action it
        // was protecting. Without the marker a crash mid-refresh would strand
        // the successor and the next launch would present a spent token.
        await expectEqual(0) { await client.callCount }
        let session = await store.session
        XCTAssertEqual(session?.refreshToken, "refresh-1")
    }

    // ── A failed store must not lose the new pair ────────────────────────────

    func testAFailedWriteKeepsTheRotatedPairAndKeepsWorking() async {
        let clock = TestClock(AuthFixtures.now)
        let store = SpyTokenStore(session: AuthFixtures.session())
        let client = ScriptedRefreshClient(script: [.success(AuthFixtures.tokens(index: 2))])
        let coordinator = makeCoordinator(store: store, client: client, clock: clock)
        await store.failNextWrites(1)

        // ⛔ The predecessor is already spent server-side, so discarding the
        // successor here would convert a momentary Keychain failure into a
        // PERMANENT sign-out.
        await expectEqual(.available("access-2")) { await coordinator.accessToken() }
        // ⚠️ And the marker stays set, so a crash before the retry lands on the
        // clean interrupted-refresh path rather than on a replay.
        let marker = await store.pending
        XCTAssertEqual(marker, "refresh-1")
    }

    func testTheRescuedPairIsRetriedAndUsedInsteadOfTheSpentDiskCopy() async {
        let clock = TestClock(AuthFixtures.now)
        let store = SpyTokenStore(session: AuthFixtures.session())
        let client = ScriptedRefreshClient(script: [
            .success(AuthFixtures.tokens(index: 2)),
            .success(AuthFixtures.tokens(index: 3, at: AuthFixtures.now + 20 * 60 * 1000)),
        ])
        let coordinator = makeCoordinator(store: store, client: client, clock: clock)
        await store.failNextWrites(1)

        _ = await coordinator.accessToken()
        clock.advance(by: 20 * 60 * 1000)
        await expectEqual(.available("access-3")) { await coordinator.accessToken() }

        // ⛔ THE SECOND REFRESH PRESENTED refresh-2, NOT THE refresh-1 STILL ON
        // DISK. Presenting the disk copy is the replay that revokes the family.
        await expectEqual(["refresh-1", "refresh-2"]) { await client.presented }
        let session = await store.session
        XCTAssertEqual(session?.refreshToken, "refresh-3")
    }

    func testAPersistentlyFailingStoreStillNeverRepresentsAToken() async {
        let clock = TestClock(AuthFixtures.now)
        let store = SpyTokenStore(session: AuthFixtures.session())
        let client = ScriptedRefreshClient(script: (2 ... 4).map { index in
            .success(AuthFixtures.tokens(index: index, at: AuthFixtures.now + Int64(index) * 20 * 60 * 1000))
        })
        let coordinator = makeCoordinator(store: store, client: client, clock: clock)
        await store.failNextWrites(.max)

        for index in 2 ... 4 {
            clock.millis = AuthFixtures.now + Int64(index) * 20 * 60 * 1000
            await expectEqual(.available("access-\(index)")) { await coordinator.accessToken() }
        }

        let presented = await client.presented
        XCTAssertEqual(presented, ["refresh-1", "refresh-2", "refresh-3"])
        let written = await store.writtenSessions
        XCTAssertTrue(written.isEmpty)
    }

    /// ⛔ A LOGIN COMPLETING BESIDE A QUEUED REFRESH MUST NOT COST A ROTATION.
    /// The store reads inside `acquire` are suspension points, so `adopt` can
    /// land in the middle of them; without the re-check that follows those
    /// reads, this refreshes a credential that is seconds old — and every
    /// avoidable refresh is one closer to the shared per-user limiter that
    /// degrades the account's other devices.
    func testALoginLandingMidAcquisitionPreemptsTheRefresh() async {
        let clock = TestClock(AuthFixtures.now)
        let store = GatedReadTokenStore(session: AuthFixtures.session())
        let client = NeverRefreshClient()
        let coordinator = TokenRefreshCoordinator(store: store, refreshClient: client, now: clock.now)

        let racer = Task { await coordinator.accessToken() }
        await waitUntil { await store.readEntered }
        await coordinator.adopt(AuthFixtures.tokens(index: 9), deviceId: "device-abc")
        await store.openGate()

        let outcome = await racer.value
        XCTAssertEqual(outcome, .available("access-9"))
        await expectEqual(0) { await client.callCount }
    }
}

// MARK: - Helpers

/// A store whose session reads fine but whose MARKER read throws — the one
/// combination `SpyTokenStore`'s single `failReads` flag cannot express, and the
/// only way to reach the coordinator's second store-failure branch.
private actor ReadableSessionUnreadableMarkerStore: TokenStore {
    private struct Failure: Error {}
    private let session: PersistedSession

    init(session: PersistedSession) {
        self.session = session
    }

    func read() async throws -> PersistedSession? {
        session
    }

    func write(_: PersistedSession) async throws {}
    func clear() async throws {}
    func pendingRefreshToken() async throws -> String? {
        throw Failure()
    }

    func markRefreshPending(_: String) async throws {}
    func clearRefreshPending() async throws {}

    /// ⚠️ The revoke outbox is inert here: nothing in this file signs out, and a
    /// store that answered a pending revoke would send this suite's coordinator
    /// down a path it is not testing.
    func pendingRevokeToken() async throws -> String? {
        nil
    }

    func markRevokePending(_: String) async throws {}
    func clearRevokePending() async throws {}
}

/// A store whose `read()` blocks until released, so the suspension window inside
/// `acquire` can be entered deliberately rather than raced for.
private actor GatedReadTokenStore: TokenStore {
    private var session: PersistedSession?
    private var pending: String?
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var readEntered = false

    init(session: PersistedSession?) {
        self.session = session
    }

    func openGate() {
        isOpen = true
        let resuming = waiters
        waiters = []
        for waiter in resuming {
            waiter.resume()
        }
    }

    func read() async throws -> PersistedSession? {
        readEntered = true
        if !isOpen {
            await withCheckedContinuation { waiters.append($0) }
        }
        return session
    }

    func write(_ session: PersistedSession) async throws {
        self.session = session
    }

    func clear() async throws {
        session = nil
        pending = nil
    }

    func pendingRefreshToken() async throws -> String? {
        pending
    }

    func markRefreshPending(_ refreshToken: String) async throws {
        pending = refreshToken
    }

    func clearRefreshPending() async throws {
        pending = nil
    }

    /// ⚠️ Inert, as above: this store exists to gate a `read()`, not to sign out.
    func pendingRevokeToken() async throws -> String? {
        nil
    }

    func markRevokePending(_: String) async throws {}
    func clearRevokePending() async throws {}
}
