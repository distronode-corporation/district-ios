import DistrictNetwork
import Foundation

/// The one concrete ``HTTPTransport``: Darwin `URLSession`.
///
/// ⛔ IT LIVES IN `App/` AND NOT IN THE PACKAGE, WHICH IS THE ARCHITECTURE
/// RATHER THAN A FILING CHOICE. `URLSession` on Linux is libcurl-backed and
/// differs from Darwin's in redirect handling, header casing and error domains,
/// so `swift test` on the Linux tier could neither exercise this file nor trust
/// what it measured. Keeping it here leaves `DistrictNetwork` at a coverage floor
/// it can actually meet, and leaves this class as the single place a platform
/// difference is allowed to exist.
///
/// ⚠️ NOTHING HERE IS COVERED BY A UNIT TEST. Its real exercise is a device build
/// talking to the real server. Keep it boring for that reason: no retry
/// policy, no caching cleverness, no error re-mapping beyond what the protocol
/// asks for.
final class URLSessionHTTPTransport: NSObject, HTTPTransport, URLSessionTaskDelegate, @unchecked Sendable {
    /// ⚠️ 30s, applied to the REQUEST rather than to the whole resource. A
    /// resource timeout would also cap a slow media upload
    /// (`messages/media` accepts up to 5MB), which is a different thing from a
    /// server that has stopped answering.
    private static let requestTimeout: TimeInterval = 30

    private let session: URLSession

    /// - Parameter configuration: injectable for a future test host only.
    ///   Production uses `.default`.
    init(configuration: URLSessionConfiguration = .default) {
        configuration.timeoutIntervalForRequest = Self.requestTimeout
        // ⛔ NO COOKIES ON THE API PATH. Every request this transport carries is
        // authorised by a bearer token attached by `ApiClient`; a cookie jar
        // shared with the login browser would be a second, ambient credential
        // travelling on calls that never asked for one.
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        session = URLSession(configuration: configuration)
        super.init()
    }

    func send(_ request: HTTPRequest, followRedirects: Bool) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        // ⛔ THE DELEGATE IS THE WHOLE REDIRECT POLICY, AND IT IS ATTACHED PER
        // TASK RATHER THAN PER SESSION. `calls/{id}/recording` answers 302 with a
        // `Location` that ``ApiClient/redirectTarget(_:)`` hands to AVPlayer;
        // following it here would download the entire audio file through this
        // process, on a metered connection, purely to learn its address — and the
        // presigned URL is short-lived, so the second fetch has to happen anyway.
        // A session-wide delegate would apply that policy to every other call as
        // well, including the ordinary API redirects there is no reason to
        // refuse.
        let (data, response) = try await session.data(
            for: urlRequest,
            delegate: followRedirects ? nil : self
        )

        guard let http = response as? HTTPURLResponse else {
            // Unreachable over http(s) — every response there is an
            // HTTPURLResponse — but a `guard` beats a force-cast on a path that
            // no test can reach.
            throw URLSessionHTTPTransportError.notAnHTTPResponse
        }

        return HTTPResponse(
            statusCode: http.statusCode,
            headers: Self.headers(from: http),
            body: data
        )
    }

    // ── URLSessionTaskDelegate ───────────────────────────────────────────────

    /// Refuse every redirect, surfacing the 3xx itself.
    ///
    /// ⛔ `completionHandler(nil)` MEANS "HAND ME THE REDIRECT RESPONSE", NOT
    /// "FAIL". `URLSession` then completes the task with the 3xx response and its
    /// headers, which is exactly the shape ``ApiClient/redirectTarget(_:)`` reads
    /// — it requires a status in 300...399 and a non-empty `Location`, and treats
    /// a 3xx WITHOUT one as contract drift.
    ///
    /// ⚠️ ONLY ATTACHED WHEN `followRedirects` IS FALSE (see `send`), so this
    /// never sees an ordinary call.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    // ── Internals ────────────────────────────────────────────────────────────

    /// ⚠️ Darwin canonicalises header names (`location` arrives as `Location`)
    /// and the Linux transport does not, which is why ``HTTPResponse/header(_:)``
    /// is case-insensitive. Nothing is normalised here: the package already
    /// absorbs the difference, and lowercasing on the way in would only make this
    /// transport disagree with the one the tests use.
    private static func headers(from response: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for (name, value) in response.allHeaderFields {
            guard let name = name as? String, let value = value as? String else { continue }
            headers[name] = value
        }
        return headers
    }
}

enum URLSessionHTTPTransportError: Error {
    case notAnHTTPResponse
}
