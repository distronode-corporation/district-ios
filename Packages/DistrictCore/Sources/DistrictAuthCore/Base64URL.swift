import Foundation

/// base64url encoding without padding, per RFC 7636 Appendix A.
///
/// This is the one piece of PKCE that has no dependency on a hash function.
/// Getting it wrong is a silent auth failure rather than a loud one — the
/// authorisation server simply rejects the exchange — so it is unit-tested
/// against the RFC's own vector.
public enum Base64URL {
    /// Encode bytes as base64url with `+`/`/` substituted and padding removed.
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Decode a base64url string, restoring the padding base64 requires.
    ///
    /// Returns nil rather than throwing: every caller here is parsing
    /// attacker-reachable input (a callback URL) and has a "reject this
    /// response" branch already.
    public static func decode(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            // A remainder of 1 is not producible by any valid base64 encoding;
            // Data(base64Encoded:) rejects it, which is what we want.
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }
}
