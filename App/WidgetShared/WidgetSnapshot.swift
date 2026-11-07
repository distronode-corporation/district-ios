import Foundation
import Security

/// What the Home Screen widget shows: the selected workspace's name, its unread messages
/// and its calls this week, and when the app last knew them.
///
/// ⛔ NOTHING HERE IS A CREDENTIAL, AND NOTHING NAMES A CUSTOMER. The widget draws on the
/// Home Screen of a phone anyone can glance at, and it never makes a request: the app writes
/// this after reads it already does, and the widget only reads it. No contact names, no
/// numbers, no message text.
///
/// ⚠️ EACH COUNT IS OPTIONAL ON ITS OWN. The two come from different screens (the Inbox and
/// Overview); one not read yet is shown as a dash, never as a zero it does not know.
struct WidgetSnapshot: Codable, Equatable, Sendable {
    var workspaceName: String?
    var unreadMessages: Int?
    var callsThisWeek: Int?
    var updatedAt: Date

    /// The snapshot after `name` became the selected workspace: a different workspace's
    /// counts are dropped rather than shown under the new name.
    func selecting(workspace name: String, at now: Date) -> WidgetSnapshot {
        guard name != workspaceName else { return self }
        return WidgetSnapshot(workspaceName: name, unreadMessages: nil, callsThisWeek: nil, updatedAt: now)
    }
}

protocol WidgetSnapshotStoring: Sendable {
    func read() -> WidgetSnapshot?
    func write(_ snapshot: WidgetSnapshot) throws
    func clear()
}

/// The one Keychain item the widget reads, in the `.widget` group
/// (``KeychainAccessGroups/widgetGroup``).
///
/// ⛔ THE GROUP IS NAMED ON EVERY QUERY, as ``NotifyTokenKeychain`` does: a write with no
/// group lands in the app's FIRST group, the private one, where the widget cannot read it.
///
/// ⚠️ nil GROUP, NO-OP: an unsigned build resolves no team prefix, so nothing is written
/// or read and the widget shows its signed-out face. That is why this can only be proved
/// on a signed device install.
struct WidgetSnapshotKeychain: WidgetSnapshotStoring {
    static let service = "com.distronode.district.widget"
    static let account = "home-screen-snapshot"

    let accessGroup: String?

    init(accessGroup: String? = KeychainAccessGroups.widgetGroup) {
        self.accessGroup = accessGroup
    }

    func read() -> WidgetSnapshot? {
        guard var request = query() else { return nil }
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data
        else { return nil }
        return try? Self.decoder.decode(WidgetSnapshot.self, from: data)
    }

    func write(_ snapshot: WidgetSnapshot) throws {
        guard let identity = query() else { return }
        let attributes: [String: Any] = try [
            kSecValueData as String: Self.encoder.encode(snapshot),
            // ⚠️ AFTER FIRST UNLOCK: the widget is drawn on a locked phone's Home Screen
            // after a restart has been unlocked once, which is when its data is needed.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updated = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess {
            return
        }
        guard updated == errSecItemNotFound else { throw WidgetSnapshotError.status(updated) }
        var request = identity
        request.merge(attributes) { _, new in new }
        let added = SecItemAdd(request as CFDictionary, nil)
        guard added == errSecSuccess else { throw WidgetSnapshotError.status(added) }
    }

    func clear() {
        guard let identity = query() else { return }
        SecItemDelete(identity as CFDictionary)
    }

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

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}

enum WidgetSnapshotError: Error, Equatable {
    case status(OSStatus)
}
