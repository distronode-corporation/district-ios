@testable import DistrictAuthCore
import Foundation

// MARK: - Server-rule oracles

// ⚠️ TEST SUPPORT, NOT CLIENT BEHAVIOUR. These re-implement the server's own
// validators so the suites can assert that what this client MINTS passes them.
// They lived in `Sources/` as public pre-flight checks the client never ran, so
// their documentation described a guard that did not exist.

extension PKCE {
    /// The verifier alphabet, RFC 7636 §4.1 (the URI unreserved set).
    ///
    /// ⚠️ Held as a `Set<Character>` rather than a regular expression on
    /// purpose: `NSRegularExpression` and the Swift `Regex` literal both behave
    /// subtly differently between Darwin Foundation and swift-corelibs-
    /// foundation, and these suites also run on Linux.
    private static let verifierAlphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// The challenge alphabet: base64url, which is the verifier's alphabet
    /// without `.` and `~`.
    private static let challengeAlphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    /// The server's `isValidCodeVerifier`.
    static func isValidVerifier(_ verifier: String) -> Bool {
        (43 ... 128).contains(verifier.count) && verifier.allSatisfy(verifierAlphabet.contains)
    }

    /// The server's `isValidCodeChallenge`: exactly 43 base64url characters.
    ///
    /// ⚠️ Checked at AUTHORIZE time server-side, so a 44-character (padded)
    /// challenge fails before a code is even minted, which presents as "the
    /// login button does nothing" rather than as a token-exchange error.
    static func isValidChallenge(_ challenge: String) -> Bool {
        challenge.count == 43 && challenge.allSatisfy(challengeAlphabet.contains)
    }
}

extension AppleNonce {
    /// The server's `z.string().min(16).max(256)`.
    ///
    /// ⚠️ LENGTH ONLY, BECAUSE THE SCHEMA IS LENGTH ONLY. Asserting a hex
    /// alphabet here would be inventing a rule the server does not have.
    static func isValidRaw(_ value: String) -> Bool {
        (16 ... 256).contains(value.count)
    }
}
