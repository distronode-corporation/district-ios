@testable import DistrictAI
import DistrictAuthCore
import XCTest

/// KeychainTokenStore's two compare-and-clear requirements, the ones DistrictCore 9.0.0
/// adds to ``TokenStore`` with no default: the clear happens only while the slot still
/// holds the named token, and it is one atomic step, so a concurrent write can never
/// lose the newer token. The keychain itself is injected, because an unsigned build
/// answers -34018 for every SecItem call and these semantics have to be testable there.
/// Every expectation is deterministic: both interleavings of each concurrent test end
/// in the same place, and nothing sleeps.
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

    func testConcurrentUndoAndWriteNeverLosesTheNewerSession() async throws {
        let store: KeychainTokenStore = self.store
        let replacement = session("new")
        try await store.write(session("old"))

        async let undone: Void = store.clear(ifHolding: "old")
        async let written: Void = store.write(replacement)
        _ = try await undone
        _ = try await written

        let read = try await store.read()
        XCTAssertEqual(
            read?.refreshToken,
            "new",
            "whichever order the actor runs them in, the login's session is what survives"
        )
    }

    // ── clearRevokePending(ifHolding:) ────────────────────────────────────────

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

    func testConcurrentAcknowledgeAndMarkNeverLosesTheNewerOutboxEntry() async throws {
        let store: KeychainTokenStore = self.store
        try await store.markRevokePending("old")

        async let acknowledged: Void = store.clearRevokePending(ifHolding: "old")
        async let marked: Void = store.markRevokePending("new")
        _ = try await acknowledged
        _ = try await marked

        let outbox = try await store.pendingRevokeToken()
        XCTAssertEqual(
            outbox,
            "new",
            "whichever order the actor runs them in, the newer revoke is what stays queued"
        )
    }
}

/// A deterministic in-memory keychain. Unchecked Sendable is sound here: every access
/// is under the lock, and the class never escapes a single test.
private final class MemoryKeychain: KeychainItemBackend, @unchecked Sendable {
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
