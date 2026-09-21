@testable import DistrictAuthCore
import Foundation
import XCTest

final class PKCETests: XCTestCase {
    // ── Known-answer vectors ─────────────────────────────────────────────────
    // RFC 7636 Appendix B publishes one verifier/challenge pair. Asserting it
    // is independent confirmation that this implementation is right, not merely
    // that it agrees with the server — if both sides drifted together, this is
    // what would notice. `PKCEVectorTests` covers the other direction.
    private static let rfcVerifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    private static let rfcChallenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"

    func testDerivesTheRFC7636AppendixBVector() {
        XCTAssertEqual(PKCE.deriveChallenge(for: Self.rfcVerifier), Self.rfcChallenge)
    }

    func testDerivesTheEmptyStringToTheKnownSHA256OfNothing() {
        // base64url of SHA-256(""), the most widely published digest there is.
        // It pins the encoding independently of any verifier alphabet concern.
        XCTAssertEqual(
            PKCE.deriveChallenge(for: ""),
            "47DEQpj8HBSa-_TImW-5JCeuQeRkm5NMpJWZG3hSuFU"
        )
    }

    /// base64url(SHA-256(the DECODED 32 octets of the RFC verifier)) — the value
    /// the natural mistake produces. Computed independently, not by this code.
    private static let rfcChallengeOfDecodedBytes = "38v3YOi6zQgk1xkqk6Y5dvSDoBHqZrTh3mmWHxxWvyk"

    func testDerivesTheASCIIStringNotDecodedBytes() {
        // ⛔ The trap this exists for: the verifier LOOKS like base64url, so
        // hashing its decoded bytes is the natural mistake. Both answers are
        // well-formed 43-character challenges and only one is right; the server
        // reports the wrong one as an opaque invalid_grant with nothing to point
        // at, so an assertion is the only thing that can catch it.
        XCTAssertNotEqual(Self.rfcChallengeOfDecodedBytes, Self.rfcChallenge)
        XCTAssertEqual(PKCE.deriveChallenge(for: Self.rfcVerifier), Self.rfcChallenge)
        XCTAssertNotEqual(PKCE.deriveChallenge(for: Self.rfcVerifier), Self.rfcChallengeOfDecodedBytes)
    }

    // ── Generation ───────────────────────────────────────────────────────────

    func testGeneratedVerifierIsAcceptedByTheServersShapeCheck() {
        let generated = PKCE.newChallenge()
        XCTAssertEqual(generated.verifier.count, 43, "32 bytes must base64url to RFC 7636's 43-char minimum")
        XCTAssertTrue(PKCE.isValidVerifier(generated.verifier))
        XCTAssertTrue(PKCE.isValidChallenge(generated.challenge))
        XCTAssertFalse(generated.challenge.contains("="), "padding fails isValidCodeChallenge at authorize time")
    }

    func testGeneratedChallengeMatchesItsOwnVerifier() {
        let generated = PKCE.newChallenge()
        XCTAssertEqual(generated.challenge, PKCE.deriveChallenge(for: generated.verifier))
    }

    func testStateIsGeneratedAndIsNotTheVerifier() {
        let generated = PKCE.newChallenge()
        XCTAssertEqual(generated.state.count, 43)
        XCTAssertNotEqual(generated.state, generated.verifier)
        XCTAssertTrue(PKCE.isValidVerifier(generated.state), "state travels in a URL and must be URL-safe")
    }

    func testStandaloneStateGeneration() {
        XCTAssertNotEqual(PKCE.newState(), PKCE.newState())
    }

    func testEveryAttemptGetsFreshSecrets() {
        // A reused verifier or state across attempts would defeat both PKCE and
        // the CSRF binding. Cheap to assert, catastrophic to get wrong.
        let attempts = (0 ..< 200).map { _ in PKCE.newChallenge() }
        XCTAssertEqual(Set(attempts.map(\.verifier)).count, 200)
        XCTAssertEqual(Set(attempts.map(\.state)).count, 200)
    }

    func testEncodesExactlyTheBytesTheSourceProduced() {
        // The seam's whole purpose: proves newChallenge base64url-encodes its
        // entropy rather than, say, hex-encoding it or truncating it.
        let source = FixedByteSource(byte: 0xFB)
        let generated = PKCE.newChallenge(using: source)
        XCTAssertEqual(generated.verifier, Base64URL.encode(Data(repeating: 0xFB, count: 32)))
        XCTAssertEqual(generated.state, Base64URL.encode(Data(repeating: 0xFB, count: 32)))
        XCTAssertEqual(source.requestedCounts, [32, 32])
    }

    func testCryptoRandomByteSourceReturnsTheRequestedLengthAndVaries() {
        let source = CryptoRandomByteSource()
        let first = source.bytes(32)
        XCTAssertEqual(first.count, 32)
        XCTAssertEqual(source.bytes(16).count, 16)
        XCTAssertNotEqual(first, source.bytes(32))
    }

    // ── Shape checks, mirroring the server ───────────────────────────────────

    func testVerifierBoundsMatchTheServersRegex() {
        XCTAssertTrue(PKCE.isValidVerifier(String(repeating: "a", count: 43)))
        XCTAssertTrue(PKCE.isValidVerifier(String(repeating: "a", count: 128)))
        XCTAssertFalse(PKCE.isValidVerifier(String(repeating: "a", count: 42)))
        XCTAssertFalse(PKCE.isValidVerifier(String(repeating: "a", count: 129)))
        XCTAssertTrue(PKCE.isValidVerifier("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"))
        // `+` and `/` are standard base64, not the unreserved set: a client that
        // encoded with the wrong alphabet fails here rather than at exchange.
        XCTAssertFalse(PKCE.isValidVerifier(String(repeating: "a", count: 42) + "+"))
        XCTAssertFalse(PKCE.isValidVerifier(String(repeating: "a", count: 42) + "/"))
        XCTAssertFalse(PKCE.isValidVerifier(String(repeating: "a", count: 42) + "="))
    }

    func testChallengeShapeIsExactlyFortyThreeBase64URLCharacters() {
        XCTAssertTrue(PKCE.isValidChallenge(String(repeating: "a", count: 43)))
        XCTAssertFalse(PKCE.isValidChallenge(String(repeating: "a", count: 42)))
        XCTAssertFalse(PKCE.isValidChallenge(String(repeating: "a", count: 44)))
        // ⛔ 43 characters plus padding is 44 and is refused, which is the exact
        // failure a padded base64url encoder produces.
        XCTAssertFalse(PKCE.isValidChallenge(String(repeating: "a", count: 43) + "="))
        XCTAssertFalse(PKCE.isValidChallenge(String(repeating: "a", count: 42) + "."))
        XCTAssertFalse(PKCE.isValidChallenge(String(repeating: "a", count: 42) + "~"))
    }
}

// MARK: - Helpers

/// A deterministic entropy source, so encoding can be asserted against a known
/// byte pattern.
private final class FixedByteSource: RandomByteSource, @unchecked Sendable {
    private let byte: UInt8
    private let lock = NSLock()
    private var counts: [Int] = []

    init(byte: UInt8) {
        self.byte = byte
    }

    var requestedCounts: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return counts
    }

    func bytes(_ count: Int) -> Data {
        lock.lock()
        counts.append(count)
        lock.unlock()
        return Data(repeating: byte, count: count)
    }
}
