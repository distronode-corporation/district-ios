import Foundation

/// One query parameter, which may be absent.
///
/// ⛔ A NIL VALUE IS DROPPED, NOT SENT EMPTY, AND THAT IS LOAD-BEARING ON THREE
/// ROUTES. The server reads `searchParams.get("x")` and distinguishes ABSENT
/// from PRESENT-BUT-EMPTY:
///
///   - `overview` re-derives the workspace when `workspaceId` is absent, and
///     fails its id pattern when it is present and empty;
///   - `timeline`'s cursor pair — `before=` present-but-empty becomes
///     `new Date("")`, an Invalid Date, and the route answers **400**, so every
///     thread open would break;
///   - `workspace/usage` switches its whole response TYPE on `history`, and the
///     single-month read is genuinely `history` absent rather than
///     `history=false`.
public struct ApiQueryItem: Sendable, Equatable {
    public let name: String
    public let value: String?

    public init(_ name: String, _ value: String?) {
        self.name = name
        self.value = value
    }
}

/// A `multipart/form-data` body: text fields plus exactly one file part.
public struct MultipartBody: Sendable, Equatable {
    /// ⚠️ SENT AS PARTS, NOT AS QUERY PARAMETERS. `messages/media` reads
    /// `workspaceId` off `req.formData()`; a query parameter leaves it undefined
    /// and trips the guard's 400 while the URL looks perfectly correct.
    public let fields: [String: String]
    /// ⚠️ Carried for the server's benefit only — the route stores the mime type
    /// and the byte length and never reads it — but omitting it makes the part a
    /// plain field rather than a file, and `file instanceof File` then fails.
    public let fileName: String
    public let contentType: String
    public let bytes: Data

    public init(fields: [String: String], fileName: String, contentType: String, bytes: Data) {
        self.fields = fields
        self.fileName = fileName
        self.contentType = contentType
        self.bytes = bytes
    }

    /// ⛔ THE SERVER READS `form.get("file")` AND NOTHING ELSE. A part named
    /// `image`, `upload` or `attachment` is not an error — the route simply does
    /// not find a file and answers 400 "Missing file field", which reads like a
    /// client that sent no body at all.
    public static let filePartName = "file"
}

/// What travels in the request body, if anything.
public enum ApiBody: Sendable, Equatable {
    /// ⚠️ Genuinely no body. Every GET here, and every DELETE — all four of this
    /// API's deletes read QUERY parameters and would ignore a body.
    case none
    /// ⚠️ Built through ``JSONValue/object(_:)``, which drops nils. See the ⛔ on
    /// ``JSONValue``.
    case json(JSONValue)
    case multipart(MultipartBody)
}

/// One fully-described request: the verb, the path as SEGMENTS, the query and
/// the body.
///
/// ⛔ THE INITIALISER IS INTERNAL, AND THAT IS THE `calls/outbound` GUARD. A
/// public initialiser taking a segment list would let any caller — feature code,
/// a future repository, a well-meant helper — address `calls/outbound` (the AI
/// campaign dialer, which puts the voice agent on a human's line) or any other
/// route this client has deliberately not ported. Because only
/// ``DistrictEndpoints`` can construct one, the set of expressible requests is
/// exactly ``EndpointID/allCases``.
///
/// ⛔ SEGMENTS, NEVER AN INTERPOLATED STRING. A call id of `a/../../admin`
/// interpolated into `calls/{id}/transcript` resolved to
/// `/api/district/admin/transcript` on the Kotlin client before its paths were
/// built this way. ``ApiPath/build(_:)`` encodes each element separately.
public struct ApiRequestDescriptor: Sendable, Equatable {
    public let id: EndpointID
    public let method: HTTPMethod
    public let segments: [String]
    public let query: [ApiQueryItem]
    public let body: ApiBody

    init(
        _ id: EndpointID,
        _ method: HTTPMethod,
        _ segments: [String],
        query: [ApiQueryItem] = [],
        body: ApiBody = .none
    ) {
        self.id = id
        self.method = method
        self.segments = segments
        self.query = query
        self.body = body
    }
}
