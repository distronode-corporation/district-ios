import Foundation

/// A 2xx body this client does not have a DTO for yet.
///
/// ⛔ A DELIBERATE PLACEHOLDER WITH A BURN-DOWN, NOT A PERMANENT ESCAPE HATCH.
/// The contract gate wires every fixture in with a counted, printed skip-list so the
/// DTO burn-down is visible; ``UntypedEndpoints/all`` is the same idea one layer
/// up, listing every endpoint still answering as bytes. An endpoint leaves that
/// list the day its fixture is implemented and its DTO lands in `DistrictModel`.
///
/// ⚠️ THE PARSE IS LENIENT AND THAT IS THE SHIPPED BEHAVIOUR ON PURPOSE. Strict
/// in the gate, lenient in the field: a field added server-side reds CI through
/// the contract fixtures, and degrades to "ignored" on already-installed builds
/// rather than breaking every response on every phone.
public struct RawResponse: Sendable, Equatable {
    public let statusCode: Int
    /// The bytes exactly as they arrived.
    public let body: Data
    /// The parsed document, or nil when the body was empty or not JSON at all.
    ///
    /// ⚠️ NIL IS NOT AN ERROR HERE. A captive portal answers 200 with an HTML
    /// login page for every request the app makes; a caller that needs JSON
    /// should say so rather than assume.
    public let json: JSONValue?

    init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
        json = JSONWire.decode(body)
    }
}

/// A redirect the client refused to follow.
///
/// ⛔ THE RECORDING ROUTE ANSWERS 302 AND THE `Location` IS THE ANSWER. Following
/// it would stream the whole audio file through this process to learn its
/// address. ⚠️ AND THE URL IS PERISHABLE — a presigned object URL — so it must be
/// resolved at the moment of playback and never cached or persisted.
public struct RedirectTarget: Sendable, Equatable {
    public let statusCode: Int
    public let location: String
}
