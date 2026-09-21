@testable import DistrictAuthCore
import Foundation
import XCTest

/// ⚠️ THESE ARE HAND-WRITTEN PAYLOADS, NOT CONTRACT FIXTURES. There are no
/// committed fixtures for the native-auth token/refresh responses on either
/// platform, so nothing here would notice the server changing the shape — only
/// that this DTO decodes what this file says it decodes. The payloads below are
/// transcribed from the two JSON literals the `token` and `refresh` routes
/// return; once fixtures exist, they replace these and ``NativeTokenResponse``
/// joins the strict gate.
final class NativeTokenResponseTests: XCTestCase {
    /// Byte-for-byte the key set both routes return.
    private static let payload = Data(#"""
    {
      "tokenType": "Bearer",
      "accessToken": "eyJhbGciOiJIUzI1NiJ9.header.signature",
      "accessTokenExpiresAt": 1786500600000,
      "refreshToken": "Zm9vYmFyLXJlZnJlc2gtdG9rZW4tMzItYnl0ZXMtb2YtZW50cm9weQ",
      "refreshTokenExpiresAt": 1791684000000
    }
    """#.utf8)

    func testDecodesTheRouteShape() throws {
        let decoded = try JSONDecoder().decode(NativeTokenResponse.self, from: Self.payload)
        XCTAssertEqual(decoded.tokenType, "Bearer")
        XCTAssertEqual(decoded.accessToken, "eyJhbGciOiJIUzI1NiJ9.header.signature")
        XCTAssertEqual(decoded.accessTokenExpiresAt, 1_786_500_600_000)
        XCTAssertEqual(decoded.refreshToken, "Zm9vYmFyLXJlZnJlc2gtdG9rZW4tMzItYnl0ZXMtb2YtZW50cm9weQ")
        XCTAssertEqual(decoded.refreshTokenExpiresAt, 1_791_684_000_000)
    }

    func testExpiriesAreMillisecondsAndAreNotRescaled() throws {
        // ⚠️ The whole trap: the JWS inside the access token carries `exp` in
        // SECONDS while the envelope carries ms. A DTO that "normalised" would
        // put the access token four decades in the past and every request would
        // refresh.
        let decoded = try JSONDecoder().decode(NativeTokenResponse.self, from: Self.payload)
        XCTAssertGreaterThan(decoded.accessTokenExpiresAt, 1_000_000_000_000)
        XCTAssertGreaterThan(decoded.refreshTokenExpiresAt, decoded.accessTokenExpiresAt)
    }

    func testRoundTripsEveryKeyForTheStrictGate() throws {
        // ⛔ THE PROPERTY THE STRICT GATE DEPENDS ON. It decodes, RE-ENCODES
        // and compares key sets, so a key this type does not declare vanishes at
        // re-encode. Asserted now so `tokenType` is not "tidied away" as unused
        // before the fixture that needs it exists.
        let decoded = try JSONDecoder().decode(NativeTokenResponse.self, from: Self.payload)
        let reEncoded = try JSONEncoder().encode(decoded)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.payload) as? [String: Any])
        let round = try XCTUnwrap(JSONSerialization.jsonObject(with: reEncoded) as? [String: Any])
        XCTAssertEqual(Set(original.keys), Set(round.keys))
    }

    func testProjectsToTheCredentialPairWithoutTheTransportField() throws {
        let decoded = try JSONDecoder().decode(NativeTokenResponse.self, from: Self.payload)
        XCTAssertEqual(
            decoded.tokens,
            NativeTokens(
                accessToken: decoded.accessToken,
                accessTokenExpiresAt: decoded.accessTokenExpiresAt,
                refreshToken: decoded.refreshToken,
                refreshTokenExpiresAt: decoded.refreshTokenExpiresAt
            )
        )
    }

    func testMemberwiseInitialiserIsUsableByCallers() {
        // DistrictNetwork will construct these in its own tests; the public
        // initialiser is part of the module's surface rather than an accident of
        // the struct being internal.
        let built = NativeTokenResponse(
            tokenType: "Bearer",
            accessToken: "a",
            accessTokenExpiresAt: 2,
            refreshToken: "r",
            refreshTokenExpiresAt: 3
        )
        XCTAssertEqual(built.tokens.accessToken, "a")
        XCTAssertEqual(built.tokens.refreshTokenExpiresAt, 3)
    }
}
