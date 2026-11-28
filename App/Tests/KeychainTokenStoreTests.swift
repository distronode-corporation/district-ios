@testable import DistrictAI
import DistrictAuthCore
import XCTest

/// KeychainTokenStore's two compare-and-clear requirements, the ones DistrictCore 9.0.0
/// adds to ``TokenStore`` with no default: the clear happens only while the slot still
/// holds the named token, and it is one atomic step, so a concurrent write can never
/// lose the newer token. The keychain itself is injected, because an unsigned build
/// answers -34018 for every SecItem call and these semantics have to be testable there.
///
/// The concurrent tests prove the SERIALIZATION, not just the outcome: the gated fake
/// parks the clear's compare mid-step, the competing write is sent while it is parked,
/// and the write must be unable to enter (the store is an actor, so the write queues
/// behind the clear's turn). A non-serialised store would run the write mid-compare,
/// which both deletes the newer token and trips the entry assertion. Every handoff is
/// observed state, never a sleep.
final class KeychainTokenStoreTests: XCTestCase {
    private var items: MemoryKeychain!
    private var store: KeychainTokenStore!

    override func setUp() {
        super.setUp()
        items = MemoryKeychain()
        store = KeychainTokenStore(items: items)
    }

    private func session(_ refreshToken: String) -> PersistedSession {
        PersistedSession(refreshToken: refreshToken, refreshTokenExpiresAt: 1, deviceId: "test-device")
    }

    // ── clear(ifHolding:) ──────────────────────────────────────────────────────

    func testClearIfHoldingTheHeldTokenClearsSessionAndMarker() async throws {
        try await store.write(session("old"))
        try await store.markRefreshPending("old")

        try await store.clear(ifHolding: "old")

        let read = try await store.read()
        XCTAssertNil(read, "the session the token named must be gone")
        let marker = try await store.pendingRefreshToken()
        XCTAssertNil(marker, "clear(ifHolding:) is clear(): the refresh marker dies with the session")
    }

    func testClearIfHoldingADifferentTokenKeepsEverything() async throws {
        try await store.write(session("new"))
        try await store.markRefreshPending("new")

        try await store.clear(ifHolding: "old")

        let read = try await store.read()
        XCTAssertEqual(read?.refreshToken, "new", "a newer session must survive an older undo")
        let marker = try await store.pendingRefreshToken()
        XCTAssertEqual(marker, "new", "the marker belongs to the surviving session")
    }

    /// The clear's compare parks mid-step (the gated fake holds it after its read), the
    /// login's write is sent while it is parked, and the write must NOT enter: the actor
    /// runs one member at a time, so the write queues behind the clear's turn and the
    /// compare cannot see a store the clear did not make. A struct would run the write
    /// mid-compare, delete the newer token, and trip the saves assertion below.
    func testConcurrentUndoAndWriteNeverLosesTheNewerSession() async throws {
        let gated = GatedKeychain()
        let gatedStore = KeychainTokenStore(items: gated)
        try await gatedStore.write(session("old"))
        gated.reset()
        gated.parkNextLoad()

        let replacement = session("new")
        async let undone: Void = gatedStore.clear(ifHolding: "old")
        while !gated.compareIsParked {
            await Task.yield()
        }

        async let written: Void = gatedStore.write(replacement)
        await Task.yield()
        XCTAssertEqual(
            gated.saves,
            0,
            "the write must not run while the compare-and-clear holds the store"
        )

        gated.release()
        _ = try await undone
        _ = try await written

        let read = try await gatedStore.read()
        XCTAssertEqual(
            read?.refreshToken,
            "new",
            "whichever side of the gate the clear finished on, the login's session is what survives"
        )
    }

    // ── clearRevokePending(ifHolding:) ──────────────────────────────────────────────────────────────────────────────

    func testClearRevokePendingHoldingTheHeldTokenClearsTheOutbox() async throws {
        try await store.markRevokePending("old")

        try await store.clearRevokePending(ifHolding: "old")

        let outbox = try await store.pendingRevokeToken()
        XCTAssertNil(outbox, "the acknowledged revoke is drained")
    }

    func testClearRevokePendingHoldingADifferentTokenKeepsTheOutbox() async throws {
        try await store.markRevokePending("new")

        try await store.clearRevokePending(ifHolding: "old")

        let outbox = try await store.pendingRevokeToken()
        XCTAssertEqual(
            outbox,
            "new",
            "an older acknowledgement must not drop a newer token the server still honours"
        )
    }

    /// Same proof for the outbox: the acknowledgement parks mid-compare, the newer
    /// revoke is sent while it is parked, and it must queue rather than run.
    func testConcurrentAcknowledgeAndMarkNeverLosesTheNewerOutboxEntry() async throws {
        let gated = GatedKeychain()
        let gatedStore = KeychainTokenStore(items: gated)
        try await gatedStore.markRevokePending("old")
        gated.reset()
        gated.parkNextLoad()

        async let acknowledged: Void = gatedStore.clearRevokePending(ifHolding: "old")
        while !gated.compareIsParked {
            await Task.yield()
        }

        async let marked: Void = gatedStore.markRevokePending("new")
        await Task.yield()
        XCTAssertEqual(
            gated.saves,
            0,
            "the newer revoke must not run while the acknowledgement holds the store"
        )

        gated.release()
        _ = try await acknowledged
        _ = try await marked

        let outbox = try await gatedStore.pendingRevokeToken()
        XCTAssertEqual(
            outbox,
            "new",
            "whichever side of the gate the acknowledgement finished on, the newer revoke is what stays queued"
        )
    }
}

/// A deterministic in-memory keychain. Unchecked Sendable is sound here: every access
/// is under the lock, and the class never escapes a single test.
class MemoryKeychain: KeychainItemBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    func load(account: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return items[account]
    }

    func save(_ data: Data, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        items[account] = data
    }

    func delete(account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        items[account] = nil
    }
}

/// A ``MemoryKeychain`` that parks one load mid-compare, so the concurrent tests can
/// hold the clear's step open and prove the store excludes the competing write. The
/// park is a semaphore, not an await: the compare is a synchronous stretch of the
/// store's turn, and the point is that nothing else enters the store while it runs.
final class GatedKeychain: MemoryKeychain, @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var parked = false
    private(set) var saves = 0

    /// True once the held load has read its value and parked.
    var compareIsParked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return parked
    }

    /// Zero the counters, so a test can seed the fake and then count only what the
    /// concurrent phase sends.
    func reset() {
        lock.lock()
        saves = 0
        parked = false
        lock.unlock()
    }

    /// Let the held compare proceed.
    func release() {
        gate.signal()
    }

    /// Park the NEXT load, and only that one: the test's verification reads after
    /// the race must pass through. Load reads its value first, so the parked compare
    /// is already committed to what it saw when the gate opens.
    private var parkNext = false

    func parkNextLoad() {
        lock.lock()
        parkNext = true
        lock.unlock()
    }

    override func load(account: String) throws -> Data? {
        let value = try super.load(account: account)
        lock.lock()
        let park = parkNext
        parkNext = false
        parked = park
        lock.unlock()
        if park {
            gate.wait()
        }
        return value
    }

    override func save(_ data: Data, account: String) throws {
        lock.lock()
        saves += 1
        lock.unlock()
        try super.save(data, account: account)
    }
}
