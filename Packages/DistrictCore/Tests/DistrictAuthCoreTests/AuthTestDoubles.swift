@testable import DistrictAuthCore
import Foundation
import XCTest

// MARK: - Async assertions

// ⛔ XCTest's ASSERTIONS TAKE A NON-ASYNC `@autoclosure`, so
// `XCTAssertEqual(await someActor.value, x)` does not compile at all:
// "'await' in an autoclosure that does not support concurrency". Nearly
// everything in this module is actor-isolated, so without these wrappers every
// assertion would have to hoist its subject into a local first — which reads as
// ceremony and, worse, makes it easy to assert against a value captured several
// statements before the thing that was supposed to change it.
//
// ⛔ AND THE SUBJECT IS A TRAILING CLOSURE RATHER THAN AN `@autoclosure () async`,
// WHICH IS THE NON-OBVIOUS HALF. The autoclosure form compiles, but SwiftFormat's
// `hoistAwait` rule rewrites `await expectEqual(await x.y(), z)` to
// `await expectEqual(x.y(), z)` — and THAT does not compile, because an async
// autoclosure still needs its suspension marked at the argument site. The
// resulting error ("actor-isolated instance method cannot be called from outside
// of the actor") points at the actor rather than at the formatter that moved the
// keyword, so the cause is genuinely hard to see. An `await` inside a closure
// body is already at the start of its own expression and `hoistAwait` leaves it
// alone. ⚠️ Do not "simplify" these back to autoclosures; `swiftformat --lint`
// in CI will pass and the build will not.

func expectEqual<T: Equatable>(
    _ expected: T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    from actual: () async -> T
) async {
    let value = await actual()
    XCTAssertEqual(value, expected, message(), file: file, line: line)
}

func expectNil(
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    from actual: () async -> (some Any)?
) async {
    let value = await actual()
    XCTAssertNil(value, message(), file: file, line: line)
}

func expectTrue(
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    from actual: () async -> Bool
) async {
    let value = await actual()
    XCTAssertTrue(value, message(), file: file, line: line)
}

func expectFalse(
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    from actual: () async -> Bool
) async {
    let value = await actual()
    XCTAssertFalse(value, message(), file: file, line: line)
}

/// A clock the tests drive by hand.
///
/// ⚠️ NOT `Date()`. Every expiry in this module is an absolute epoch value in
/// MILLISECONDS, so a test that used the wall clock would either sleep or race.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64

    init(_ millis: Int64) {
        value = millis
    }

    var millis: Int64 {
        get {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        set {
            lock.lock()
            value = newValue
            lock.unlock()
        }
    }

    /// A `now` closure for the types under test.
    var now: @Sendable () -> Int64 {
        { [self] in millis }
    }

    func advance(by delta: Int64) {
        millis += delta
    }
}

/// A ``TokenStore`` that records what was asked of it and can be made to fail.
///
/// ⛔ NOT `InMemoryTokenStore` WITH KNOBS BOLTED ON. That type ships in
/// `Sources/` for other modules' suites and stays honest on purpose; failure
/// injection belongs to the tests that need it, here, where it cannot be
/// mistaken for behaviour the real store has.
actor SpyTokenStore: TokenStore {
    struct InjectedFailure: Error {}

    /// The mutations this store saw, in the order it saw them.
    ///
    /// ⛔ THE ONLY WAY TO PROVE THE SIGN-OUT ORDERING. "The outbox write is
    /// durable before the wipe" is a claim about SEQUENCE, and a pair of
    /// end-state assertions cannot distinguish it from the reverse order — both
    /// leave an outbox entry and no session. See `SignOutCoordinatorTests`.
    enum Operation: Equatable {
        case read
        case write
        case clear
        case markRefreshPending
        case clearRefreshPending
        case readRevoke
        case markRevokePending
        case clearRevokePending
    }

    private(set) var session: PersistedSession?
    private(set) var pending: String?
    private(set) var revokePending: String?

    private(set) var reads = 0
    private(set) var writes = 0
    private(set) var clears = 0
    private(set) var markerWrites = 0
    private(set) var markerClears = 0
    /// Every session ever written, in order — the "no lost update" evidence.
    private(set) var writtenSessions: [PersistedSession] = []
    private(set) var operations: [Operation] = []

    private var failRead = false
    private var failMarkerWrite = false
    private var failRevokeMarkerWrite = false
    /// Number of remaining `write` calls that should throw. `Int.max` for
    /// "always".
    private var failingWrites = 0

    init(session: PersistedSession? = nil, pending: String? = nil, revokePending: String? = nil) {
        self.session = session
        self.pending = pending
        self.revokePending = revokePending
    }

    // ── Injection ────────────────────────────────────────────────────────────

    func failReads(_ shouldFail: Bool) {
        failRead = shouldFail
    }

    func failMarkerWrites(_ shouldFail: Bool) {
        failMarkerWrite = shouldFail
    }

    func failNextWrites(_ count: Int) {
        failingWrites = count
    }

    func failRevokeMarkerWrites(_ shouldFail: Bool) {
        failRevokeMarkerWrite = shouldFail
    }

    // ── TokenStore ───────────────────────────────────────────────────────────

    func read() async throws -> PersistedSession? {
        reads += 1
        operations.append(.read)
        if failRead {
            throw InjectedFailure()
        }
        return session
    }

    func write(_ session: PersistedSession) async throws {
        writes += 1
        operations.append(.write)
        if failingWrites > 0 {
            failingWrites -= 1
            throw InjectedFailure()
        }
        self.session = session
        writtenSessions.append(session)
    }

    /// ⛔ `revokePending` SURVIVES, mirroring ``InMemoryTokenStore`` and the real
    /// `KeychainTokenStore`. A double that wiped it here would make the whole
    /// outbox mechanism untestable while looking correct.
    func clear() async throws {
        clears += 1
        operations.append(.clear)
        session = nil
        pending = nil
    }

    func pendingRefreshToken() async throws -> String? {
        if failRead {
            throw InjectedFailure()
        }
        return pending
    }

    func markRefreshPending(_ refreshToken: String) async throws {
        markerWrites += 1
        operations.append(.markRefreshPending)
        if failMarkerWrite {
            throw InjectedFailure()
        }
        pending = refreshToken
    }

    func clearRefreshPending() async throws {
        markerClears += 1
        operations.append(.clearRefreshPending)
        pending = nil
    }

    func pendingRevokeToken() async throws -> String? {
        operations.append(.readRevoke)
        if failRead {
            throw InjectedFailure()
        }
        return revokePending
    }

    func markRevokePending(_ refreshToken: String) async throws {
        operations.append(.markRevokePending)
        if failRevokeMarkerWrite {
            throw InjectedFailure()
        }
        revokePending = refreshToken
    }

    func clearRevokePending() async throws {
        operations.append(.clearRevokePending)
        revokePending = nil
    }
}

/// A ``RevokeClient`` that answers from a script and records what it presented.
///
/// ⛔ `presented` IS THE EVIDENCE THAT THE CREDENTIAL WAS READ BEFORE THE WIPE.
/// An empty array after a sign-out with a stored session means the coordinator
/// wiped first and had nothing left to revoke with.
actor ScriptedRevokeClient: RevokeClient {
    private(set) var presented: [String] = []

    private var script: [RevokeOutcome]
    private let fallback: RevokeOutcome

    init(script: [RevokeOutcome] = [], fallback: RevokeOutcome = .accepted) {
        self.script = script
        self.fallback = fallback
    }

    var callCount: Int {
        presented.count
    }

    func revoke(refreshToken: String) async -> RevokeOutcome {
        presented.append(refreshToken)
        return script.isEmpty ? fallback : script.removeFirst()
    }
}

/// A ``RevokeClient`` that must never be called.
actor NeverRevokeClient: RevokeClient {
    private(set) var callCount = 0

    func revoke(refreshToken _: String) async -> RevokeOutcome {
        callCount += 1
        return .accepted
    }
}

/// A ``RefreshClient`` that answers from a script, records what it was asked to
/// present, and can be held open so a race is observable rather than hoped for.
actor ScriptedRefreshClient: RefreshClient {
    /// Every refresh token this client was asked to present, in order.
    ///
    /// ⛔ THE CORE EVIDENCE OF THE WHOLE MODULE: a value appearing here twice is
    /// the replay that revokes the user's entire token family.
    private(set) var presented: [String] = []

    private var script: [RefreshResult]
    private let fallback: RefreshResult
    private var isOpen: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(script: [RefreshResult] = [], fallback: RefreshResult = .transportFailure, open: Bool = true) {
        self.script = script
        self.fallback = fallback
        isOpen = open
    }

    var callCount: Int {
        presented.count
    }

    /// Let every blocked call, and every later call, through.
    func open() {
        isOpen = true
        let resuming = waiters
        waiters = []
        for waiter in resuming {
            waiter.resume()
        }
    }

    func refresh(refreshToken: String) async -> RefreshResult {
        presented.append(refreshToken)
        if !isOpen {
            await withCheckedContinuation { waiters.append($0) }
        }
        return script.isEmpty ? fallback : script.removeFirst()
    }
}

/// A ``RefreshClient`` that must never be called.
///
/// Used to pin paths that must not touch the session credential: if it is ever
/// invoked, ``callCount`` says so.
actor NeverRefreshClient: RefreshClient {
    private(set) var callCount = 0

    func refresh(refreshToken _: String) async -> RefreshResult {
        callCount += 1
        return .transportFailure
    }
}

/// Collects the outcomes of a stampede of concurrent callers.
///
/// ⚠️ AN ACTOR RATHER THAN A `withTaskGroup(of: AccessTokenOutcome.self)` THAT
/// RETURNS AN ARRAY. Returning a collection out of a task group nested inside a
/// `Task` defeats the region-based isolation checker, which refuses with
/// "pattern that the region based isolation checker does not understand how to
/// check. Please file a bug" — a diagnostic that reads like a compiler fault
/// rather than like a shape to avoid.
actor OutcomeCollector {
    private(set) var outcomes: [AccessTokenOutcome] = []

    func record(_ outcome: AccessTokenOutcome) {
        outcomes.append(outcome)
    }

    var count: Int {
        outcomes.count
    }
}

// MARK: - Fixtures

enum AuthFixtures {
    /// 2026-08-19T12:00:00Z, in milliseconds.
    static let now: Int64 = 1_787_140_800_000

    static func session(
        refreshToken: String = "refresh-1",
        expiresIn: Int64 = 60 * 24 * 60 * 60 * 1000,
        deviceId: String = "device-abc"
    ) -> PersistedSession {
        PersistedSession(
            refreshToken: refreshToken,
            refreshTokenExpiresAt: now + expiresIn,
            deviceId: deviceId
        )
    }

    static func tokens(
        index: Int,
        at clock: Int64 = AuthFixtures.now,
        accessLifetime: Int64 = 10 * 60 * 1000
    ) -> NativeTokens {
        NativeTokens(
            accessToken: "access-\(index)",
            accessTokenExpiresAt: clock + accessLifetime,
            refreshToken: "refresh-\(index)",
            refreshTokenExpiresAt: clock + 60 * 24 * 60 * 60 * 1000
        )
    }
}
