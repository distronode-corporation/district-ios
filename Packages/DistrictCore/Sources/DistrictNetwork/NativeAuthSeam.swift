import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// The seam that lets this module decode the native-auth token body without
/// naming the type that models it.
///
/// ⛔ `NativeTokenResponse` LIVES IN `DistrictAuthCore` AND THIS MODULE MUST NOT
/// REACH FOR IT. `DistrictNetwork` is the transport layer; `DistrictAuthCore`
/// owns the credential POLICY (PKCE, mandatory rotation, the single-flight
/// coordinator). The two are siblings — neither depends on the other — and a
/// dependency in either direction to borrow one struct would either drag HTTP
/// into the module that guards the refresh token or point the transport at the
/// policy above it. The shape travels as a constraint instead.
///
/// ⚠️ THE CONFORMANCE IS EMPTY IN `App/`: `NativeTokenResponse` already declares
/// `Decodable`, `Sendable` and a `tokens` projection, so
/// `extension NativeTokenResponse: NativeAuthTokenWire {}` is the whole of it —
/// no adapter, nothing to keep in step. ⛔ And because `App/` is compiled by
/// nothing on the Linux tier, `NativeAuthSeamTests` declares the identical
/// conformance against a MIRROR of that type; if the pattern ever stops
/// compiling, it fails here rather than on the scarcer macOS CI.
public protocol NativeAuthTokenWire: Decodable, Sendable {
    associatedtype Tokens: Sendable

    /// The credential pair, with the transport-level `tokenType` dropped.
    var tokens: Tokens { get }
}

/// The seam that lets this module answer with `DistrictAuthCore.RefreshResult`
/// without naming it.
///
/// ⛔ THE FIVE MEMBERS ARE `RefreshResult`'S FIVE CASES IN ITS OWN SPELLING, AND
/// THAT IS WHAT MAKES `extension RefreshResult: NativeRefreshOutcome {}` AN
/// EMPTY EXTENSION IN `App/`. A Swift enum case witnesses a static requirement,
/// so no mapping function exists anywhere — which is the entire point. A
/// hand-written switch from some mirror enum onto `RefreshResult` would put the
/// security-relevant status map in a second place, on the one tier with no
/// compiler and no tests, which is the debt this file exists to clear.
///
/// ⛔ SO DO NOT ADD, RENAME OR REORDER A MEMBER HERE WITHOUT DOING THE SAME TO
/// `RefreshResult`. A member this protocol requires and that enum does not have
/// breaks the App target — and it breaks it on the macOS tier, which is manual.
/// ``NativeAuthSeamTests`` pins the shape against a mirror for exactly that
/// reason.
public protocol NativeRefreshOutcome: Sendable {
    associatedtype Tokens: Sendable

    /// Rotated successfully (HTTP 200).
    static func success(_ tokens: Tokens) -> Self

    /// A definite 401 `invalid_grant` — the credential is dead.
    static var rejected: Self { get }

    /// HTTP 429, or a 400 the route refused before touching
    /// `rotateNativeSession`. ⛔ NOT a dead credential.
    static var rateLimited: Self { get }

    /// No usable answer — a 5xx, an unreadable 200, an I/O failure. AMBIGUOUS:
    /// the server may have rotated anyway.
    static var transportFailure: Self { get }

    /// The request PROVABLY never left the device. See ``ProvablyUnsentError``.
    static var notSent: Self { get }
}

/// The seam that lets this module answer with `DistrictAuthCore.RevokeOutcome`
/// without naming it — the same arrangement as ``NativeRefreshOutcome``, for the
/// same reason.
///
/// ⛔ TWO MEMBERS AND NOT THREE. A sign-out cannot fail in a way the user should
/// hear about, because the local wipe is unconditional; the only question the
/// answer carries is whether the credential still needs chasing. There is no
/// `rejected` here and adding one would be adding a way to drop a live
/// credential.
public protocol NativeRevokeOutcome: Sendable {
    associatedtype Deferral: NativeRevokeDeferral

    /// HTTP 200 — the ONLY status that lets the credential go.
    static var accepted: Self { get }

    /// Anything else. ⛔ Keep the credential.
    static func deferred(_ deferral: Deferral) -> Self
}

/// The reasons ``NativeRevokeOutcome/deferred(_:)`` carries, in
/// `RevokeDeferral`'s own spelling so the App-side conformance is empty.
///
/// ⛔ DO NOT ADD, RENAME OR REORDER A MEMBER HERE WITHOUT DOING THE SAME TO
/// `RevokeDeferral`. A member this protocol requires and that enum does not have
/// breaks the App target on the manual macOS tier. ``NativeAuthSeamTests`` pins
/// the shape against a mirror for exactly that reason.
public protocol NativeRevokeDeferral: Sendable {
    /// HTTP 503 — the route's write threw; the token may still be live.
    static var serverUnavailable: Self { get }

    /// HTTP 429 — rate-limited before the write, so nothing was revoked.
    static var rateLimited: Self { get }

    /// No answer at all.
    static var notSent: Self { get }

    /// A status this client does not model.
    static func unexpected(status: Int) -> Self
}

/// A transport error that knows whether the request ever left the device.
///
/// ⛔ THIS IS THE `notSent` SEAM, AND IT IS A PROTOCOL RATHER THAN A `URLError`
/// CHECK BECAUSE `DistrictNetwork` MUST NOT ASSUME WHICH STACK IS UNDERNEATH IT.
/// ``HTTPTransport`` exists precisely so a Darwin `URLSession`, a libcurl-backed
/// Linux one and a test double are interchangeable; a client that read one
/// stack's error domain directly would have re-tied the knot the protocol was
/// introduced to cut. Any transport can conform its own error type and answer
/// this question in its own terms.
///
/// ⚠️ AN ERROR THAT DOES NOT CONFORM IS AMBIGUOUS, NEVER UNSENT. See
/// ``NativeAuthClient/refresh(refreshToken:)``: the cost of a false "unsent" is a
/// revoked token family, and the cost of a false "ambiguous" is one re-login.
public protocol ProvablyUnsentError: Error {
    /// Whether the request provably never reached the server.
    var isProvablyUnsent: Bool { get }
}

/// ⚠️ THE CONFORMANCE LIVES HERE RATHER THAN IN `App/` BECAUSE THE ONE CONCRETE
/// TRANSPORT THROWS `URLError` RAW. `URLSessionHTTPTransport` deliberately does
/// no error re-mapping (see its own doc comment), so if this classification sat
/// next to it, it would sit in the only file in the project that no test can
/// reach. `URLError` is a Foundation value type — on Linux it arrives through
/// `FoundationNetworking` — so it costs this module nothing and is testable here.
extension URLError: ProvablyUnsentError {
    /// ⛔ CONSERVATIVE BY CONSTRUCTION: anything not on this list is treated as
    /// ambiguous. The cost of a false "unsent" is presenting a spent refresh
    /// token and having the whole family revoked as theft; the cost of a false
    /// "ambiguous" is one re-login.
    ///
    /// ⚠️ `.timedOut` IS DELIBERATELY ABSENT — a connect timeout and a read
    /// timeout arrive as the same code, and a read timeout means the bytes were
    /// already sent.
    public var isProvablyUnsent: Bool {
        switch code {
        case .notConnectedToInternet,
             .cannotFindHost,
             .cannotConnectToHost,
             .dnsLookupFailed,
             .internationalRoamingOff,
             .dataNotAllowed,
             .secureConnectionFailed:
            true
        default:
            false
        }
    }
}
