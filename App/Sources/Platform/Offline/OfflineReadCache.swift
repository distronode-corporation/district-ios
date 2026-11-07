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
final class OfflineReadCache: Sendable {
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

    private let directory: URL
    private let now: @Sendable () -> Date

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

    /// Keeps a successful answer. Does nothing for a request the cache does not keep,
    /// an empty body or one over ``maximumBodyBytes``.
    func store(_ body: Data, for request: HTTPRequest) {
        guard Self.isCacheable(request), !body.isEmpty, body.count <= Self.maximumBodyBytes else { return }
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
    }

    /// The saved answer for a request, or nil when there is none or it is older than
    /// ``maximumAge``.
    func entry(for request: HTTPRequest) -> Entry? {
        guard Self.isCacheable(request), let data = try? Data(contentsOf: file(for: request)), data.count > 8 else {
            return nil
        }
        let bits = data.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let savedAt = Date(timeIntervalSince1970: Double(bitPattern: bits))
        let age = now().timeIntervalSince(savedAt)
        guard age >= 0, age <= Self.maximumAge else { return nil }
        return Entry(body: Data(data.dropFirst(8)), savedAt: savedAt)
    }

    /// Removes every saved answer. Runs on sign-out, so the next account on this
    /// device never sees the last one's data.
    func clear() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func file(for request: HTTPRequest) -> URL {
        let language = request.headers.first { $0.key.lowercased() == "accept-language" }?.value ?? ""
        let key = "\(request.method.rawValue) \(request.url.absoluteString) \(language)"
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest)
    }
}
