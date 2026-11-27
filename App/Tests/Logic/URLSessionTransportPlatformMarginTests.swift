@testable import DistrictAI
import DistrictNetwork
import Foundation
import XCTest

/// ``URLSessionHTTPTransport`` over a real Darwin `URLSession` whose only protocol class is a stub
/// defined here, so the method, headers, body, status, the redirect policy and a transport error
/// are each read back from what `URLSession` really did rather than from a fake transport.
final class URLSessionTransportPlatformMarginTests: XCTestCase {
    private var host = ""

    override func setUp() {
        super.setUp()
        // ⚠️ ONE HOST PER TEST: the stub's answers are keyed by host, so no test reads another's.
        host = "\(UUID().uuidString.lowercased()).transport.test"
    }

    override func tearDown() {
        TransportStubProtocol.clear(host: host)
        super.tearDown()
    }

    private func transport(timeout: TimeInterval = 7) -> (URLSessionHTTPTransport, URLSessionConfiguration) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TransportStubProtocol.self]
        return (URLSessionHTTPTransport(configuration: configuration, requestTimeout: timeout), configuration)
    }

    private func url(_ path: String) throws -> URL {
        try XCTUnwrap(URL(string: "https://\(host)\(path)"))
    }

    // MARK: - The configuration it is handed

    func testInitAppliesTheRequestTimeoutAndRefusesCookies() {
        let (_, configuration) = transport(timeout: 5)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 5)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
    }

    func testTheDefaultRequestTimeoutIsThirtySeconds() {
        XCTAssertEqual(URLSessionHTTPTransport.defaultRequestTimeout, 30)
        let configuration = URLSessionConfiguration.ephemeral
        _ = URLSessionHTTPTransport(configuration: configuration)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 30)
    }

    // MARK: - What goes out

    func testSendCarriesTheMethodHeadersAndBody() async throws {
        TransportStubProtocol.answer(host: host) { _ in .reply(
            status: 201,
            headers: ["X-Echo": "yes"],
            body: Data("ok".utf8)
        ) }
        let (sut, _) = transport()
        let body = Data(#"{"name":"Desk ü"}"#.utf8)
        let request = try HTTPRequest(
            method: .post,
            url: url("/api/district/messages"),
            headers: ["Authorization": "Bearer abc", "Content-Type": "application/json"],
            body: body
        )

        let response = try await sut.send(request, followRedirects: true)

        let seen = try XCTUnwrap(TransportStubProtocol.requests(host: host).first)
        XCTAssertEqual(seen.method, "POST")
        XCTAssertEqual(seen.path, "/api/district/messages")
        XCTAssertEqual(seen.headers["Authorization"], "Bearer abc")
        XCTAssertEqual(seen.headers["Content-Type"], "application/json")
        XCTAssertEqual(seen.body, body)
        XCTAssertEqual(response.statusCode, 201)
        XCTAssertEqual(response.header("x-echo"), "yes")
        XCTAssertEqual(response.body, Data("ok".utf8))
    }

    func testEveryMethodGoesOutAsItsRawValue() async throws {
        TransportStubProtocol.answer(host: host) { _ in .reply(status: 204, headers: [:], body: Data()) }
        let (sut, _) = transport()
        for method in HTTPMethod.allCases {
            _ = try await sut.send(
                HTTPRequest(method: method, url: url("/m"), headers: [:], body: nil),
                followRedirects: true
            )
        }
        XCTAssertEqual(TransportStubProtocol.requests(host: host).map(\.method), HTTPMethod.allCases.map(\.rawValue))
    }

    func testANilBodyGoesOutEmpty() async throws {
        TransportStubProtocol.answer(host: host) { _ in .reply(status: 200, headers: [:], body: Data()) }
        let (sut, _) = transport()
        _ = try await sut.send(
            HTTPRequest(method: .get, url: url("/x"), headers: [:], body: nil),
            followRedirects: true
        )
        XCTAssertEqual(TransportStubProtocol.requests(host: host).first?.body, Data())
    }

    // MARK: - What comes back

    func testAServerErrorIsAResponseNotAThrow() async throws {
        TransportStubProtocol.answer(host: host) { _ in
            .reply(status: 500, headers: ["Content-Type": "application/json"], body: Data(#"{"error":"boom"}"#.utf8))
        }
        let (sut, _) = transport()
        let response = try await sut.send(
            HTTPRequest(method: .get, url: url("/fail"), headers: [:], body: nil),
            followRedirects: true
        )
        XCTAssertEqual(response.statusCode, 500)
        XCTAssertEqual(response.header("CONTENT-TYPE"), "application/json")
        XCTAssertEqual(response.body, Data(#"{"error":"boom"}"#.utf8))
    }

    func testATransportErrorIsThrownRaw() async throws {
        TransportStubProtocol.answer(host: host) { _ in .fail(URLError(.timedOut)) }
        let (sut, _) = transport()
        do {
            _ = try await sut.send(
                HTTPRequest(method: .get, url: url("/slow"), headers: [:], body: nil),
                followRedirects: true
            )
            XCTFail("a timed-out request must throw")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        }
    }

    func testAnOfflineErrorIsThrownRawOnTheNoRedirectPathToo() async throws {
        TransportStubProtocol.answer(host: host) { _ in .fail(URLError(.notConnectedToInternet)) }
        let (sut, _) = transport()
        do {
            _ = try await sut.send(
                HTTPRequest(method: .post, url: url("/sso"), headers: [:], body: nil),
                followRedirects: false
            )
            XCTFail("an offline request must throw")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        }
    }

    // MARK: - The redirect policy

    func testARefusedRedirectSurfacesTheThreeOhTwoAndItsLocation() async throws {
        let target = try url("/landing?token=single-use")
        TransportStubProtocol.answer(host: host) { path in
            path == "/landing" ? .reply(status: 200, headers: [:], body: Data("followed".utf8)) : .redirect(to: target)
        }
        let (sut, _) = transport()

        let response = try await sut.send(
            HTTPRequest(method: .post, url: url("/api/district/scheduling/sso"), headers: [:], body: nil),
            followRedirects: false
        )

        XCTAssertEqual(response.statusCode, 302)
        XCTAssertEqual(response.header("location"), target.absoluteString)
        // ⛔ The single-use location was never requested.
        XCTAssertEqual(TransportStubProtocol.requests(host: host).map(\.path), ["/api/district/scheduling/sso"])
    }

    func testAFollowedRedirectLandsOnTheTarget() async throws {
        let target = try url("/landing")
        TransportStubProtocol.answer(host: host) { path in
            path == "/landing" ? .reply(status: 200, headers: [:], body: Data("followed".utf8)) : .redirect(to: target)
        }
        let (sut, _) = transport()

        let response = try await sut.send(
            HTTPRequest(method: .get, url: url("/start"), headers: [:], body: nil),
            followRedirects: true
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, Data("followed".utf8))
        XCTAssertEqual(TransportStubProtocol.requests(host: host).map(\.path), ["/start", "/landing"])
    }
}

/// A `URLProtocol` answering from a per-host table, recording every request it was handed.
final class TransportStubProtocol: URLProtocol {
    enum Answer: Sendable {
        case reply(status: Int, headers: [String: String], body: Data)
        case redirect(to: URL)
        case fail(URLError)
    }

    struct Seen: Sendable {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var answers: [String: @Sendable (String) -> Answer] = [:]
    private nonisolated(unsafe) static var seen: [String: [Seen]] = [:]

    static func answer(host: String, _ answer: @escaping @Sendable (String) -> Answer) {
        lock.withLock { answers[host] = answer }
    }

    static func requests(host: String) -> [Seen] {
        lock.withLock { seen[host] ?? [] }
    }

    static func clear(host: String) {
        lock.withLock {
            answers[host] = nil
            seen[host] = nil
        }
    }

    override static func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return lock.withLock { answers[host] != nil }
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url, let host = url.host else { return }
        let record = Seen(
            method: request.httpMethod ?? "",
            path: url.path,
            headers: request.allHTTPHeaderFields ?? [:],
            body: Self.body(of: request)
        )
        let handler = Self.lock.withLock { () -> (@Sendable (String) -> Answer)? in
            Self.seen[host, default: []].append(record)
            return Self.answers[host]
        }
        guard let answer = handler?(url.path) else { return }
        switch answer {
        case let .reply(status, headers, body):
            finish(status: status, headers: headers, body: body)
        case let .redirect(target):
            let headers = ["Location": target.absoluteString]
            if let response = HTTPURLResponse(
                url: url,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            ) {
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            }
            // ⚠️ When the redirect is refused, the session completes with this response instead.
            finish(status: 302, headers: headers, body: Data())
        case let .fail(error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private func finish(status: Int, headers: [String: String], body: Data) {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: status,
                  httpVersion: "HTTP/1.1",
                  headerFields: headers
              )
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    /// `URLSession` hands a protocol the body as a stream, not as `httpBody`.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
