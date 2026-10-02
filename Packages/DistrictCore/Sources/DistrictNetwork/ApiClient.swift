import DistrictModel
import Foundation

/// Sends ``ApiRequestDescriptor``s over an ``HTTPTransport`` and normalises
/// every outcome onto ``ApiError``.
///
/// ⛔ THE BEARER IS ATTACHED HERE, THROUGH AN ASYNC CLOSURE, NOT BY A MIDDLEWARE
/// OR AN INTERCEPTOR. Acquiring an access token may mean waiting on a refresh
/// behind a mutex, which is asynchronous; the Kotlin client learned the same
/// thing the hard way (an OkHttp `Interceptor` is synchronous, so wiring it there
/// meant `runBlocking` on a dispatcher thread that the refresh itself needed a
/// connection from). A closure is the smallest thing that can be both async and
/// substituted in a test.
///
/// ⛔ THIS CLIENT DOES NOT RETRY. Not on a 401, not on a 5xx, not on a timeout.
/// A 401 to a request that carried a bearer is REPORTED, through
/// ``RejectedTokenHandler``, with the exact token the server refused; the app
/// hands it to `TokenRefreshCoordinator.invalidateAccessToken(_:)`, so the NEXT
/// call refreshes instead of presenting the same dead token for the rest of its
/// TTL. The failed request itself is returned as a 401 and never resent. The
/// reason a resend must not live here is written across the endpoint surface:
/// `messages/send` bills carrier segments, `messages/draft` bills a
/// Vertex generation, `contacts/enrich` buys a model run, `calls/dial` rings a
/// telephone, `numbers/release` gives up a number for good, and HQ's confirm
/// executes an irreversible write. A retry helper added here would apply to all
/// of them at once.
public struct ApiClient: Sendable {
    /// Supplies a bearer token, possibly after an async refresh. Returning nil
    /// means "there is no credential", which this client reports as a 401 rather
    /// than sending an unauthenticated request the server would refuse anyway.
    public typealias TokenProvider = @Sendable () async -> String?

    /// Told the bearer a 401 answered, so the issuer can stop handing it out.
    ///
    /// ⚠️ THE TOKEN, NOT A FLAG. Two requests can 401 together; the issuer
    /// compares it against what it currently holds, so a late report about an
    /// old token cannot discard the fresh one that replaced it.
    public typealias RejectedTokenHandler = @Sendable (String) async -> Void

    /// ⛔ ONE HOST FOR EVERY REGION. Per-region base URLs were considered and
    /// rejected on the Kotlin side: Cloudflare already routes a request to the
    /// right origin, so region-specific hosts would duplicate that logic in the
    /// client and go stale independently. It also would not help — a workspace's
    /// region is a property of its DATA, not of which origin can serve it, and a
    /// bearer token works on any of them where a host-only session cookie would
    /// not.
    public static let productionBaseURL = URL(string: "https://www.distronode.com")!

    private let baseURL: URL

    /// The API's own host, lowercased.
    ///
    /// ⛔ EXPOSED SO A CALLER CAN REFUSE A FOREIGN ONE, not so it can build URLs.
    /// ``SchedulingHandoffClient`` reads a URL out of a response body and hands it to
    /// a browser; without a host to compare against, "https" alone would let an
    /// influenced body redirect a signed-in operator anywhere. ⚠️ `baseURL` itself
    /// stays private — a caller that could read the whole URL would start assembling
    /// paths by hand, which is exactly what ``ApiRequestDescriptor`` exists to stop.
    public var baseHost: String? {
        baseURL.host?.lowercased()
    }

    private let transport: any HTTPTransport
    private let accessToken: TokenProvider
    private let rejectedToken: RejectedTokenHandler
    private let boundary: @Sendable () -> String

    /// - Parameter rejectedToken: called with the bearer of every request the
    ///   server answered 401. See ``RejectedTokenHandler``.
    /// - Parameter boundary: the multipart boundary generator. ⚠️ Injectable only
    ///   so a test can assert exact bytes; production uses a fresh UUID per
    ///   request.
    public init(
        baseURL: URL = ApiClient.productionBaseURL,
        transport: any HTTPTransport,
        accessToken: @escaping TokenProvider,
        rejectedToken: @escaping RejectedTokenHandler = { _ in },
        boundary: @escaping @Sendable () -> String = { "district-" + UUID().uuidString }
    ) {
        self.baseURL = baseURL
        self.transport = transport
        self.accessToken = accessToken
        self.rejectedToken = rejectedToken
        self.boundary = boundary
    }

    /// Send a descriptor and hand back the raw 2xx body.
    ///
    /// ⚠️ For the endpoints in ``UntypedEndpoints/all``, which is most of them
    /// until the DTO burn-down completes.
    public func send(_ descriptor: ApiRequestDescriptor) async -> Result<RawResponse, ApiError> {
        let outcome = await perform(descriptor, followRedirects: true)
        return outcome.flatMap { response in
            guard ApiErrorNormalizer.isSuccess(response.statusCode) else {
                return .failure(ApiErrorNormalizer.apiError(statusCode: response.statusCode, body: response.body))
            }
            return .success(RawResponse(statusCode: response.statusCode, body: response.body ?? Data()))
        }
    }

    /// Send a descriptor and hand back the response WHATEVER its status, with the
    /// failure body intact.
    ///
    /// ⛔ THIS EXISTS FOR THE ONE CASE WHERE THE ERROR BODY IS THE ANSWER, AND IT
    /// MUST NOT BECOME THE DEFAULT. `GET /api/district/workspace/list` answers
    /// **503 `REGIONS_DEGRADED`** carrying `degradedRegions`, and a client that
    /// rendered that as an empty list would tell a paying customer their account
    /// is gone. ``ApiError`` has nowhere to put a structured body, so a caller
    /// that needs one has to see the bytes.
    ///
    /// ⚠️ THE `Result` STILL FAILS FOR EVERYTHING THAT NEVER PRODUCED A RESPONSE
    /// — an unbuildable path, a missing credential, a dead socket. Only the
    /// status mapping is skipped, so a caller cannot accidentally treat "offline"
    /// as a body it can read.
    public func sendUnmapped(_ descriptor: ApiRequestDescriptor) async -> Result<RawResponse, ApiError> {
        let outcome = await perform(descriptor, followRedirects: true)
        return outcome.map { RawResponse(statusCode: $0.statusCode, body: $0.body ?? Data()) }
    }

    /// Send a descriptor and decode its 2xx body into a DTO.
    ///
    /// ⚠️ A DECODE FAILURE BECOMES ``ApiError/decoding(_:)`` CARRYING NO BODY
    /// PREVIEW. The bodies that fail to decode here are call transcripts, contact
    /// records and message threads, and ``ApiError/message`` can reach a screen.
    /// It does carry the KEY PATH that failed (names only, see
    /// ``ApiErrorNormalizer/decodingReason(statusCode:byteCount:failure:)``), so
    /// contract drift names the field that moved.
    public func send<T: Decodable & Sendable>(
        _ descriptor: ApiRequestDescriptor,
        as type: T.Type
    ) async -> Result<T, ApiError> {
        let outcome = await perform(descriptor, followRedirects: true)
        return outcome.flatMap { response in
            guard ApiErrorNormalizer.isSuccess(response.statusCode) else {
                return .failure(ApiErrorNormalizer.apiError(statusCode: response.statusCode, body: response.body))
            }
            let body = response.body ?? Data()
            do {
                return try .success(JSONDecoder().decode(type, from: body))
            } catch {
                return .failure(.decoding(ApiErrorNormalizer.decodingReason(
                    statusCode: response.statusCode,
                    byteCount: body.count,
                    failure: error
                )))
            }
        }
    }

    /// Send a descriptor that answers a redirect, and report where it points
    /// WITHOUT following it.
    ///
    /// ⛔ THE ONLY CALLER IS `calls/{id}/recording`. See ``RedirectEndpoints``.
    ///
    /// ⚠️ A call with no recording answers **404 with a JSON body**, not a
    /// redirect, so that case falls through to the ordinary error mapping and
    /// arrives as a 404 rather than as a missing `Location`.
    public func redirectTarget(_ descriptor: ApiRequestDescriptor) async -> Result<RedirectTarget, ApiError> {
        let outcome = await perform(descriptor, followRedirects: false)
        return outcome.flatMap { response in
            guard (300 ... 399).contains(response.statusCode) else {
                return .failure(ApiErrorNormalizer.apiError(statusCode: response.statusCode, body: response.body))
            }
            guard let location = response.header("Location"), !location.isEmpty else {
                // A 3xx with no Location is contract drift, not an HTTP failure:
                // the status says "look elsewhere" and the response does not say
                // where.
                return .failure(.decoding(
                    "The server redirected without saying where (HTTP \(response.statusCode))."
                ))
            }
            return .success(RedirectTarget(statusCode: response.statusCode, location: location))
        }
    }

    private func perform(
        _ descriptor: ApiRequestDescriptor,
        followRedirects: Bool
    ) async -> Result<HTTPResponse, ApiError> {
        guard let url = ApiURL.build(base: baseURL, segments: descriptor.segments, query: descriptor.query) else {
            // ⛔ An empty path segment would collapse to `//` and address a
            // DIFFERENT route, so nothing is sent. See ``ApiPath``.
            return .failure(.transport("The request path could not be built (an id was empty)."))
        }

        let contentType: String?
        let body: Data?
        switch descriptor.body {
        case .none:
            contentType = nil
            body = nil
        case let .json(value):
            // ⛔ AN UNENCODABLE BODY FAILS HERE, BEFORE ANYTHING IS SENT. The only
            // way to get here is a non-finite `Double` inside a caller-supplied
            // ``JSONValue`` (HQ's confirm args, a directory row). Sending it empty
            // instead spent a round trip on a destructive route and relied on
            // every route answering 400 to an empty body; throwing out of a send
            // that has no catch above it would take the process.
            guard let encoded = try? JSONWire.encode(value) else {
                return .failure(.transport("The request body could not be encoded (a number was not finite)."))
            }
            contentType = "application/json; charset=utf-8"
            body = encoded
        case let .multipart(part):
            let marker = boundary()
            contentType = "multipart/form-data; boundary=\(marker)"
            body = MultipartEncoder.encode(part, boundary: marker)
        }

        guard let token = await accessToken() else {
            // ⚠️ NO INVENTED MESSAGE. The UI owns the sentence: a session lapse
            // signs out.
            return .failure(.http(status: 401, message: nil))
        }

        var headers = ["Authorization": "Bearer \(token)", "Accept": "application/json"]
        headers["Content-Type"] = contentType

        let request = HTTPRequest(method: descriptor.method, url: url, headers: headers, body: body)
        do {
            let response = try await transport.send(request, followRedirects: followRedirects)
            // ⛔ REPORTED, NOT RETRIED. See the ⛔ on the type: the issuer drops
            // this exact token so the next call refreshes, and this request is
            // returned as the 401 it was.
            if response.statusCode == 401 {
                await rejectedToken(token)
            }
            return .success(response)
        } catch {
            // ⚠️ Carries the cause rather than swallowing it: "offline" and "TLS
            // rejected" need different diagnostics, and this is the only place
            // that distinction exists.
            return .failure(.transport(String(describing: error)))
        }
    }
}

/// Builds a `multipart/form-data` body.
///
/// ⚠️ BY HAND, BECAUSE `URLSession` HAS NO MULTIPART BUILDER ON EITHER PLATFORM
/// and the one thing that must not vary between them is the bytes. Fields are
/// emitted in sorted order so the body is deterministic and can be asserted.
enum MultipartEncoder {
    static func encode(_ part: MultipartBody, boundary: String) -> Data {
        var data = Data()
        // ⚠️ Iterated as sorted PAIRS rather than sorted keys plus a lookup: the
        // lookup would be an optional whose nil branch no input can reach.
        for (key, value) in part.fields.sorted(by: { $0.key < $1.key }) {
            data.append(text: "--\(boundary)\r\n")
            data.append(text: "Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n")
            data.append(text: value + "\r\n")
        }
        data.append(text: "--\(boundary)\r\n")
        // ⛔ THE PART NAME IS `file`. The route reads `form.get("file")` and
        // nothing else; any other name answers 400 "Missing file field", which
        // reads like a client that sent no body at all.
        data.append(
            text: "Content-Disposition: form-data; name=\"\(MultipartBody.filePartName)\"; "
                + "filename=\"\(part.fileName)\"\r\n"
        )
        data.append(text: "Content-Type: \(part.contentType)\r\n\r\n")
        data.append(part.bytes)
        data.append(text: "\r\n--\(boundary)--\r\n")
        return data
    }
}

private extension Data {
    mutating func append(text: String) {
        append(Data(text.utf8))
    }
}
