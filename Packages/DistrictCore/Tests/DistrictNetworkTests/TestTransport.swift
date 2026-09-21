@testable import DistrictNetwork
import Foundation

/// The ``HTTPTransport`` double.
///
/// ⚠️ IT RECORDS THE REQUEST AND THE `followRedirects` FLAG, because the flag is
/// half of the recording-route trap: a transport asked to follow the 302 would
/// download the whole audio file, and nothing about the resulting URL would look
/// wrong.
final class TestTransport: HTTPTransport, @unchecked Sendable {
    struct Recorded {
        let request: HTTPRequest
        let followRedirects: Bool
    }

    private let lock = NSLock()
    private var responses: [Result<HTTPResponse, Error>]
    private(set) var recorded: [Recorded] = []

    init(_ responses: [Result<HTTPResponse, Error>]) {
        self.responses = responses
    }

    convenience init(status: Int, headers: [String: String] = [:], body: Data? = nil) {
        self.init([.success(HTTPResponse(statusCode: status, headers: headers, body: body))])
    }

    convenience init(json: String, status: Int = 200) {
        self.init(status: status, headers: ["Content-Type": "application/json"], body: Data(json.utf8))
    }

    convenience init(throwing error: Error) {
        self.init([.failure(error)])
    }

    var lastRequest: HTTPRequest? {
        lock.lock()
        defer { lock.unlock() }
        return recorded.last?.request
    }

    var lastFollowedRedirects: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return recorded.last?.followRedirects
    }

    func send(_ request: HTTPRequest, followRedirects: Bool) async throws -> HTTPResponse {
        // ⚠️ `withLock`, not `lock()`/`unlock()`: the bare pair is unavailable
        // from an async context because a suspension between them would hold the
        // lock across a hop.
        let next: Result<HTTPResponse, Error>? = lock.withLock {
            recorded.append(Recorded(request: request, followRedirects: followRedirects))
            return responses.isEmpty ? nil : responses.removeFirst()
        }

        guard let next else {
            throw TransportStub.exhausted
        }
        return try next.get()
    }
}

enum TransportStub: Error, Equatable {
    case exhausted
    case offline
}

extension ApiClient {
    /// A client wired to a double, with a fixed multipart boundary so bodies can
    /// be asserted byte for byte.
    static func test(
        _ transport: TestTransport,
        accessToken: String? = "session-token"
    ) -> ApiClient {
        ApiClient(
            baseURL: URL(string: EndpointTable.host)!,
            transport: transport,
            accessToken: { accessToken },
            boundary: { "test-boundary" }
        )
    }
}
