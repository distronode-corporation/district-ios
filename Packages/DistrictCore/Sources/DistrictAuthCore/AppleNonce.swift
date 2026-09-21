import Crypto
import Foundation

/// The one-use nonce that binds an Apple identity token to this sign-in attempt.
///
/// ⛔ TWO VALUES, AND SENDING THE SAME ONE TWICE IS REFUSED. Apple echoes back
/// whatever the app puts on `ASAuthorizationAppleIDRequest.nonce`, verbatim, as
/// the token's `nonce` claim. `POST /api/auth/native/apple` then SHA-256s the
/// value it finds in the request BODY and compares the two, so the app must set
/// the request property to ``hashed`` and send ``raw`` to our own server. A
/// client that sends the raw value in both places is refused, and a client that
/// sends the hash in both places is refused — the route's own header says it
/// accepts exactly ONE form on purpose, "so the contract is whatever the first
/// client happened to do" never becomes true.
///
/// ⛔ LOWER-CASE HEX, NOT BASE64URL, WHICH IS THE OPPOSITE OF ``PKCE``'s
/// CHALLENGE AND THE EASIEST THING IN THIS FILE TO GET WRONG. PKCE's S256
/// challenge is `base64url(SHA256(verifier))` because RFC 7636 says so; this one
/// is hex because the server computes it with a helper that returns hex. Both
/// are well-formed, both are 100% wrong in the other's place, and the server
/// reports the disagreement as one opaque `invalid_grant` that reads exactly
/// like a replayed token.
///
/// ⚠️ THE RAW VALUE IS ITSELF HEX, which is not required by anything — the
/// server's schema is `z.string().min(16).max(256)` with no alphabet — but it
/// keeps the value URL-safe, JSON-safe and free of any character an intermediary
/// might re-encode, and 32 bytes of it is 64 characters, comfortably inside that
/// window.
///
/// ⛔ NEVER PERSISTED, AND NEVER REUSED. It is held in memory by the App-tier
/// controller for the duration of one `ASAuthorizationController` round trip, on
/// the same reasoning as ``PKCEChallenge``: an attempt interrupted by process
/// death is simply restarted, which costs a tap, rather than writing a live
/// exchange secret to disk.
public struct AppleNonce: Sendable, Equatable {
    /// Bytes of entropy in a raw nonce.
    ///
    /// 32 bytes is 64 hex characters. The server accepts 16...256 characters, so
    /// this sits well inside the window with no rounding to think about, and it
    /// is the same 256 bits ``PKCE/verifierByteCount`` uses.
    public static let byteCount = 32

    /// The value that goes in the REQUEST BODY. The server hashes this.
    public let raw: String

    /// The value that goes on `ASAuthorizationAppleIDRequest.nonce`. Apple
    /// returns it as the identity token's `nonce` claim.
    public let hashed: String

    /// ⚠️ ``hashed`` IS DERIVED HERE RATHER THAN TAKEN, so the two halves cannot
    /// be supplied out of step. There is no initialiser that accepts both.
    public init(raw: String) {
        self.raw = raw
        hashed = Self.sha256Hex(raw)
    }

    /// A fresh nonce for one sign-in attempt.
    ///
    /// ⚠️ THE SEAM IS ``RandomByteSource``, the same one ``PKCE`` uses and for
    /// the same reason: there is exactly one production implementation and it is
    /// the default argument, but "the generator encodes its bytes correctly" is
    /// otherwise unassertable without reimplementing hex in the test.
    public static func new(using random: any RandomByteSource = CryptoRandomByteSource()) -> AppleNonce {
        AppleNonce(raw: hex(random.bytes(byteCount)))
    }

    /// `SHA-256(utf8(value))` as lower-case hex — the server's `sha256Hex`.
    ///
    /// ⚠️ UTF-8 BYTES, matching what the route hashes. Over the hex alphabet a
    /// raw nonce produces, UTF-8 and ASCII are identical, so the distinction
    /// cannot matter for a well-formed value; matching the only implementation
    /// whose opinion counts is what makes it right for a malformed one too.
    public static func sha256Hex(_ value: String) -> String {
        hex(Data(SHA256.hash(data: Data(value.utf8))))
    }

    /// The server's `z.string().min(16).max(256)`, re-implemented so a malformed
    /// nonce is caught before a round trip rather than as an opaque
    /// `invalid_grant`.
    ///
    /// ⚠️ LENGTH ONLY, BECAUSE THE SCHEMA IS LENGTH ONLY. Asserting a hex
    /// alphabet here would be this client inventing a rule the server does not
    /// have, and the first thing it would break is a future nonce format.
    public static func isValidRaw(_ value: String) -> Bool {
        (16 ... 256).contains(value.count)
    }

    /// ⛔ A TABLE RATHER THAN `String(format: "%02x")`. The format-string path
    /// goes through `NSString` on Linux and is both the slower and the less
    /// predictable of the two; a nibble table produces the same bytes on every
    /// platform and is the thing the vector test can pin.
    private static let hexDigits = Array("0123456789abcdef")

    private static func hex(_ bytes: Data) -> String {
        var out = ""
        out.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            out.append(hexDigits[Int(byte >> 4)])
            out.append(hexDigits[Int(byte & 0x0F)])
        }
        return out
    }
}
