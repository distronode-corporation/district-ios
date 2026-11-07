import DistrictNetwork
import Foundation
import Observation

/// What the screens need to know about the offline copy: whether the last read they
/// were given came from it, and when it was saved. ``OfflineBanner`` draws it.
@MainActor
@Observable
final class OfflineStatus {
    /// When the shown copy was saved, or nil while the app is reading live answers.
    private(set) var showingSavedAt: Date?

    func servedSaved(_ savedAt: Date) {
        // ⚠️ THE OLDEST COPY ON SCREEN IS THE ONE TO STATE, so a later, fresher
        // answer from the cache does not hide that another screen is older.
        showingSavedAt = min(showingSavedAt ?? savedAt, savedAt)
    }

    func servedLive() {
        showingSavedAt = nil
    }
}

/// The app's transport for the API client, with the read cache in front of it.
///
/// ⛔ READS ONLY, AND ONLY WHEN THE SERVICE CANNOT BE REACHED. A request goes to the
/// network first, always; the saved copy answers only a cacheable `GET` that failed
/// without reaching the service (``isUnreachable(_:)``). A write is never answered from
/// here: it fails as it did before this type existed.
///
/// ⛔ A REQUEST CARRYING ``offlinePlaceholderToken`` IS NEVER SENT, WHATEVER IT IS. That
/// token is what ``AppContainer/offlineBearer(_:)`` hands the API client when a refresh
/// could not leave the device (`RetryReason.refreshNotSent`). Without it, `ApiClient`
/// turns a missing token into a local 401 before the transport is reached, so a
/// device that went offline after its access token expired showed « Your session has
/// ended » on every screen and never reached the saved copy. The placeholder lets the
/// request reach this type, which answers it from the cache or fails it as offline. It
/// must not reach the service: there it would be a bad credential.
///
/// ⚠️ THE AUTH CLIENT AND THE SCHEDULING SSO CLIENT DO NOT USE THIS TYPE OR THE
/// PLACEHOLDER. They keep the plain transport and the plain bearer.
final class OfflineCachingTransport: HTTPTransport, @unchecked Sendable {
    /// Never a real token: it fails the server's JWT parse and is matched exactly here.
    static let offlinePlaceholderToken = "district-offline-placeholder"

    /// The header a saved answer carries, holding when it was saved (ISO 8601).
    static let savedAtHeader = "X-District-Offline-Saved-At"

    private let inner: any HTTPTransport
    private let cache: OfflineReadCache
    private let status: @Sendable (Date?) async -> Void

    /// - Parameter status: told the save time when a saved answer was served, and nil
    ///   when a cacheable read was answered live.
    init(
        wrapping inner: any HTTPTransport,
        cache: OfflineReadCache,
        status: @escaping @Sendable (Date?) async -> Void
    ) {
        self.inner = inner
        self.cache = cache
        self.status = status
    }

    func send(_ request: HTTPRequest, followRedirects: Bool) async throws -> HTTPResponse {
        if Self.carriesPlaceholder(request) {
            if let saved = await saved(for: request) {
                return saved
            }
            throw URLError(.notConnectedToInternet)
        }
        do {
            let response = try await inner.send(request, followRedirects: followRedirects)
            if OfflineReadCache.isCacheable(request), (200 ..< 300).contains(response.statusCode) {
                if let body = response.body {
                    cache.store(body, for: request)
                }
                await status(nil)
            }
            return response
        } catch {
            guard Self.isUnreachable(error), let saved = await saved(for: request) else { throw error }
            return saved
        }
    }

    /// The saved answer as a 200, or nil when there is none.
    private func saved(for request: HTTPRequest) async -> HTTPResponse? {
        guard let entry = cache.entry(for: request) else { return nil }
        await status(entry.savedAt)
        return HTTPResponse(
            statusCode: 200,
            headers: [
                "Content-Type": "application/json",
                Self.savedAtHeader: ISO8601DateFormatter().string(from: entry.savedAt),
            ],
            body: entry.body
        )
    }

    static func carriesPlaceholder(_ request: HTTPRequest) -> Bool {
        let authorization = request.headers.first { $0.key.lowercased() == "authorization" }?.value
        return authorization == "Bearer \(offlinePlaceholderToken)"
    }

    /// Whether a failure means the service was not reached: the request provably never
    /// left the device (`URLError.isProvablyUnsent`), or it timed out. A read is safe
    /// to answer from the cache either way, because answering it changes nothing.
    static func isUnreachable(_ error: any Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return error.isProvablyUnsent || error.code == .timedOut || error.code == .networkConnectionLost
    }
}

/// The app's one offline cache and its status, shared by the API client's transport,
/// the sign-out that clears it and the banner that states it.
///
/// ⚠️ A NAMESPACE RATHER THAN STORED PROPERTIES ON ``AppContainer``, whose file is at
/// the 500-line `file_length` limit that `--strict` enforces.
@MainActor
enum OfflineRead {
    static let cache = OfflineReadCache()
    static let status = OfflineStatus()

    /// `inner` with the read cache in front of it, reporting to ``status``.
    static func transport(wrapping inner: any HTTPTransport) -> OfflineCachingTransport {
        OfflineCachingTransport(wrapping: inner, cache: cache) { savedAt in
            await MainActor.run {
                if let savedAt {
                    status.servedSaved(savedAt)
                } else {
                    status.servedLive()
                }
            }
        }
    }
}
