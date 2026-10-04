@testable import DistrictAI
import DistrictData
import DistrictNetwork
import Foundation

/// A transport that answers a queued list of bodies and keeps every request.
///
/// ⛔ ITS OWN COPY IN THE APP TARGET RATHER THAN A SHARED ONE. `DistrictCore`'s
/// `RepositoryTransport` lives in that package's TEST target, which nothing outside it
/// can import — a test bundle is not a product. The alternative was moving a test helper
/// into shipping code, which is a worse trade than thirty lines.
///
/// ⛔ AND IT RECORDS BODIES, WHICH IS THE POINT FOR HALF THIS SURFACE. "Did this save
/// carry the engine id", "did an unreadable rule go back unchanged" and "was a cleared
/// voice sent as an empty string" are all questions about the encoded document rather
/// than about arguments — and `JSONValue.object(_:)` drops a nil pair silently by
/// design, so only the bytes can answer them.
final class SettingsTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [HTTPResponse]
    private(set) var requests: [HTTPRequest] = []

    init(_ bodies: [String], status: Int = 200) {
        responses = bodies.map {
            HTTPResponse(statusCode: status, headers: ["Content-Type": "application/json"], body: Data($0.utf8))
        }
    }

    /// ⚠️ A STATUS PER RESPONSE, for a flow whose read succeeds and whose write is refused.
    init(responses: [(status: Int, body: String)]) {
        self.responses = responses.map {
            HTTPResponse(statusCode: $0.status, headers: ["Content-Type": "application/json"], body: Data($0.body.utf8))
        }
    }

    var bodies: [String] {
        lock.withLock { requests }.compactMap(\.body).compactMap { String(data: $0, encoding: .utf8) }
    }

    var paths: [String] {
        lock.withLock { requests }.map(\.url.path)
    }

    /// ⚠️ A QUEUE THAT HAS RUN DRY ANSWERS 500 rather than hanging or crashing, so a
    /// test that drives one request too many fails on an assertion about behaviour
    /// instead of on a fatal error somewhere in the client.
    func send(_ request: HTTPRequest, followRedirects: Bool) async throws -> HTTPResponse {
        _ = followRedirects
        let next: HTTPResponse? = lock.withLock {
            requests.append(request)
            return responses.isEmpty ? nil : responses.removeFirst()
        }
        return next ?? HTTPResponse(statusCode: 500, headers: [:], body: nil)
    }
}

extension WorkspaceRepository {
    static func settingsTest(_ transport: SettingsTransport) -> WorkspaceRepository {
        WorkspaceRepository(client: ApiClient(
            baseURL: ApiClient.productionBaseURL,
            transport: transport,
            accessToken: { "session-token" }
        ))
    }
}
