@testable import DistrictNetwork
import Foundation
import XCTest

// ── The mirrors ──────────────────────────────────────────────────────────────
//
// ⛔ THESE MIRROR `DistrictAuthCore`'s REAL TYPES FIELD FOR FIELD AND CASE FOR
// CASE, AND THAT IS THE WHOLE VALUE OF THEM. `DistrictNetworkTests` cannot
// import `DistrictAuthCore` (its target does not depend on it) and NOTHING on
// the Linux tier compiles `App/`, where the real conformances are declared — the
// app target reaches a compiler only on a macOS build. So
// the conformances are rehearsed here against copies: if
// `extension NativeTokenResponse: NativeAuthTokenWire {}` or
// `extension RefreshResult: NativeRefreshOutcome {}` would stop compiling, this
// file stops compiling first.
//
// ⚠️ KEEP THEM IN STEP WITH THE ORIGINALS. A mirror that drifts still compiles
// and proves nothing — see `NativeTokens.swift` and `RefreshClient.swift`.

/// Mirrors `DistrictAuthCore.NativeTokens`.
struct MirrorTokens: Sendable, Equatable {
    let accessToken: String
    let accessTokenExpiresAt: Int64
    let refreshToken: String
    let refreshTokenExpiresAt: Int64
}

/// Mirrors `DistrictAuthCore.NativeTokenResponse`, including the `tokenType` key
/// nothing reads and the `tokens` projection that drops it.
struct MirrorTokenResponse: Codable, Sendable, Equatable {
    let tokenType: String
    let accessToken: String
    let accessTokenExpiresAt: Int64
    let refreshToken: String
    let refreshTokenExpiresAt: Int64

    var tokens: MirrorTokens {
        MirrorTokens(
            accessToken: accessToken,
            accessTokenExpiresAt: accessTokenExpiresAt,
            refreshToken: refreshToken,
            refreshTokenExpiresAt: refreshTokenExpiresAt
        )
    }
}

/// ⚠️ EMPTY, EXACTLY AS IN `App/`. The type already declares `Decodable`,
/// `Sendable` and `tokens`, so there is no adapter to write and none to rot.
extension MirrorTokenResponse: NativeAuthTokenWire {}

/// Mirrors `DistrictAuthCore.RefreshResult` — the five cases, in its spelling.
enum MirrorRefreshResult: Sendable, Equatable {
    case success(MirrorTokens)
    case rejected
    case rateLimited
    case transportFailure
    case notSent
}

/// ⚠️ ALSO EMPTY: a Swift enum case witnesses a static protocol requirement, so
/// the five cases satisfy ``NativeRefreshOutcome`` with no mapping code. If this
/// ever needed a body, the status map would have gained a second home.
extension MirrorRefreshResult: NativeRefreshOutcome {}

/// Mirrors `DistrictAuthCore.RefreshClient`, which
/// `TokenRefreshCoordinator(store:refreshClient:)` takes as an existential.
protocol MirrorRefreshClient: Sendable {
    func refresh(refreshToken: String) async -> MirrorRefreshResult
}

/// ⚠️ THE CONDITIONAL CONFORMANCE `App/` DECLARES, rehearsed. `refresh` on the
/// generic client is the witness once `Refresh` is pinned.
extension NativeAuthClient: MirrorRefreshClient where Refresh == MirrorRefreshResult {}

/// Mirrors `DistrictAuthCore.RevokeDeferral` — four cases, in its spelling.
///
/// ⚠️ `unexpected(status:)` KEEPS ITS ARGUMENT LABEL. The label is part of the
/// requirement's name, so a mirror that dropped it would compile here and the
/// real conformance would not.
enum MirrorRevokeDeferral: Sendable, Equatable {
    case serverUnavailable
    case rateLimited
    case notSent
    case unexpected(status: Int)
}

/// Mirrors `DistrictAuthCore.RevokeOutcome` — TWO cases, deliberately. A
/// sign-out has no "rejected": the local wipe is unconditional, so the only
/// question is whether the credential still needs chasing.
enum MirrorRevokeOutcome: Sendable, Equatable {
    case accepted
    case deferred(MirrorRevokeDeferral)
}

/// ⚠️ BOTH EMPTY, as in `App/`. An enum case witnesses a static requirement,
/// including one with an associated value and an argument label, so there is no
/// mapping code and the revoke status map has exactly one home.
extension MirrorRevokeDeferral: NativeRevokeDeferral {}

extension MirrorRevokeOutcome: NativeRevokeOutcome {}

/// Mirrors `DistrictAuthCore.RevokeClient`, which `SignOutCoordinator` takes as
/// an existential.
protocol MirrorRevokeClient: Sendable {
    func revoke(refreshToken: String) async -> MirrorRevokeOutcome
}

/// ⚠️ THE SECOND CONDITIONAL CONFORMANCE `App/` DECLARES, rehearsed.
extension NativeAuthClient: MirrorRevokeClient where Revoke == MirrorRevokeOutcome {}

/// The client under test, with all three seams satisfied.
typealias TestNativeAuthClient = NativeAuthClient<
    MirrorTokenResponse,
    MirrorRefreshResult,
    MirrorRevokeOutcome
>

/// A transport error that answers the ``ProvablyUnsentError`` question itself,
/// standing in for a non-`URLSession` transport.
struct StubTransportError: ProvablyUnsentError {
    let isProvablyUnsent: Bool
}

/// One row of the connect-phase table. ⚠️ Carries its own source line so a
/// failing row names itself.
private struct CodeRow {
    let code: URLError.Code
    let unsent: Bool
    let line: UInt

    init(_ code: URLError.Code, _ unsent: Bool, line: UInt = #line) {
        self.code = code
        self.unsent = unsent
        self.line = line
    }
}

final class NativeAuthSeamTests: XCTestCase {
    /// ⛔ THE POINT OF THE WHOLE GENERIC ARRANGEMENT: the client hands back the
    /// consumer's own result type through an existential, with no mapping
    /// function anywhere. This is the shape `AppContainer` passes to
    /// `TokenRefreshCoordinator`.
    func testTheClientSatisfiesTheRefreshClientSeamThroughAnExistential() async throws {
        let transport = TestTransport(status: 401)
        let client: any MirrorRefreshClient = try TestNativeAuthClient(
            baseURL: XCTUnwrap(URL(string: "https://example.test")),
            transport: transport
        )

        let result = await client.refresh(refreshToken: "rt")

        XCTAssertEqual(result, .rejected)
    }

    /// ⛔ THE SAME ARRANGEMENT FOR THE REVOKE SEAM: the client hands back the
    /// consumer's own outcome type through an existential, with no mapping
    /// function anywhere. This is the shape `AppContainer` passes to
    /// `SignOutCoordinator`.
    ///
    /// ⚠️ THE 503 ROW IS THE ONE WORTH REHEARSING HERE rather than a 200,
    /// because it is the case that carries a PAYLOAD across the seam — a bare
    /// `accepted` would prove the static-var half and say nothing about
    /// `deferred(_:)`.
    func testTheClientSatisfiesTheRevokeClientSeamThroughAnExistential() async throws {
        let transport = TestTransport(status: 503)
        let client: any MirrorRevokeClient = try TestNativeAuthClient(
            baseURL: XCTUnwrap(URL(string: "https://example.test")),
            transport: transport
        )

        let result = await client.revoke(refreshToken: "rt")

        XCTAssertEqual(result, .deferred(.serverUnavailable))
    }

    /// ⛔ CONNECT-PHASE ONLY. The cost of a false "unsent" is presenting a spent
    /// refresh token and having the whole family revoked as theft; the cost of a
    /// false "ambiguous" is one re-login.
    ///
    /// ⚠️ `.timedOut` IS DELIBERATELY ABSENT from the true list: a connect
    /// timeout and a read timeout arrive as the same code, and a read timeout
    /// means the bytes were already sent.
    func testOnlyTheConnectPhaseUrlErrorsAreProvablyUnsent() {
        let rows: [CodeRow] = [
            CodeRow(.notConnectedToInternet, true),
            CodeRow(.cannotFindHost, true),
            CodeRow(.cannotConnectToHost, true),
            CodeRow(.dnsLookupFailed, true),
            CodeRow(.internationalRoamingOff, true),
            CodeRow(.dataNotAllowed, true),
            CodeRow(.secureConnectionFailed, true),
            // Ambiguous: the request may already have been sent.
            CodeRow(.timedOut, false),
            CodeRow(.networkConnectionLost, false),
            CodeRow(.badServerResponse, false),
            CodeRow(.cancelled, false),
        ]

        for row in rows {
            XCTAssertEqual(
                URLError(row.code).isProvablyUnsent,
                row.unsent,
                "\(row.code)",
                line: row.line
            )
        }
    }

    /// ⛔ THE SIGNAL IS THE PROTOCOL, NOT THE ERROR DOMAIN. A transport that is
    /// not `URLSession`-backed answers the same question in its own terms, and
    /// `DistrictNetwork` never learns which stack is underneath it.
    func testAnyTransportCanDeclareItsErrorProvablyUnsent() {
        XCTAssertTrue(StubTransportError(isProvablyUnsent: true).isProvablyUnsent)
        XCTAssertFalse(StubTransportError(isProvablyUnsent: false).isProvablyUnsent)
    }
}
