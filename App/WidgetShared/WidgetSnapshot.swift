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
///
/// ⛔ THE COUNTS BELONG TO `workspaceId`, NOT TO THE NAME (cubic, #112): two workspaces can
/// share a display name, and a count read for one must never be shown under the other.
struct WidgetSnapshot: Codable, Equatable, Sendable {
    var workspaceId: String?
    var workspaceName: String?
    var unreadMessages: Int?
    var callsThisWeek: Int?
    /// When ``callsThisWeek`` was read. ⚠️ It is a ROLLING seven-day count, so it goes stale
    /// on its own; see ``callsMaxAge``.
    var callsReadAt: Date?
    var updatedAt: Date

    /// ⚠️ HOW LONG A SEVEN-DAY CALL COUNT IS SHOWN WITHOUT A NEW READ (cubic, #112). The window
    /// moves while the app is closed, and the widget makes no request of its own, so after a
    /// day the count is a dash until Overview is read again rather than a number a day out.
    static let callsMaxAge: TimeInterval = 24 * 60 * 60

    /// The snapshot after `id` became the selected workspace: a different workspace's counts
    /// are dropped rather than shown under the new name. The same workspace keeps its counts
    /// and takes the name it has now (a rename).
    func selecting(workspaceId id: String, name: String, at now: Date) -> WidgetSnapshot {
        guard id == workspaceId else {
            return WidgetSnapshot(workspaceId: id, workspaceName: name, updatedAt: now)
        }
        guard name != workspaceName else { return self }
        var renamed = self
        renamed.workspaceName = name
        renamed.updatedAt = now
        return renamed
    }

    /// What the widget shows at `date`: the call count is a dash once it is older than
    /// ``callsMaxAge``.
    func shown(at date: Date) -> WidgetSnapshot {
        guard let callsReadAt, date < callsReadAt.addingTimeInterval(Self.callsMaxAge) else {
            var expired = self
            expired.callsThisWeek = nil
            return expired
        }
        return self
    }

    /// The widget's timeline from `now`: what it shows now and, while the call count is still
    /// fresh, the moment it turns into a dash. ⚠️ The widget asks for nothing after that; the
    /// app's next write redraws it.
    func timeline(from now: Date) -> [(date: Date, snapshot: WidgetSnapshot)] {
        let current = shown(at: now)
        guard current.callsThisWeek != nil, let callsReadAt else { return [(now, current)] }
        let expiry = callsReadAt.addingTimeInterval(Self.callsMaxAge)
        return [(now, current), (expiry, shown(at: expiry))]
    }
}

extension WidgetSnapshot {
    init(workspaceId: String? = nil, workspaceName: String? = nil, updatedAt: Date) {
        self.init(
            workspaceId: workspaceId,
            workspaceName: workspaceName,
            unreadMessages: nil,
            callsThisWeek: nil,
            callsReadAt: nil,
            updatedAt: updatedAt
        )
    }
}

protocol WidgetSnapshotStoring: Sendable {
    func read() -> WidgetSnapshot?
    func write(_ snapshot: WidgetSnapshot) throws
    func clear() throws
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

    /// ⚠️ THROWS ON A FAILED DELETE (cubic, #112), as ``NotifyTokenKeychain`` does: a snapshot
    /// left behind names a signed-out account's workspace, so the caller retries it
    /// (``WidgetSnapshotPublisher``). Nothing to delete is a success.
    func clear() throws {
        guard let identity = query() else { return }
        let status = SecItemDelete(identity as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw WidgetSnapshotError.status(status)
        }
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
