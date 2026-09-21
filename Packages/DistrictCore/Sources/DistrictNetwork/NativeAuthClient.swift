import Foundation

/// The four unauthenticated native-auth paths, as SEGMENTS.
///
/// ⚠️ SEGMENTS, NOT A TEMPLATE, matching how ``DistrictPaths`` builds every
/// other path in this client. Nothing user-supplied is interpolated into any of
/// them, so the segment discipline is convention here rather than a defence —
/// but a string template is the shape that invites the next path to take an id.
///
/// ⛔ THEY ARE NOT IN ``DistrictPaths`` AND HAVE NO ``EndpointID``, WHICH IS THE
/// SAME GUARD `calls/outbound` RELIES ON RATHER THAN AN OMISSION. Those are the
/// raw materials of ``ApiRequestDescriptor``, and a descriptor is a request
/// ``ApiClient`` will attach a bearer to — which these four routes must never
/// be: the credential is the code (exchange), Apple's identity token, or the
/// refresh token itself (refresh, revoke). Giving them an `EndpointID` would
/// also put them in the untyped/typed/redirect partition that
/// `EndpointSurfaceTests` asserts over `EndpointID.allCases`, i.e. it would claim they are reachable through the
/// client that cannot reach them — so that suite's 55/25/1 counts are untouched
/// by anything in this file.
enum NativeAuthPaths {
    private static let nativeAuth = ["api", "auth", "native"]

    static let token = nativeAuth + ["token"]
    static let refresh = nativeAuth + ["refresh"]
    static let revoke = nativeAuth + ["revoke"]

    /// ⚠️ A SIBLING OF `token`, NOT A VARIANT OF IT. The two routes mint the
    /// same credential and return the same five keys, but they authenticate
    /// completely different things — a PKCE code this app minted a challenge
    /// for, against an identity token Apple signed — so they are separate
    /// handlers with separate rate-limit buckets on the server.
    static let apple = nativeAuth + ["apple"]
}

/// The four unauthenticated native-auth calls the shell needs: the PKCE code
/// exchange, the Apple identity-token exchange, the refresh rotation, and the
/// sign-out revoke.
///
/// ⛔ THESE CARRY NO BEARER TOKEN, WHICH IS WHY THEY CANNOT GO THROUGH
/// ``ApiClient``. Acquiring an access token is what the first three are FOR, so
/// routing them through a client that acquires one first is a deadlock; the
/// revoke has a second reason, which is that it is called from a sign-out that
/// has already decided to stop having a session. All four sit under `proxy.ts`'s
/// public `/api/auth/` prefix for the same reason: the caller has no usable
/// session, and the authority is the code (exchange), Apple's signature (apple)
/// or the refresh token itself (refresh, revoke).
///
/// ⛔ THE STATUS MAPPING IS SECURITY-RELEVANT, NOT PLUMBING. It is taken from
/// `DistrictAuthCore.RefreshResult`'s table, which was derived from the route
/// files rather than guessed. Getting it wrong either signs users out for a
/// transient 429, or re-presents a spent refresh token and revokes their entire
/// token family. `NativeAuthClientTests` walks both maps status by status, which
/// is the reason this type is here rather than in `App/`: every line of it is
/// pure logic over the ``HTTPTransport`` seam, and in `App/` nothing on the
/// Linux tier could exercise a line of it.
///
/// ⚠️ GENERIC OVER ITS THREE RESULT TYPES, WHICH IS THE PRICE OF NOT DEPENDING
/// ON `DistrictAuthCore`. See ``NativeAuthTokenWire``, ``NativeRefreshOutcome``
/// and ``NativeRevokeOutcome``: the App target supplies `NativeTokenResponse`,
/// `RefreshResult` and `RevokeOutcome` through EMPTY extensions, so no mapping
/// code exists on the untested tier.
public struct NativeAuthClient<
    Wire: NativeAuthTokenWire,
    Refresh: NativeRefreshOutcome,
    Revoke: NativeRevokeOutcome
>: Sendable where Refresh.Tokens == Wire.Tokens {
    private let baseURL: URL
    private let transport: any HTTPTransport

    public init(baseURL: URL = ApiClient.productionBaseURL, transport: any HTTPTransport) {
        self.baseURL = baseURL
        self.transport = transport
    }

    // ── Code exchange ────────────────────────────────────────────────────────

    /// Trade a single-use authorization code for the first token pair.
    ///
    /// ⚠️ A 400 IS `rejected` HERE AND `rateLimited` ON THE REFRESH PATH, WHICH
    /// LOOKS INCONSISTENT AND IS NOT. The token route answers one opaque
    /// `invalid_grant` 400 for every refusal — expired, replayed, PKCE mismatch,
    /// redirect mismatch — and all four mean "start the login over". On refresh,
    /// a 400 means our own body was malformed and the token was provably never
    /// rotated, so signing the user out would punish a client bug.
    public func exchangeCode(_ request: CodeExchangeRequest) async -> CodeExchangeResult<Wire.Tokens> {
        // ⚠️ camelCase, WHICH IS NOT WHAT THE AUTHORIZE LEG USES. `page.tsx`
        // reads `code_challenge` / `redirect_uri` in snake_case; this route's zod
        // schema reads `codeVerifier` / `redirectUri`. Mixing them up fails with
        // a 400 that is indistinguishable from a rejected code.
        //
        // ⛔ `deviceName` IS DROPPED WHEN NIL RATHER THAN SENT EMPTY, which is
        // what ``JSONValue/object(_:)`` does with a nil pair. The settings device
        // list renders whatever arrives, so an empty string would be a blank row.
        let payload = JSONValue.object([
            ("code", .string(request.code)),
            ("codeVerifier", .string(request.codeVerifier)),
            ("redirectUri", .string(request.redirectUri)),
            ("deviceId", .string(request.deviceId)),
            ("platform", .string(CodeExchangeRequest.platform)),
            ("deviceName", .optional(request.deviceName)),
        ])

        guard let response = try? await post(NativeAuthPaths.token, payload: payload) else {
            return .transportFailure
        }

        switch response.statusCode {
        case 200:
            guard let tokens = Self.tokens(from: response) else { return .transportFailure }
            return .success(tokens)
        case 400:
            return .rejected
        case 429:
            return .rateLimited
        default:
            return .transportFailure
        }
    }

    // ── Apple sign-in ────────────────────────────────────────────────────────

    /// Trade an Apple identity token for the first token pair.
    ///
    /// ⛔ THE SAME STATUS MAP AS ``exchangeCode(_:)``, READ OFF THE ROUTE RATHER
    /// THAN ASSUMED FROM THE SIBLING. The server's Apple route answers one opaque
    /// `invalid_grant` 400 for every refusal it can make — a signature that does
    /// not verify, a wrong audience, an expired token, a nonce that does not
    /// match, a subject it cannot resolve, an address whose verification was
    /// withdrawn — and all of them mean "start the sign-in over". It rate-limits
    /// at 429 before doing any of that work, and its own catch answers 500.
    ///
    /// ⛔ AND ONE STATUS THE SIBLING DOES NOT HAVE: 403 IS `noAccount`. The route
    /// answers it for a verified Apple ID that no District AI account uses, since
    /// sign-in never creates an account. It is keyed on the STATUS ALONE, not the
    /// body: no other refusal on this route is a 403, and a body this build
    /// cannot parse must not turn "ask for an invitation" into "check your
    /// connection", which reads as broken sign-in.
    ///
    /// ⚠️ A 200 THIS BUILD CANNOT PARSE IS `transportFailure`, NOT `rejected`:
    /// the server minted a session this build cannot read, which is ambiguous
    /// rather than a refusal. Same reasoning as the sibling.
    ///
    /// ⛔ AND THERE IS NO `notSent` HERE EITHER. An identity token is single-use
    /// against this route and the flow restarts from a fresh
    /// `ASAuthorizationController` either way, so every I/O failure is one
    /// outcome. `notSent` exists only for a credential that must not be
    /// re-presented.
    public func exchangeAppleIdentityToken(
        _ request: AppleNativeSignInRequest
    ) async -> CodeExchangeResult<Wire.Tokens> {
        // ⚠️ THE ENCODE IS INSIDE THE `try?` DELIBERATELY. `JSONEncoder` can only
        // fail here on a value it cannot represent, and every property of the
        // request is a `String`, so the throw is unreachable — giving it its own
        // branch would be a line no input can cover and a claim no test can make.
        // Collapsing it into "no answer" is also the honest outcome: nothing was
        // sent.
        guard let response = try? await post(
            NativeAuthPaths.apple,
            body: JSONEncoder().encode(request)
        ) else {
            return .transportFailure
        }

        switch response.statusCode {
        case 200:
            guard let tokens = Self.tokens(from: response) else { return .transportFailure }
            return .success(tokens)
        case 400:
            return .rejected
        case 403:
            return .noAccount
        case 429:
            return .rateLimited
        default:
            return .transportFailure
        }
    }

    // ── Refresh rotation ─────────────────────────────────────────────────────

    /// Rotate the refresh token.
    ///
    /// ⚠️ THIS IS THE WITNESS FOR `DistrictAuthCore.RefreshClient`, which the App
    /// target declares as an empty conditional conformance. The signature must
    /// keep matching that protocol's `refresh(refreshToken:)`.
    public func refresh(refreshToken: String) async -> Refresh {
        let response: HTTPResponse
        do {
            response = try await post(
                NativeAuthPaths.refresh,
                payload: .object([("refreshToken", .string(refreshToken))])
            )
        } catch {
            // ⛔ "NEVER LEFT THE DEVICE" IS NOT THE SAME AS "MIGHT HAVE ROTATED
            // THE TOKEN", AND COLLAPSING THEM BURNS SESSIONS. See
            // `RefreshResult.notSent`: opening the app offline marks the token
            // pending, fails to send it, and the next launch reads marker ==
            // stored token as an interrupted refresh — one offline app-open
            // costing a re-login.
            //
            // ⛔ THE CONCRETE `URLError` CHECK IS NOT REDUNDANT WITH THE PROTOCOL
            // CAST BELOW, AND REMOVING IT SILENTLY RESTORES THE BUG. On Darwin a
            // `_BridgedStoredNSError` value bridges to `NSError` the moment it
            // enters an `any Error` existential, so `type(of: error)` reports
            // `NSError` even for a directly constructed `URLError`. The runtime
            // special-cases `as? URLError` and gets it right; it does NOT
            // special-case a cast to an arbitrary protocol, so
            // `as? any ProvablyUnsentError` fails and every URLError collapsed
            // to `.transportFailure` on Darwin while the same test passes on Linux.
            //
            // ⚠️ `ProvablyUnsentError` therefore reaches only PURE-SWIFT error
            // types. `StubTransportError` always passed for that reason, and a
            // future `extension SomeFoundationError: ProvablyUnsentError` will be
            // unreachable the same way, with nothing to warn you: this is not a
            // retroactive-conformance diagnostic, and the compiler is silent here.
            //
            // ⛔ THE ORDER IS LOAD-BEARING FOR DETECTION, NOT FOR BEHAVIOUR.
            // Protocol-first also answers correctly, but Linux would satisfy the
            // protocol cast and never reach this branch while Darwin fell through
            // to it, so the two platforms would run different code for identical
            // input. That asymmetry is what hid this for as long as it lived.
            // Concrete-first makes both platforms take this branch for URLError,
            // so a Linux run is evidence about Darwin. The protocol path stays
            // exercised on both by the non-Foundation transports.
            if let urlError = error as? URLError {
                return urlError.isProvablyUnsent ? .notSent : .transportFailure
            }
            return (error as? any ProvablyUnsentError)?.isProvablyUnsent == true ? .notSent : .transportFailure
        }

        switch response.statusCode {
        case 200:
            // ⚠️ A 200 THIS BUILD CANNOT PARSE IS THE WORST CASE, NOT THE BEST:
            // the server HAS rotated the token and the successor is unreadable.
            // Ambiguous, so the coordinator must keep its marker set — which is
            // what `transportFailure` does and `rejected` would not.
            guard let tokens = Self.tokens(from: response) else { return .transportFailure }
            return .success(tokens)
        case 401:
            return .rejected
        case 429, 400:
            // The route rate-limits BEFORE `rotateNativeSession`, and validates
            // the body before it too, so the token is provably unspent in both
            // cases. Neither is a dead credential.
            return .rateLimited
        default:
            return .transportFailure
        }
    }

    // ── Sign-out revoke ──────────────────────────────────────────────────────

    /// End this device's session server-side.
    ///
    /// ⛔ ONLY A 200 LETS THE CREDENTIAL GO, AND THAT IS THE OPPOSITE SHAPE TO
    /// ``refresh(refreshToken:)``. There, a 401 is fatal to the session and a
    /// 5xx is ambiguous. Here, the route answers 200 for an unknown token ON
    /// PURPOSE — its header: "sign-out has one job: end the session and leave
    /// the client certain it may discard its credential" — and it split the 503
    /// out specifically so a failed database write stops being reported as a
    /// completed sign-out. Since nothing in either answer confirms whether a
    /// token existed, a 200 is the only evidence that the server will not honour
    /// it again, and every other answer keeps it.
    ///
    /// ⛔ NO RETRY HERE, AND NOT BECAUSE RETRYING WOULD BE WRONG. The retry is
    /// the revoke OUTBOX: the caller writes the token durably before this is
    /// called and drains it on a later launch. A loop inside this function would
    /// hold a sign-out the user is watching, against an origin the 503 says is
    /// already struggling.
    ///
    /// ⚠️ `isProvablyUnsent` IS DELIBERATELY NOT CONSULTED. It exists so a
    /// refresh can tell an unspent token from a possibly-spent one; a revoke has
    /// no such distinction, because every failure to get an answer means the
    /// same thing — try again later.
    public func revoke(refreshToken: String) async -> Revoke {
        // ⚠️ ONE KEY, matching `RevokeSchema` (`z.object({ refreshToken:
        // z.string().min(1).max(512) })`), and never in the URL: a query
        // parameter would reach logs, proxies and anything that ever opened it.
        let payload = JSONValue.object([("refreshToken", .string(refreshToken))])

        guard let response = try? await post(NativeAuthPaths.revoke, payload: payload) else {
            return .deferred(.notSent)
        }

        switch response.statusCode {
        case 200:
            // ⚠️ THE BODY IS NOT READ, AND A 200 THIS BUILD CANNOT PARSE IS
            // STILL `accepted`. The status IS the contract: the route's only
            // successful body is `{"success":true}` and nothing branches on it,
            // so treating an unparseable 200 as a failure would strand a
            // credential the server has already forgotten. This is the opposite
            // of the refresh path, where an unreadable 200 hides a rotation that
            // really happened and the successor is genuinely lost.
            return .accepted
        case 503:
            return .deferred(.serverUnavailable)
        case 429:
            return .deferred(.rateLimited)
        default:
            return .deferred(.unexpected(status: response.statusCode))
        }
    }

    // ── Internals ────────────────────────────────────────────────────────────

    /// ⚠️ THE `JSONValue` DOOR, WHICH IS THE ONE THE THREE ORIGINAL ROUTES USE.
    /// The Apple route encodes its body from a type instead and goes through the
    /// overload below; both end at the same request, so the headers and the
    /// redirect policy cannot drift between them.
    private func post(_ segments: [String], payload: JSONValue) async throws -> HTTPResponse {
        // ⚠️ THE THROW IS UNREACHABLE FOR THESE THREE BODIES — only a
        // non-finite `Double` makes `JSONWire` fail and every value in all
        // three payloads is a string — so it is propagated rather than given
        // a fallback. A `?? Data()` here would be a branch no input can take,
        // i.e. a line that can never be covered and a claim that can never be
        // tested, and it would send an EMPTY body where every caller already
        // treats a throw as its "no answer" outcome.
        try await post(segments, body: JSONWire.encode(payload))
    }

    private func post(_ segments: [String], body: Data) async throws -> HTTPResponse {
        // ⚠️ ONE SEGMENT AT A TIME, WHICH IS BOTH THE SEGMENT DISCIPLINE AND A
        // TOTAL FUNCTION. ``ApiURL/build(base:segments:query:)`` answers an
        // Optional for the empty-segment case these four constant paths cannot
        // reach, and a nil branch no input can take is a line that can never be
        // covered and a claim that can never be tested. Appending components
        // percent-encodes each one and cannot fail. ⚠️ It also absorbs a trailing
        // `/` on the base URL, which `//api/auth/...` would otherwise turn into a
        // different path.
        let url = segments.reduce(baseURL) { $0.appendingPathComponent($1) }
        let request = HTTPRequest(
            method: .post,
            url: url,
            headers: [
                "Content-Type": "application/json; charset=utf-8",
                "Accept": "application/json",
            ],
            body: body
        )
        // ⛔ REDIRECTS FOLLOWED, WHICH IS THE DEFAULT EVERYWHERE EXCEPT THE
        // RECORDING ROUTE. A credential exchange that silently stopped at a 308
        // would report `transportFailure` and look like an outage.
        return try await transport.send(request, followRedirects: true)
    }

    /// Parse the five-key body both routes return.
    ///
    /// ⚠️ LENIENT ON PURPOSE. `JSONDecoder` ignores unknown keys, so a field
    /// added server-side degrades to "ignored" on every installed build instead
    /// of breaking login on every phone in the field. Strictness is the contract
    /// gate's job, and these two responses join it once their fixtures exist.
    private static func tokens(from response: HTTPResponse) -> Wire.Tokens? {
        guard let body = response.body else { return nil }
        return try? JSONDecoder().decode(Wire.self, from: body).tokens
    }
}
