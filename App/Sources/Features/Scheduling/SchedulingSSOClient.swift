import DistrictModel
import DistrictNetwork
import Foundation

/// The scheduler hand-off: one authenticated GET whose 302 is read rather than
/// followed.
///
/// ⛔ IT LIVES IN `App/` RATHER THAN IN `DistrictNetwork`, AND THAT IS THE SAME
/// DECISION `DistrictEndpoints+Scheduling.swift` RECORDS. `GET
/// /api/district/scheduling/sso` answers a 302 and not a JSON body, and it does
/// not belong on ``RedirectEndpoints`` either: that list exists for
/// `calls/{id}/recording`, where following the redirect merely wastes bandwidth.
/// Here following it SPENDS a single-use credential on a transport the user never
/// sees, so the request is issued here, once, and the `Location` is handed
/// straight to a browser sheet.
///
/// ⛔ THE BROWSER SHEET CANNOT MAKE THIS REQUEST ITSELF. `SFSafariViewController`
/// carries neither this app's bearer nor a session cookie (the API path sets none
/// at all, deliberately), so pointing it at the route would land the operator on a
/// sign-in page rather than in their scheduler.
///
/// ⛔ NOTHING HERE LOGS, STORES OR INTERPOLATES THE `Location`. It carries a
/// 60-second single-use JWT in its query string, so every message below is
/// written from the STATUS and never from the header — a "could not read that"
/// diagnostic quoting the value would put a live credential wherever the
/// diagnostic goes.
///
/// ⚠️ A `struct` OVER THE SAME `HTTPTransport` SEAM `ApiClient` USES, so the
/// redirect policy is the transport's existing per-task delegate rather than a
/// second `URLSession` with its own configuration. `URLSessionHTTPTransport`
/// already refuses redirects when asked; see the ⛔ on its delegate.
struct SchedulingSSOClient: Sendable {
    /// ⚠️ SPELLED OUT HERE BECAUSE `DistrictEndpoints` DELIBERATELY DOES NOT
    /// CARRY IT. See the ⛔ at the top of `DistrictEndpoints+Scheduling.swift`.
    private static let ssoPath = "/api/district/scheduling/sso"

    private let baseURL: URL
    private let transport: any HTTPTransport
    private let accessToken: @Sendable () async -> String?

    init(
        baseURL: URL,
        transport: any HTTPTransport,
        accessToken: @escaping @Sendable () async -> String?
    ) {
        self.baseURL = baseURL
        self.transport = transport
        self.accessToken = accessToken
    }

    /// Ask for a hand-off and report where it points, without going there.
    ///
    /// - Parameter next: where the hand-off lands inside the scheduler, which the
    ///   route validates and may drop. ⛔ THE CALENDAR OAUTH ROUND TRIP IS THE ONLY
    ///   CALLER: the provider's consent screen is the provider's, not ours, so there
    ///   is no way to run that round trip through the admin RPC. A console `next`
    ///   answers 410 now the console is retired, which is why there is no default.
    ///   See `SchedulingCalendarConnectModel`.
    func handOffURL(
        workspaceId: String,
        next: String
    ) async -> Result<URL, ApiError> {
        guard let url = requestURL(workspaceId: workspaceId, next: next) else {
            // Unreachable with a non-empty workspace id, and a guard beats a
            // force-unwrap on a path that mints a credential.
            return .failure(.transport("The scheduler sign-in address could not be built."))
        }
        // ⚠️ nil BECOMES A LOCAL 401 rather than an unauthenticated request, which
        // is the rule ``ApiClient`` follows for the same reason: the server would
        // refuse it anyway and the UI owns the sentence.
        guard let token = await accessToken() else {
            return .failure(.http(status: 401, message: nil))
        }
        let request = HTTPRequest(
            method: .get,
            url: url,
            headers: ["Authorization": "Bearer \(token)", "Accept": "application/json"],
            body: nil
        )
        do {
            let response = try await transport.send(request, followRedirects: false)
            return Self.target(from: response)
        } catch {
            // ⚠️ The cause is the REQUEST's, and the request URL carries no token.
            return .failure(.transport(String(describing: error)))
        }
    }

    /// ⛔ `percentEncodedQueryItems` WITH OUR OWN ENCODER, NOT `queryItems`, AND THE
    /// DIFFERENCE IS A LIVE BUG THE MOMENT A `next` CARRIES A QUERY OF ITS OWN.
    /// `URLComponents` encodes a query value against `CharacterSet.urlQueryAllowed`,
    /// which CONTAINS `?`, `&`, `=` and `/` — so
    /// `next=/v1/calendar/connect?provider=google&return_to=…` would cross the wire
    /// with those characters literal, and the route would parse `return_to` as a
    /// sibling parameter and see a `next` it never sent. That failure is silent at
    /// every step: `safeNextPath` drops what is left, the SSO route still 302s, and
    /// the operator lands on the scheduler's default page instead of the consent
    /// screen.
    private func requestURL(workspaceId: String, next: String) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        components.path = Self.ssoPath
        components.percentEncodedQueryItems = [
            URLQueryItem(name: "workspaceId", value: Self.encode(workspaceId)),
            URLQueryItem(name: "next", value: Self.encode(next)),
        ]
        return components.url
    }

    /// ⚠️ RFC 3986 UNRESERVED ONLY, WHICH IS STRICTER THAN `encodeURIComponent` AND
    /// DECODES IDENTICALLY. The browser half leaves `!'()*` alone; escaping them too
    /// changes no meaning and removes the question of whether a given server's
    /// parser agrees about them.
    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    private static let unreserved: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    /// ⛔ HTTPS ONLY, CHECKED HERE RATHER THAN TRUSTED. `SFSafariViewController`
    /// accepts only `http` and `https` and traps on anything else, so an
    /// unexpected scheme would be a crash rather than a refusal; and a hand-off
    /// that is not TLS would put the token on the wire in clear. The route builds
    /// `https://<publicHost>/v1/auth/sso`, so anything else is contract drift.
    private static func target(from response: HTTPResponse) -> Result<URL, ApiError> {
        guard (300 ... 399).contains(response.statusCode) else {
            return .failure(ApiErrorNormalizer.apiError(statusCode: response.statusCode, body: response.body))
        }
        guard let location = response.header("Location"), !location.isEmpty else {
            return .failure(.decoding(
                "The server redirected without saying where (HTTP \(response.statusCode))."
            ))
        }
        guard let url = URL(string: location), url.scheme?.lowercased() == "https" else {
            return .failure(.decoding("The scheduler sign-in address was not an https address."))
        }
        return .success(url)
    }
}
