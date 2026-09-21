import DistrictAuthCore
import Foundation
import Security

/// The production ``TokenStore``: one Keychain item for the session, one for the
/// pending-refresh marker, one for the revoke outbox.
///
/// ⛔ `kSecAttrSynchronizable = false` IS LOAD-BEARING, NOT HYGIENE, AND ITS
/// FAILURE MODE DOES NOT LOOK LIKE A KEYCHAIN PROBLEM. A synchronizable item is
/// copied to iCloud Keychain and lands on the user's other devices. Both devices
/// then hold the same refresh token, and the server's rotation is mandatory and
/// single-use: the second device to present it is indistinguishable from a thief
/// replaying a stolen credential, so `rotateNativeSession` revokes the ENTIRE
/// token family and logs `[auth] Native refresh replay detected`. The user is
/// signed out everywhere, at random, and the symptom points nowhere near this
/// line. The Android client carries the same rule.
///
/// ⛔ `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, AND THE
/// `ThisDeviceOnly` HALF IS THE SECOND HALF OF THE RULE ABOVE. It also keeps the
/// item out of an unencrypted device backup, so a restored backup cannot carry a
/// live refresh token onto a different phone.
/// ⚠️ `AfterFirstUnlock` RATHER THAN `WhenUnlocked`, WHICH DISAGREES WITH THE
/// DOC COMMENT ON ``TokenStore`` AND IS A DELIBERATE CHOICE TO REVIEW. This class
/// is read on every cold start and may be read from a push-triggered background
/// wake; `WhenUnlocked` fails those reads on a locked phone. The
/// coordinator survives that correctly — a thrown read maps to
/// ``RetryReason/storeUnavailable`` and keeps the session — but it means an alert
/// push arriving on a locked phone could not fetch anything. `AfterFirstUnlock`
/// is the narrowest class that still works after a reboot-plus-one-unlock, which
/// is the property background work needs.
///
/// ⚠️ A STRUCT, SO IT IS `Sendable` BY CONSTRUCTION. Every Keychain call below is
/// synchronous and thread-safe; there is no state here to protect, so an actor
/// would only add suspension points to a call that never blocks.
struct KeychainTokenStore: TokenStore {
    /// `kSecAttrService` for every item this store owns.
    ///
    /// ⚠️ Changing it ORPHANS the existing item rather than migrating it: the old
    /// entry stays in the Keychain, unreadable and unreachable, and every user is
    /// silently signed out on the update that changed it.
    static let defaultService = "com.distronode.district.session"

    /// The three accounts under ``service``.
    ///
    /// ⚠️ SEPARATE ITEMS, NOT THREE FIELDS OF ONE. The marker must be durable
    /// BEFORE the refresh it protects is sent, and the session must be written
    /// AFTER the rotation succeeds — two writes at two different moments. Packing
    /// them into one blob would mean rewriting the session to set the marker.
    ///
    /// ⛔ AND THE OUTBOX HAS A HARDER REASON TO BE ITS OWN ITEM THAN THE OTHER
    /// TWO: it is the one slot ``clear()`` MUST NOT DELETE. If it were a field
    /// of the session blob, clearing the session would take it by construction,
    /// and the bug would be invisible — the wipe would look correct and the
    /// stranded credential would surface only as a session the server kept
    /// honouring for 60 days.
    private static let sessionAccount = "native-session"
    private static let pendingAccount = "native-refresh-pending"
    private static let revokeAccount = "native-revoke-pending"

    let service: String

    init(service: String = KeychainTokenStore.defaultService) {
        self.service = service
    }

    // ── TokenStore ───────────────────────────────────────────────────────────

    func read() async throws -> PersistedSession? {
        guard let data = try load(account: Self.sessionAccount) else { return nil }
        let stored = try decode(data)
        return PersistedSession(
            refreshToken: stored.refreshToken,
            refreshTokenExpiresAt: stored.refreshTokenExpiresAt,
            deviceId: stored.deviceId
        )
    }

    func write(_ session: PersistedSession) async throws {
        let stored = StoredSession(
            refreshToken: session.refreshToken,
            refreshTokenExpiresAt: session.refreshTokenExpiresAt,
            deviceId: session.deviceId
        )
        let data = try JSONEncoder().encode(stored)
        try save(data, account: Self.sessionAccount)
    }

    /// ⛔ `revokeAccount` IS DELIBERATELY ABSENT FROM THIS METHOD, AND IT IS THE
    /// ONE LINE IN THIS FILE MOST LIKELY TO BE "TIDIED UP" INTO A BUG. The
    /// outbox names a credential the SERVER IS STILL HONOURING, and the sign-out
    /// that wrote it calls this method microseconds later — so deleting it here
    /// would erase the only record of the very token it exists to chase, which
    /// is precisely the stranding it was added to prevent. The three slots look
    /// symmetric and are not: the session and its refresh marker describe THIS
    /// session and die with it, the outbox describes a server-side row that
    /// outlives it. Same rule as `KeystoreTokenStore.wipe` on Android; see the
    /// ⛔ on ``TokenStore/clear()``.
    func clear() async throws {
        try delete(account: Self.sessionAccount)
        try delete(account: Self.pendingAccount)
    }

    func pendingRefreshToken() async throws -> String? {
        guard let data = try load(account: Self.pendingAccount) else { return nil }
        guard let token = String(data: data, encoding: .utf8) else {
            throw KeychainTokenStoreError.unreadableItem
        }
        return token
    }

    func markRefreshPending(_ refreshToken: String) async throws {
        try save(Data(refreshToken.utf8), account: Self.pendingAccount)
    }

    func clearRefreshPending() async throws {
        try delete(account: Self.pendingAccount)
    }

    /// ⚠️ THE SAME ACCESSIBILITY AND SYNCHRONIZABLE ATTRIBUTES AS THE SESSION,
    /// because it holds the same kind of secret: this IS a live refresh token,
    /// just one the device has stopped using. `kSecAttrSynchronizable = false`
    /// stays load-bearing for the reason on the type — an outbox entry synced to
    /// a second device would be a second copy of a credential whose replay
    /// revokes the whole family — and both attributes come from ``query(account:)``
    /// and ``save(_:account:)``, which every account shares.
    func pendingRevokeToken() async throws -> String? {
        guard let data = try load(account: Self.revokeAccount) else { return nil }
        guard let token = String(data: data, encoding: .utf8) else {
            throw KeychainTokenStoreError.unreadableItem
        }
        return token
    }

    func markRevokePending(_ refreshToken: String) async throws {
        try save(Data(refreshToken.utf8), account: Self.revokeAccount)
    }

    func clearRevokePending() async throws {
        try delete(account: Self.revokeAccount)
    }

    // ── Keychain ─────────────────────────────────────────────────────────────

    /// The identity of one item. ⚠️ Used for reads, writes and deletes alike, so
    /// a value that differs between them would address a different item.
    private func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // ⛔ See the ⛔ on the type. Also stated on the LOOKUP, not only on
            // the write: a query that omits it would still match only
            // non-synchronizable items today, but stating it means an item that
            // somehow became synchronizable is invisible here rather than being
            // read and presented.
            kSecAttrSynchronizable as String: false,
        ]
    }

    private func load(account: String) throws -> Data? {
        var request = query(account: account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw KeychainTokenStoreError.unreadableItem }
            return data
        case errSecItemNotFound:
            // ⛔ THE ONE STATUS THAT IS NOT AN ERROR. Every other failure THROWS,
            // because "the device is locked" and "there is no session" are
            // different answers and the coordinator acts on the difference: a
            // throw keeps the session, a nil signs the user out.
            return nil
        default:
            throw KeychainTokenStoreError.status(status)
        }
    }

    /// Write `data`, creating the item if it is not there yet.
    ///
    /// ⚠️ UPDATE FIRST, ADD ON `errSecItemNotFound` — deliberately NOT
    /// delete-then-add, which is the more common shape. A crash between the
    /// delete and the add would lose a refresh token that was perfectly good,
    /// costing a re-login for no reason.
    private func save(_ data: Data, account: String) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // Restated on every write so an item created by an earlier build
            // with a laxer class is corrected rather than inherited.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updated = SecItemUpdate(query(account: account) as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess {
            return
        }
        guard updated == errSecItemNotFound else { throw KeychainTokenStoreError.status(updated) }

        var request = query(account: account)
        request.merge(attributes) { _, new in new }
        let added = SecItemAdd(request as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainTokenStoreError.status(added) }
    }

    private func delete(account: String) throws {
        let status = SecItemDelete(query(account: account) as CFDictionary)
        // Nothing to delete is a successful clear, not a failure.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainTokenStoreError.status(status)
        }
    }

    private func decode(_ data: Data) throws -> StoredSession {
        do {
            return try JSONDecoder().decode(StoredSession.self, from: data)
        } catch {
            // ⚠️ NOT re-thrown as a decode error. An item this build cannot read
            // is as unusable as a Keychain failure, and the coordinator's only
            // safe reading of a throw is "could not check" — which keeps the
            // session and retries rather than silently starting a new one.
            throw KeychainTokenStoreError.unreadableItem
        }
    }

    /// What actually goes in the item's data.
    ///
    /// ⚠️ ITS KEYS ARE STORAGE, NOT A WIRE CONTRACT. They are named after
    /// ``PersistedSession`` for readability only; nothing on the server ever sees
    /// this shape, and it is not under the contract gate.
    private struct StoredSession: Codable {
        let refreshToken: String
        let refreshTokenExpiresAt: Int64
        let deviceId: String
    }
}

/// Why a Keychain operation failed.
///
/// ⚠️ CARRIES THE `OSStatus` RATHER THAN A SENTENCE. Nothing renders this: every
/// consumer is ``TokenRefreshCoordinator``, which maps a throw to
/// ``RetryReason/storeUnavailable`` without reading it. The code exists so a
/// Sentry breadcrumb can say `-25308` — `errSecInteractionNotAllowed`, the
/// locked-device case — instead of "keychain error".
enum KeychainTokenStoreError: Error {
    case status(OSStatus)
    /// The item was present but its bytes were not what this build stores.
    case unreadableItem
}
