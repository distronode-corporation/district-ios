@testable import DistrictAI
import DistrictAuthCore
import Foundation
import Security
import XCTest

/// The session store against the simulator's real Keychain, under a service name of its own per
/// test: a round trip, an overwrite, what a clear removes and keeps, the two pending markers, and
/// an item this build cannot read, which must throw rather than read as "no session".
final class KeychainTokenStoreTests: XCTestCase {
    private var store = KeychainTokenStore(service: "unused", accessGroup: nil)

    override func setUp() async throws {
        try await super.setUp()
        store = KeychainTokenStore(service: "com.distronode.district.tests.\(UUID().uuidString)", accessGroup: nil)
    }

    override func tearDown() async throws {
        try await store.clear()
        try await store.clearRevokePending()
        try await super.tearDown()
    }

    private static let session = PersistedSession(
        refreshToken: "refresh-1",
        refreshTokenExpiresAt: 4_102_444_800_000,
        deviceId: "device_1"
    )

    func testNothingStoredReadsAsNoSession() async throws {
        let read = try await store.read()
        XCTAssertNil(read)
        let pending = try await store.pendingRefreshToken()
        XCTAssertNil(pending)
        let revoke = try await store.pendingRevokeToken()
        XCTAssertNil(revoke)
    }

    func testASessionReadsBackAsWritten() async throws {
        try await store.write(Self.session)
        let read = try await store.read()
        XCTAssertEqual(read, Self.session)
    }

    /// A second write replaces the first rather than failing on the duplicate.
    func testAWriteReplacesTheStoredSession() async throws {
        try await store.write(Self.session)
        let rotated = PersistedSession(refreshToken: "refresh-2", refreshTokenExpiresAt: 1, deviceId: "device_1")
        try await store.write(rotated)
        let read = try await store.read()
        XCTAssertEqual(read, rotated)
    }

    /// ⚠️ A CLEAR TAKES THE SESSION AND THE PENDING REFRESH, AND LEAVES THE PENDING REVOKE: the
    /// revoke still has to reach the service after the sign-out that cleared the rest.
    func testAClearKeepsOnlyThePendingRevoke() async throws {
        try await store.write(Self.session)
        try await store.markRefreshPending("refresh-1")
        try await store.markRevokePending("refresh-0")
        try await store.clear()
        let read = try await store.read()
        XCTAssertNil(read)
        let pending = try await store.pendingRefreshToken()
        XCTAssertNil(pending)
        let revoke = try await store.pendingRevokeToken()
        XCTAssertEqual(revoke, "refresh-0")
    }

    func testThePendingMarkersRoundTripAndClear() async throws {
        try await store.markRefreshPending("refresh-1")
        try await store.markRefreshPending("refresh-2")
        let pending = try await store.pendingRefreshToken()
        XCTAssertEqual(pending, "refresh-2")
        try await store.clearRefreshPending()
        let cleared = try await store.pendingRefreshToken()
        XCTAssertNil(cleared)

        try await store.markRevokePending("")
        let empty = try await store.pendingRevokeToken()
        XCTAssertEqual(empty, "", "an empty token is stored as written, not read as absent")
        try await store.clearRevokePending()
        let gone = try await store.pendingRevokeToken()
        XCTAssertNil(gone)
    }

    /// Clearing what is not there is a successful clear.
    func testClearingNothingSucceeds() async throws {
        try await store.clear()
        try await store.clearRefreshPending()
        try await store.clearRevokePending()
    }

    /// ⛔ AN ITEM THIS BUILD CANNOT READ THROWS: nil would sign the person out.
    func testAnUnreadableSessionThrows() async throws {
        add(Data("not json".utf8), account: "native-session")
        do {
            _ = try await store.read()
            XCTFail("an unreadable session must throw")
        } catch KeychainTokenStoreError.unreadableItem {
            // expected
        }
    }

    func testAPendingTokenThatIsNotTextThrows() async throws {
        add(Data([0xFF, 0xFE, 0xFD]), account: "native-refresh-pending")
        do {
            _ = try await store.pendingRefreshToken()
            XCTFail("a pending token that is not UTF-8 must throw")
        } catch KeychainTokenStoreError.unreadableItem {
            // expected
        }
    }

    /// ⛔ NEVER SYNCHRONISED, and the access group only when one is named.
    func testTheQueryNeverSynchronises() {
        let query = store.query(account: "native-session")
        XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, "native-session")
        XCTAssertNil(query[kSecAttrAccessGroup as String])
        let grouped = KeychainTokenStore(service: "s", accessGroup: "TEAM.group").query(account: "a")
        XCTAssertEqual(grouped[kSecAttrAccessGroup as String] as? String, "TEAM.group")
    }

    /// Bytes written straight to the item the store reads, as an older or a broken build might leave.
    private func add(_ data: Data, account: String) {
        var request = store.query(account: account)
        request[kSecValueData as String] = data
        request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(request as CFDictionary, nil)
        XCTAssertEqual(status, errSecSuccess, "the Keychain refused the test item")
    }
}
