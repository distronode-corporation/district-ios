import CryptoKit
import DistrictNetwork
import Foundation

/// The last answer to each of a few read requests, kept on disk so the app can show
/// something when it cannot reach the service. Read only: nothing here ever stands in
/// for a write.
///
/// ⛔ ONLY THE READS LISTED IN ``cachedPaths``, AND ONLY A `GET`. They are the screens a
/// person opens first (the workspace list, Overview, Inbox, Calls, Contacts). Anything
/// else, a write above all, goes to the network or fails as it always has.
///
/// ⛔ THE BODIES ARE CUSTOMER DATA, so they live where the rest of the app's data does
/// and no further: the Caches directory (never in a backup), each file with
/// `completeUntilFirstUserAuthentication` protection, and ``clear()`` runs on sign-out.
/// The file name is a SHA-256 of the request, so the directory listing names no
/// workspace, number or person.
///
/// ⚠️ THE LANGUAGE IS PART OF THE KEY. The service answers in the language the request
/// asked for, so a saved French answer is never shown to an English screen.
///
/// ⛔ A SAVE THAT STARTED BEFORE ``clear()`` IS DROPPED. A read in flight when the user
/// signs out would otherwise write the old account's answer back after the wipe, where
/// the next account on this device could be shown it. ``generation`` moves on every
/// clear, and ``store(_:for:generation:)`` refuses a save from an older one.
///
/// ⚠️ BOUNDED: every distinct query is its own file, so each save also removes expired
/// files and keeps at most ``maximumFiles``, newest first.
final class OfflineReadCache: @unchecked Sendable {
    /// A saved answer and when it was saved.
    struct Entry: Equatable, Sendable {
        let body: Data
        let savedAt: Date
    }

    /// The path suffixes whose `GET` answers are kept: the first screens of the app.
    static let cachedPaths: [String] = [
        "/api/district/workspace/list",
        "/api/district/overview",
        "/api/district/conversations",
        "/api/district/calls",
        "/api/district/contacts",
    ]

    /// How long a saved answer may be shown. Older than this it is a different
    /// workspace's week, and the screen says it could not load instead.
    static let maximumAge: TimeInterval = 7 * 24 * 60 * 60

    /// The largest body kept. The lists above are paged; anything larger is unusual
    /// enough to fetch again rather than hold.
    static let maximumBodyBytes = 2 * 1024 * 1024

    /// The most answers kept at once. Five screens, a few workspaces and their first
    /// pages fit easily; older ones are removed first.
    static let maximumFiles = 64

    private let directory: URL
    private let now: @Sendable () -> Date
    // ⚠️ GUARDED BY `lock`, and the save itself runs under it, so a clear cannot slip
    // between the generation check and the write.
    private let lock = NSLock()
    private var currentGeneration = 0

    init(directory: URL = OfflineReadCache.defaultDirectory, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.now = now
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OfflineReadCache", isDirectory: true)
    }

    /// Whether this request's answer is one the cache keeps.
    static func isCacheable(_ request: HTTPRequest) -> Bool {
        guard request.method == .get else { return false }
        let path = request.url.path
        return cachedPaths.contains { path == $0 }
    }

    /// The current generation, read before a request is sent and handed back to
    /// ``store(_:for:generation:)``.
    var generation: Int {
        lock.withLock { currentGeneration }
    }

    /// Keeps a successful answer. Does nothing for a request the cache does not keep,
    /// an empty body, one over ``maximumBodyBytes``, or a save whose request started
    /// before the last ``clear()``.
    func store(_ body: Data, for request: HTTPRequest, generation: Int) {
        guard Self.isCacheable(request), !body.isEmpty, body.count <= Self.maximumBodyBytes else { return }
        lock.withLock {
            guard generation == currentGeneration else { return }
            let stamp = withUnsafeBytes(of: now().timeIntervalSince1970.bitPattern.bigEndian) { Data($0) }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try (stamp + body).write(
                    to: file(for: request),
                    options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
                )
            } catch {
                // ⚠️ A FAILED SAVE COSTS ONLY THE OFFLINE COPY. The live answer has already
                // been returned to the screen; nothing to report.
            }
            prune()
        }
    }

    /// The saved answer for a request that started in `generation`, or nil when there is
    /// none, it is older than ``maximumAge``, or a ``clear()`` has run since the request
    /// started.
    ///
    /// ⛔ THE CHECK AND THE READ RUN UNDER THE LOCK ``clear()`` TAKES, so a sign-out cannot
    /// land between loading the old account's file and handing it back. A request that
    /// started before the sign-out is served nothing, whatever is on disk by then.
    func entry(for request: HTTPRequest, generation: Int) -> Entry? {
        guard Self.isCacheable(request) else { return nil }
        let data: Data? = lock.withLock {
            guard generation == currentGeneration else { return nil }
            return try? Data(contentsOf: file(for: request))
        }
        guard let data, data.count > 8 else { return nil }
        let savedAt = Self.savedAt(data)
        let age = now().timeIntervalSince(savedAt)
        guard age >= 0, age <= Self.maximumAge else { return nil }
        return Entry(body: Data(data.dropFirst(8)), savedAt: savedAt)
    }

    /// Removes every saved answer. Runs on sign-out, so the next account on this
    /// device never sees the last one's data.
    func clear() {
        lock.withLock {
            currentGeneration += 1
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Removes expired files, then the oldest beyond ``maximumFiles``, by the save time
    /// each file starts with (the clock this type is given, not the file system's).
    private func prune() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return }
        let dated = files.map { ($0, Self.savedAt(of: $0) ?? .distantPast) }.sorted { $0.1 > $1.1 }
        let cutoff = now().addingTimeInterval(-Self.maximumAge)
        for (index, item) in dated.enumerated() where index >= Self.maximumFiles || item.1 < cutoff {
            try? FileManager.default.removeItem(at: item.0)
        }
    }

    /// The save time a file starts with: eight big-endian bytes of a `Double`.
    private static func savedAt(of file: URL) -> Date? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 8), head.count == 8 else { return nil }
        return savedAt(head)
    }

    private static func savedAt(_ head: Data) -> Date {
        let bits = head.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return Date(timeIntervalSince1970: Double(bitPattern: bits))
    }

    private func file(for request: HTTPRequest) -> URL {
        let language = request.headers.first { $0.key.lowercased() == "accept-language" }?.value ?? ""
        let key = "\(request.method.rawValue) \(request.url.absoluteString) \(language)"
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest)
    }
}
