import CryptoKit
import DistrictModel
import Foundation
import Intents

/// The listen-ins the system's Recents list shows, so a tap there reopens the call (Sean,
/// 2026-11-05: "Reopen the Live screen").
///
/// ⛔ iOS HANDS BACK ONLY THE HANDLE. A Recents tap arrives as an `INStartCallIntent` naming the
/// person the call was reported with (``SuperviseModel/handle(for:)``), never the CallKit UUID,
/// so the app remembers which call each listen-in handle was. ⚠️ A number the person also
/// dialled from the keypad maps to the latest listen-in on it; the system draws one row per
/// handle either way.
///
/// ⛔ NO NUMBER IS STORED. The key is a SHA-256 of the handle, and the value is a workspace id,
/// a call id and a time; the newest ``limit`` are kept, and ``clear()`` runs at sign-out.
@MainActor
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

    /// A Recents tap that arrived before the workspace list did, by handle.
    var pending: String?

    private let defaults: UserDefaults
    private let now: () -> Date

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
    }

    /// The person started listening to `callId` under `handle`.
    func record(handle: String, workspaceId: String, callId: String) {
        var entries = load()
        entries[Self.key(handle)] = Entry(workspaceId: workspaceId, callId: callId, at: now())
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
        load()[Self.key(handle)]
    }

    /// ⛔ AT SIGN-OUT: the next account must not reopen the last one's calls.
    func clear() {
        defaults.removeObject(forKey: Self.defaultsKey)
        pending = nil
    }

    private func load() -> [String: Entry] {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    static func key(_ handle: String) -> String {
        let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        return SHA256.hash(data: Data(trimmed.utf8)).map { String(format: "%02x", $0) }.joined()
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
