import Foundation

/// The verbs this API uses. There is no single mutation convention — see
/// ``ApiRequestDescriptor`` — so the method travels with the descriptor rather
/// than being implied by the helper that sends it.
///
/// ⛔ WITHIN THE CONTACTS SECTION ALONE THERE ARE THREE: `create` is POST with a
/// JSON body, `update` is **PATCH** with a JSON body, and `delete` is **DELETE
/// with query parameters and no body**. A client that assumed POST-with-body
/// would silently not fit two of the three, and the server answers 405 rather
/// than anything that reads as a client bug.
public enum HTTPMethod: String, Sendable, CaseIterable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
}

/// One outbound request, fully resolved: an absolute URL, headers (bearer
/// included) and the bytes of a body if there is one.
///
/// ⚠️ A VALUE TYPE, AND IT MUST STAY REPLAYABLE. ``body`` is `Data` held in
/// memory rather than a stream, for the reason the Kotlin client holds its
/// multipart bytes: a caller that re-sends after a token refresh must be able to
/// write the same body twice. A one-shot stream re-sent would upload zero bytes,
/// which the server accepts as a 400 ("between 1 byte and 5MB") rather than as
/// the transport bug it is.
public struct HTTPRequest: Sendable, Equatable {
    public let method: HTTPMethod
    public let url: URL
    public let headers: [String: String]
    public let body: Data?

    public init(method: HTTPMethod, url: URL, headers: [String: String], body: Data?) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

/// One inbound response: the status, the headers and whatever bytes came back.
///
/// ⚠️ A 3xx IS A LEGITIMATE OUTCOME HERE, NOT AN ERROR. `calls/{id}/recording`
/// answers **302 with a `Location`** and the client must not follow it — see
/// ``ApiClient/redirectTarget(_:)``. That is the whole reason this type carries
/// headers at all.
public struct HTTPResponse: Sendable, Equatable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data?

    public init(statusCode: Int, headers: [String: String] = [:], body: Data? = nil) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    /// Look one header up without caring about case.
    ///
    /// ⚠️ HTTP header names are case-insensitive and the two transports this
    /// package will run against disagree in practice: Darwin's `URLSession`
    /// canonicalises them, the libcurl-backed Linux one does not. A literal
    /// `headers["Location"]` therefore works on a Mac and returns nil on Linux
    /// — which would present as "the recording has no URL" rather than as
    /// a platform difference.
    public func header(_ name: String) -> String? {
        let wanted = name.lowercased()
        for (key, value) in headers where key.lowercased() == wanted {
            return value
        }
        return nil
    }
}

/// The one seam between this package and a real HTTP stack.
///
/// ⛔ NOTHING IN `DistrictNetwork` OR `DistrictData` MAY TOUCH `URLSession`
/// DIRECTLY, AND THAT IS THE ARCHITECTURE RATHER THAN A PREFERENCE. `URLSession`
/// on Linux is libcurl-backed and behaves differently from Darwin's — redirect
/// handling, header casing and error domains all diverge — and this package must
/// keep building and testing on Linux CI. That difference is absorbed at this protocol and must never
/// reach an endpoint or a repository.
///
/// ⚠️ THE CONCRETE `URLSession` ADAPTER LIVES IN `App/`, not here, for the same
/// reason the Keychain token store does: it is the one piece that cannot be
/// exercised by `swift test` on Linux, so keeping it in the package would mean
/// permanently uncoverable lines inside a module with a coverage floor. The
/// package ships the protocol and the tests ship a double.
public protocol HTTPTransport: Sendable {
    /// Perform one request.
    ///
    /// - Parameter followRedirects: ⛔ **false** for the recording route and
    ///   nothing else. Following a 302 there downloads the entire audio file
    ///   through this process purely to learn its address, on a metered
    ///   connection, for a file the player is about to fetch again itself.
    /// - Throws: anything the stack raises. ``ApiClient`` converts a throw into
    ///   ``ApiError/transport(_:)``; no caller above it ever sees one.
    func send(_ request: HTTPRequest, followRedirects: Bool) async throws -> HTTPResponse
}
