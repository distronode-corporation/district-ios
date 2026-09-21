import Foundation

/// The credential pair returned by `POST /api/auth/native/{token,refresh}`.
///
/// ⚠️ BOTH EXPIRY FIELDS ARE MILLISECONDS, matching the server, which returns
/// `accessTokenExpiresAt` / `refreshTokenExpiresAt` in ms even though the JWT's
/// own `exp`/`iat` claims inside the access token are in SECONDS. The server
/// returns the value rather than letting clients recompute it precisely because
/// deriving it twice is how the two units get mixed up. Do not "normalise"
/// these to seconds.
public struct NativeTokens: Sendable, Equatable {
    /// Compact JWS, 10-minute TTL. ⛔ HELD IN MEMORY ONLY — see ``TokenStore``.
    public let accessToken: String
    /// Epoch MILLISECONDS.
    public let accessTokenExpiresAt: Int64
    /// Opaque, 32 bytes of entropy, base64url. Sliding 60-day TTL, re-set on
    /// every rotation.
    ///
    /// ⛔ SINGLE USE. `rotateNativeSession` stamps `rotatedAt` on this value the
    /// moment it is exchanged, and presenting it again is treated as a replay:
    /// the ENTIRE token family is revoked and the user is signed out on every
    /// device in that chain, logged as `[auth] Native refresh replay detected`.
    /// This is the one invariant the whole of ``TokenRefreshCoordinator`` exists
    /// to protect.
    public let refreshToken: String
    /// Epoch MILLISECONDS.
    public let refreshTokenExpiresAt: Int64

    public init(
        accessToken: String,
        accessTokenExpiresAt: Int64,
        refreshToken: String,
        refreshTokenExpiresAt: Int64
    ) {
        self.accessToken = accessToken
        self.accessTokenExpiresAt = accessTokenExpiresAt
        self.refreshToken = refreshToken
        self.refreshTokenExpiresAt = refreshTokenExpiresAt
    }
}

/// The wire shape of `POST /api/auth/native/token` and
/// `POST /api/auth/native/refresh`.
///
/// ⛔ ONE TYPE FOR BOTH ROUTES BECAUSE THEY RETURN THE SAME FIVE KEYS, verified
/// against the two `NextResponse.json({...})` calls rather than assumed: the
/// exchange route and the refresh route build the identical object literal.
/// A future divergence would surface as a contract-gate failure on whichever
/// fixture changed, which is the signal wanted — see the note below.
///
/// ⛔ THESE DTOs ARE NOT YET UNDER THE CONTRACT GATE, AND THAT IS A KNOWN,
/// TRACKED HOLE RATHER THAN AN OVERSIGHT. There are no fixtures for the
/// native-auth token/refresh responses on EITHER platform, because they are
/// generated on the server side alongside the Android client's. When they
/// exist, this type joins `ImplementedFixtures` and its fixture name comes off
/// `ContractManifest.unimplemented` in the same commit. Until then the only
/// thing pinning this shape is the server's two routes.
///
/// ⚠️ `tokenType` IS DECLARED EVEN THOUGH NOTHING READS IT, WHICH IS THE
/// OPPOSITE OF WHAT THE KOTLIN CLIENT DOES, AND BOTH ARE RIGHT. `NativeAuthApi`
/// hand-parses four keys and ignores this one, because it is a lenient runtime
/// parser. This type is a `Codable` destined for the strict gate,
/// which decodes, RE-ENCODES and compares key sets — so an undeclared server key
/// disappears at re-encode and fails the comparison. Dropping `tokenType` here
/// would make the fixture unpinnable the day it exists.
public struct NativeTokenResponse: Codable, Sendable, Equatable {
    /// Always `"Bearer"`. Carried for the contract gate; see the type note.
    public let tokenType: String
    public let accessToken: String
    /// Epoch MILLISECONDS.
    public let accessTokenExpiresAt: Int64
    public let refreshToken: String
    /// Epoch MILLISECONDS.
    public let refreshTokenExpiresAt: Int64

    public init(
        tokenType: String,
        accessToken: String,
        accessTokenExpiresAt: Int64,
        refreshToken: String,
        refreshTokenExpiresAt: Int64
    ) {
        self.tokenType = tokenType
        self.accessToken = accessToken
        self.accessTokenExpiresAt = accessTokenExpiresAt
        self.refreshToken = refreshToken
        self.refreshTokenExpiresAt = refreshTokenExpiresAt
    }

    /// The credential pair, with the transport-level `tokenType` dropped.
    public var tokens: NativeTokens {
        NativeTokens(
            accessToken: accessToken,
            accessTokenExpiresAt: accessTokenExpiresAt,
            refreshToken: refreshToken,
            refreshTokenExpiresAt: refreshTokenExpiresAt
        )
    }
}
