import Foundation
import Security

/// The notify-read token, as the notification service extension finds it.
///
/// ⛔ NOT THE SESSION, AND NOT A BEARER FOR ANYTHING BUT ONE ROUTE. The server mints it from
/// the app's session (`POST auth/native/notify-token`) for `GET messages/{id}/sender` alone,
/// and honours it only while this device's session family is alive. It is the one credential
/// in the shared group, because the extension, a second process, has to read it.
struct NotifyToken: Codable, Equatable, Sendable {
    var token: String
    var expiresAt: Date

    /// ⚠️ An expired token is not sent at all: the server would refuse it, and the extension
    /// has five seconds, not a round trip to spare.
    func isLive(at now: Date) -> Bool {
        !token.isEmpty && now < expiresAt
    }

    /// How long before ``expiresAt`` the app mints a new one (the round-2 contract: on
    /// launch, when missing or within seven days of expiry, or after the sender route
    /// answered 401). The token lives 30 days.
    static let renewalWindow: TimeInterval = 7 * 24 * 60 * 60

    /// Whether the app should mint a fresh token now. A missing one always should. The app's
    /// sign-in and every launch with a session ask this (`NotifyTokenRenewal`), then mint with
    /// the core's `NotifyTokenRepository.mint()` and store with ``NotifyTokenKeychain/write(_:)``.
    static func needsRenewal(_ token: NotifyToken?, at now: Date) -> Bool {
        guard let token, token.isLive(at: now) else { return true }
        return token.expiresAt.timeIntervalSince(now) <= renewalWindow
    }
}

/// Reading the notify token, behind a seam so a test can stand in for the Keychain.
protocol NotifyTokenReading: Sendable {
    /// nil when there is none. ⚠️ THROWS when the Keychain cannot answer, which before the
    /// first unlock after a reboot is every time; the extension then leaves the alert as sent.
    func read() throws -> NotifyToken?
}

/// Where the notify token is kept: the app writes and clears it, the extension reads it and
/// clears it after a 401. A seam so both sides' decisions are tested without a Keychain.
protocol NotifyTokenStoring: NotifyTokenReading {
    /// False when nothing can be kept (an unsigned build): the app then mints nothing.
    var canStore: Bool { get }
    func write(_ token: NotifyToken) throws
    func clear() throws
}

extension NotifyTokenStoring {
    /// Clear the stored token if it is still `rejected`, the one a 401 answered.
    ///
    /// ⛔ COMPARED, NOT CLEARED BLINDLY: the app may have minted a fresh token while the
    /// refused request was on the wire, and that one must survive. A Keychain that cannot
    /// answer leaves everything as it is; the server keeps refusing a dead token anyway.
    func clear(ifStill rejected: String) {
        guard let stored = try? read(), stored.token == rejected else { return }
        try? clear()
    }
}

/// The notify token's one Keychain item, in the shared group.
///
/// ⛔ THE SAME TWO ATTRIBUTES AS THE SESSION, FOR THE SAME REASONS (see ``KeychainTokenStore``
/// in the app): `kSecAttrSynchronizable = false`, so no iCloud copy reaches another device,
/// and `AfterFirstUnlockThisDeviceOnly`, so a locked phone can still name a sender while a
/// phone not yet unlocked since its reboot cannot, and no backup carries it.
///
/// ⛔ THE GROUP IS NAMED ON EVERY QUERY, and with no resolved group (an unsigned build)
/// nothing is read or written: an unnamed write would land in the app's private group.
///
/// ⛔ THE APP CLEARS IT ON EVERY TRANSITION INTO SIGNED-OUT (`PushRegistrar.forget()`, through
/// `NotifyTokenRenewal.forget()`). The server refuses it once the family is gone anyway;
/// clearing is what stops a later account on this handset inheriting it.
struct NotifyTokenKeychain: NotifyTokenStoring {
    static let service = "com.distronode.district.notify"
    static let account = "notify-read-token"

    let accessGroup: String?

    var canStore: Bool {
        query() != nil
    }

    init(accessGroup: String? = KeychainAccessGroups.notifyGroup) {
        self.accessGroup = accessGroup
    }

    func read() throws -> NotifyToken? {
        guard var request = query() else { return nil }
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw NotifyTokenKeychainError.unreadableItem }
            do {
                return try JSONDecoder().decode(NotifyToken.self, from: data)
            } catch {
                throw NotifyTokenKeychainError.unreadableItem
            }
        case errSecItemNotFound:
            return nil
        default:
            throw NotifyTokenKeychainError.status(status)
        }
    }

    /// Store a freshly minted token, replacing any other. See ``NotifyToken/needsRenewal(_:at:)``.
    func write(_ token: NotifyToken) throws {
        guard let identity = query() else { throw NotifyTokenKeychainError.noAccessGroup }
        let attributes: [String: Any] = try [
            kSecValueData as String: JSONEncoder().encode(token),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updated = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess {
            return
        }
        guard updated == errSecItemNotFound else { throw NotifyTokenKeychainError.status(updated) }
        var request = identity
        request.merge(attributes) { _, new in new }
        let added = SecItemAdd(request as CFDictionary, nil)
        guard added == errSecSuccess else { throw NotifyTokenKeychainError.status(added) }
    }

    /// Delete it. Nothing to delete, or no group to delete from, is a successful clear.
    func clear() throws {
        guard let identity = query() else { return }
        let status = SecItemDelete(identity as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NotifyTokenKeychainError.status(status)
        }
    }

    /// The item's identity, or nil when there is no group to name.
    func query() -> [String: Any]? {
        guard let accessGroup else { return nil }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: false,
        ]
    }
}

enum NotifyTokenKeychainError: Error {
    case status(OSStatus)
    case unreadableItem
    /// An unsigned build: no shared group to write into.
    case noAccessGroup
}
