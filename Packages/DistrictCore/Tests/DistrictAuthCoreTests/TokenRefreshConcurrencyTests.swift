@testable import DistrictAuthCore
import Foundation
import XCTest

/// ⛔ THE TESTS THAT MATTER MOST IN THIS MODULE. Every failure below is a
/// SILENT one in production: two callers presenting the same refresh token does
/// not fail the request, it succeeds — and the server revokes the entire token
/// family as a suspected theft, signing the user out on every device with a
/// `[auth] Native refresh replay detected` line nobody is watching.
final class TokenRefreshConcurrencyTests: XCTestCase {
    private static let callerCount = 24

    func testConcurrentCallersCoalesceOntoExactlyOneRefresh() async {
        let clock = TestClock(AuthFixtures.now)
        let store = SpyTokenStore(session: AuthFixtures.session())
        // Held closed so the race is observable rather than hoped for: every
        // caller that reached the network is counted BEFORE any of them is let
        // through.
        let client = ScriptedRefreshClient(script: [.success(AuthFixtures.tokens(index: 2))], open: false)
        let coordinator = TokenRefreshCoordinator(store: store, refreshClient: client, now: clock.now)

        let collector = OutcomeCollector()
        // ⚠️ N INDEPENDENT TASKS RATHER THAN A `withTaskGroup` NESTED INSIDE A
        // `Task`. That nesting is refused by the region-based isolation checker
        // with "pattern that the region based isolation checker does not
        // understand how to check", which reads like a compiler fault rather
        // than like a shape to avoid. Detached tasks race just as hard.
        let racers = (0 ..< Self.callerCount).map { _ in
            Task { await collector.record(coordinator.accessToken()) }
        }

        // One caller is inside the client; give every other caller ample
        // opportunity to start a refresh of its own before checking.
        await waitUntil { await client.callCount >= 1 }
        for _ in 0 ..< 2000 {
            await Task.yield()
        }

        let inFlightCalls = await client.callCount
        XCTAssertEqual(inFlightCalls, 1, "\(Self.callerCount) callers must produce ONE in-flight refresh")

        await client.open()
        for racer in racers {
            await racer.value
        }
        let outcomes = await collector.outcomes

        XCTAssertEqual(outcomes.count, Self.callerCount)
        XCTAssertTrue(outcomes.allSatisfy { $0 == .available("access-2") })
        await expectEqual(["refresh-1"]) { await client.presented }
    }

    func testNoTokenIsEverPresentedTwiceUnderRepeatedRaces() async {
        // Ten rounds of a concurrent stampede, each expiring the previous access
        // token, so the single-flight gate has to close and reopen repeatedly
        // rather than being tested once from cold.
        let rounds = 10
        let clock = TestClock(AuthFixtures.now)
        let store = SpyTokenStore(session: AuthFixtures.session())
        let client = ScriptedRefreshClient(script: (2 ... (rounds + 1)).map { index in
            .success(AuthFixtures.tokens(index: index, at: AuthFixtures.now + Int64(index) * 20 * 60 * 1000))
        })
        let coordinator = TokenRefreshCoordinator(store: store, refreshClient: client, now: clock.now)

        for round in 2 ... (rounds + 1) {
            clock.millis = AuthFixtures.now + Int64(round) * 20 * 60 * 1000
            await withTaskGroup(of: Void.self) { group in
                for _ in 0 ..< Self.callerCount {
                    group.addTask { _ = await coordinator.accessToken() }
                }
            }
        }

        let presented = await client.presented
        // ⛔ EXACTLY ONE REFRESH PER ROUND, AND NO VALUE TWICE.
        XCTAssertEqual(presented.count, rounds)
        XCTAssertEqual(Set(presented).count, rounds, "a repeated token is the replay that revokes the family")
        XCTAssertEqual(presented, (1 ... rounds).map { "refresh-\($0)" })
    }

    func testTheStoreSeesOneSuccessorPerRotationWithNoLostUpdate() async {
        let clock = TestClock(AuthFixtures.now)
        let store = SpyTokenStore(session: AuthFixtures.session())
        let client = ScriptedRefreshClient(script: [
            .success(AuthFixtures.tokens(index: 2)),
            .success(AuthFixtures.tokens(index: 3, at: AuthFixtures.now + 20 * 60 * 1000)),
        ])
        let coordinator = TokenRefreshCoordinator(store: store, refreshClient: client, now: clock.now)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< Self.callerCount {
                group.addTask { _ = await coordinator.accessToken() }
            }
        }
        clock.advance(by: 20 * 60 * 1000)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< Self.callerCount {
                group.addTask { _ = await coordinator.accessToken() }
            }
        }

        // ⛔ TWO WRITES FOR TWO ROTATIONS, IN ORDER. A third write, or an
        // out-of-order pair, means a queued caller persisted a session that a
        // later rotation had already superseded — the lost update that leaves
        // disk holding a spent token.
        let written = await store.writtenSessions
        XCTAssertEqual(written.map(\.refreshToken), ["refresh-2", "refresh-3"])
        let session = await store.session
        XCTAssertEqual(session?.refreshToken, "refresh-3")
    }

    func testAFailedRefreshIsNotLatchedForLaterCallers() async {
        // A completed single-flight task must not be left installed: the next
        // caller has to get a fresh attempt rather than the previous verdict.
        let clock = TestClock(AuthFixtures.now)
        let store = SpyTokenStore(session: AuthFixtures.session())
        let client = ScriptedRefreshClient(script: [
            .rateLimited,
            .success(AuthFixtures.tokens(index: 2)),
        ])
        let coordinator = TokenRefreshCoordinator(store: store, refreshClient: client, now: clock.now)

        await expectEqual(.retryLater(.refreshThrottled)) { await coordinator.accessToken() }
        await expectEqual(.available("access-2")) { await coordinator.accessToken() }
        await expectEqual(2) { await client.callCount }
    }

    func testConcurrentCallersAllSeeATerminalRejectionRatherThanRetrying() async {
        let clock = TestClock(AuthFixtures.now)
        let store = SpyTokenStore(session: AuthFixtures.session())
        let client = ScriptedRefreshClient(script: [.rejected], fallback: .rejected, open: false)
        let coordinator = TokenRefreshCoordinator(store: store, refreshClient: client, now: clock.now)

        let collector = OutcomeCollector()
        // ⚠️ N INDEPENDENT TASKS RATHER THAN A `withTaskGroup` NESTED INSIDE A
        // `Task`. That nesting is refused by the region-based isolation checker
        // with "pattern that the region based isolation checker does not
        // understand how to check", which reads like a compiler fault rather
        // than like a shape to avoid. Detached tasks race just as hard.
        let racers = (0 ..< Self.callerCount).map { _ in
            Task { await collector.record(coordinator.accessToken()) }
        }
        await waitUntil { await client.callCount >= 1 }
        for _ in 0 ..< 2000 {
            await Task.yield()
        }
        await client.open()
        for racer in racers {
            await racer.value
        }

        let outcomes = await collector.outcomes
        XCTAssertEqual(outcomes.count, Self.callerCount)
        XCTAssertTrue(outcomes.allSatisfy { $0 == .reauthRequired(.refreshRejected) })
        // ⛔ ONE presentation of a dead credential, not 24. Each extra one is a
        // request against the refresh limiter, which is shared per user and
        // would degrade that user's other devices.
        await expectEqual(1) { await client.callCount }
    }
}
