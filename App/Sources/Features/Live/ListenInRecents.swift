import CryptoKit
import DistrictModel
import Foundation
import Intents
import Observation
import Security

/// The per-install key the Recents map is keyed with. ⚠️ A seam: the Keychain in the app, memory
/// in a test (an unsigned simulator build has no Keychain at all).
protocol ListenInRecentsKeyStore: Sendable {
    /// The key, made on first use; nil when it cannot be kept (then nothing is remembered).
    func key() -> SymmetricKey?
    /// Forget the key: every entry made with it can no longer be found.
    func rotate()
}

/// ``ListenInRecentsKeyStore`` in the Keychain: this device only, after first unlock, never synced.
struct KeychainListenInRecentsKeyStore: ListenInRecentsKeyStore {
    static let service = "com.distronode.district.listen-in-recents"
    static let account = "hmac-key"

    func key() -> SymmetricKey? {
        if let data = read() {
            return SymmetricKey(data: data)
        }
        let made = SymmetricKey(size: .bits256)
        let data = made.withUnsafeBytes { Data($0) }
        let added: [String: Any] = base.merging([
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]) { $1 }
        guard SecItemAdd(added as CFDictionary, nil) == errSecSuccess else { return nil }
        return made
    }

    func rotate() {
        SecItemDelete(base as CFDictionary)
    }

    private var base: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrSynchronizable as String: false,
        ]
    }

    private func read() -> Data? {
        var result: AnyObject?
        let query = base.merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { $1 }
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
}

/// The listen-ins the system's Recents list shows, so a tap there reopens the call (Sean,
/// 2026-11-05: "Reopen the Live screen").
///
/// ⛔ iOS HANDS BACK ONLY THE HANDLE. A Recents tap arrives as an `INStartCallIntent` naming the
/// person the call was reported with (``SuperviseModel/handle(for:)``), never the CallKit UUID,
/// so the app remembers which call each listen-in handle was. ⚠️ A number the person also
/// dialled from the keypad maps to the latest listen-in on it; the system draws one row per
/// handle either way.
///
/// ⛔ THE KEY IS AN HMAC OF THE HANDLE UNDER A RANDOM PER-INSTALL KEY IN THE KEYCHAIN (xhigh
/// review of PR #101, item 7): a plain hash of a phone number is reversed by trying every number.
/// The value is a workspace id, a call id and a time; the newest ``limit`` are kept, and
/// ``clear()`` (sign-out, a session that must sign in again) drops them and rotates the key.
///
/// ⚠️ OBSERVABLE FOR ``pending`` ONLY: the root view catches a Recents tap even before the shell
/// exists (a cold launch), and the shell resolves it when it can.
@MainActor
@Observable
final class ListenInRecents {
    struct Entry: Codable, Equatable {
        let workspaceId: String
        let callId: String
        let at: Date
    }

    /// What a Recents tap arrives as. ⛔ Listed in project.yml's `NSUserActivityTypes`.
    static let activityType = "INStartCallIntent"

    static let limit = 20
    static let defaultsKey = "live.listenInRecents"

    /// A Recents tap not yet acted on, by handle.
    var pending: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keys: any ListenInRecentsKeyStore
    @ObservationIgnored private let now: () -> Date

    init(
        defaults: UserDefaults = .standard,
        keys: any ListenInRecentsKeyStore = KeychainListenInRecentsKeyStore(),
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.keys = keys
        self.now = now
    }

    /// The person started listening to `callId` under `handle`.
    func record(handle: String, workspaceId: String, callId: String) {
        guard let key = key(handle) else { return }
        var entries = load()
        entries[key] = Entry(workspaceId: workspaceId, callId: callId, at: now())
        if entries.count > Self.limit {
            let newest = entries.sorted { $0.value.at > $1.value.at }.prefix(Self.limit)
            entries = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
        }
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    /// The listen-in a Recents row with this handle was, if this device remembers one.
    func entry(forHandle handle: String) -> Entry? {
        key(handle).flatMap { load()[$0] }
    }

    /// Take the tap waiting to be acted on.
    func takePending() -> String? {
        defer { pending = nil }
        return pending
    }

    /// ⛔ AT SIGN-OUT AND WHEN THE SESSION MUST SIGN IN AGAIN: the next account must not reopen
    /// the last one's calls, and a new key means nothing made under the old one can be found.
    func clear() {
        defaults.removeObject(forKey: Self.defaultsKey)
        keys.rotate()
        pending = nil
    }

    private func load() -> [String: Entry] {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    /// The map key for a handle, or nil when no key can be kept.
    func key(_ handle: String) -> String? {
        guard let secret = keys.key() else { return nil }
        let code = HMAC<SHA256>.authenticationCode(for: Data(Self.normalized(handle).utf8), using: secret)
        return code.map { String(format: "%02x", $0) }.joined()
    }

    /// One form for the same number however the system wrote it back (xhigh review, item 8):
    /// digits only, a ten-digit North American number given its country code. A handle with no
    /// digit (a caller's name) is compared as trimmed, case-folded text.
    ///
    /// ⚠️ NANP ONLY: another country's national form (`020 7946 0018`) does not meet its E.164
    /// (`+442079460018`), and that row's tap does nothing, as before.
    static func normalized(_ handle: String) -> String {
        let digits = handle.filter(\.isASCII).filter(\.isNumber)
        guard !digits.isEmpty else { return handle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        return digits.count == 10 ? "1" + digits : digits
    }

    /// The handle a Recents tap names, or nil for anything else.
    static func handle(of intent: INStartCallIntent) -> String? {
        let value = intent.contacts?.first?.personHandle?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    static func handle(of activity: NSUserActivity) -> String? {
        (activity.interaction?.intent as? INStartCallIntent).flatMap(handle(of:))
    }

    /// ⛔ THE CALL'S LIVE SCREEN WHILE IT IS IN PROGRESS, ITS CALL LOG ENTRY ONCE IT HAS ENDED.
    /// Arriving on either starts nothing (``Route/superviseCall(workspaceId:role:callId:)``).
    static func route(for row: CallSummary, workspaceId: String, role: WorkspaceRole?) -> Route {
        guard CallDisplay(row).transcribesLive else {
            return .callDetail(workspaceId: workspaceId, callId: row.id)
        }
        return .superviseCall(workspaceId: workspaceId, role: role, callId: row.id)
    }
}
