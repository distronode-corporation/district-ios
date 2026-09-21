import Foundation

/// One Apple sign-in exchange, as `POST /api/auth/native/apple`'s zod schema
/// describes it.
///
/// ⛔ FIVE KEYS, AND `authorizationCode` IS NOT ONE OF THEM. The credential
/// `ASAuthorizationController` hands back also carries an `authorizationCode`,
/// which is what the WEB leg spends against Apple's token endpoint with a minted
/// ES256 client secret. This route does not: it verifies the identity token
/// against Apple's published JWKS directly, so a body carrying the code is a
/// schema failure — a 400 that is indistinguishable from a rejected token.
///
/// ⛔ `Encodable` RATHER THAN A ``JSONValue`` LITERAL, WHICH IS A DELIBERATE
/// DEPARTURE FROM ``CodeExchangeRequest``. The sibling's body is assembled by
/// hand inside ``NativeAuthClient/exchangeCode(_:)``, so its field names live at
/// the call site and are only pinned by a test that reads the encoded bytes.
/// Here the names live on the type, where the compiler carries them, and the
/// same test still reads the bytes — the point of the route being new is that
/// the shape can be declared once instead of typed twice.
///
/// ⚠️ `deviceName` IS DROPPED WHEN NIL RATHER THAN SENT AS `null`, and that is
/// synthesised `Encodable` behaviour rather than something this file arranges:
/// an Optional stored property is written with `encodeIfPresent`. It matters
/// because the settings device list renders whatever arrives, so an empty or
/// null row is a blank line in a security screen. ``AppleSignInExchangeTests``
/// asserts the key is absent, not merely empty, so a hand-written
/// `encode(to:)` could not quietly change it.
public struct AppleNativeSignInRequest: Encodable, Sendable, Equatable {
    /// ⛔ `z.enum(["ios", "android"])`, AND NOT A PARAMETER. It is not the
    /// caller's choice — this client is the iOS one — and a settable field is
    /// how a device ends up listed as the wrong platform in the settings device
    /// list. The sibling holds the same value as a static constant; here it is a
    /// stored property because the body is synthesised from the type.
    public let platform = "ios"

    /// The `identityToken` from `ASAuthorizationAppleIDCredential`, as a UTF-8
    /// string. ⚠️ Apple hands it over as `Data`; the server's schema is
    /// `z.string().min(1).max(8192)`.
    public let identityToken: String

    /// ⛔ THE **RAW** NONCE, NEVER THE HASHED ONE. The server SHA-256s this value
    /// and compares the digest to the token's `nonce` claim, so the hashed value
    /// belongs on `ASAuthorizationAppleIDRequest.nonce` and this one belongs
    /// here. Sending either value in both places is refused. See
    /// `DistrictAuthCore.AppleNonce`.
    public let nonce: String

    /// Opaque install id. Scopes per-device sign-out; 8...200 characters.
    public let deviceId: String

    /// Display only, shown in the settings device list. Never trusted.
    public let deviceName: String?

    public init(identityToken: String, nonce: String, deviceId: String, deviceName: String?) {
        self.identityToken = identityToken
        self.nonce = nonce
        self.deviceId = deviceId
        self.deviceName = deviceName
    }
}
