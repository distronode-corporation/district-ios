@testable import DistrictAuthCore
import Foundation
import XCTest

/// ``AppleNonce``, pinned against published SHA-256 vectors rather than against
/// itself.
///
/// ⛔ A SELF-CONSISTENCY TEST WOULD PASS WHILE BOTH SIDES WERE WRONG, WHICH IS
/// THE WHOLE REASON THE VECTORS BELOW ARE HERE. The only thing that ever
/// disagrees with this client is `sha256Hex` on the server, and it reports the
/// disagreement as one opaque `invalid_grant` — indistinguishable from a
/// replayed token, an expired one, or a wrong audience. Asserting
/// `AppleNonce(raw: x).hashed == AppleNonce.sha256Hex(x)` would prove only that
/// the type calls its own function. The three below are FIPS 180-2 / RFC 6234's
/// own vectors, the corpus every SHA-256 implementation is checked against, so a
/// digest that matches them matches the server's by construction.
final class AppleNonceTests: XCTestCase {
    // ── The digest ───────────────────────────────────────────────────────────

    /// ⛔ THE PUBLISHED VECTORS, LOWER-CASE HEX. `""` and `"abc"` are the two
    /// best-known SHA-256 test inputs and they catch the two failure modes that
    /// matter: a wrong digest, and a digest formatted as upper-case hex or
    /// base64 (`POST /api/auth/native/apple` compares STRINGS, so `BA7816BF…`
    /// is refused exactly as a wrong hash would be).
    func testTheDigestMatchesThePublishedVectors() {
        XCTAssertEqual(
            AppleNonce.sha256Hex(""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        XCTAssertEqual(
            AppleNonce.sha256Hex("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertEqual(
            AppleNonce.sha256Hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        )
    }

    /// ⚠️ UTF-8 BYTES, NOT UTF-16 AND NOT A LOSSY ASCII TRANSCODE. A raw nonce
    /// this client mints is hex, so the distinction cannot bite in production —
    /// which is precisely why it needs a test: nothing else in the flow would
    /// ever notice if it changed.
    func testTheDigestHashesUtf8Bytes() {
        // U+00E9, which is TWO bytes in UTF-8 (0xC3 0xA9) and one in UTF-16 or
        // Latin-1. A digest computed over either of the others differs.
        XCTAssertEqual(
            AppleNonce.sha256Hex("é"),
            "4a99557e4033c3539de2eb65472017cad5f9557f7a0625a09f1c3f6e2ba69c4c"
        )
    }

    /// ⛔ THE WHOLE NIBBLE TABLE. A hex encoder that gets the high and low
    /// nibbles the right way round for `0x00`-`0x0f` and wrong above it is a
    /// classic, and a digest test alone can miss it — every byte of a digest is
    /// plausible, so a transposed pair just produces a different plausible
    /// string.
    func testEveryByteValueEncodesToItsOwnHexPair() {
        let source = FixedBytes(Data((0 ... 255).map { UInt8($0) }))

        let nonce = AppleNonce.new(using: source)

        XCTAssertEqual(nonce.raw.count, AppleNonce.byteCount * 2)
        // `new` asks for 32 bytes, so it sees 0x00...0x1f.
        XCTAssertEqual(nonce.raw, "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
    }

    /// ⚠️ THE HIGH NIBBLE IS THE ONE A SHIFT BUG BREAKS, and the table test
    /// above only reaches 0x1f. `0xf7` has both nibbles set high and they
    /// differ, so a `& 0x0f` applied to the wrong half, or a missing `>> 4`,
    /// changes the answer.
    func testTheHighNibbleIsNotTruncated() {
        let source = FixedBytes(Data(repeating: 0xF7, count: 64))

        let nonce = AppleNonce.new(using: source)

        XCTAssertEqual(nonce.raw, String(repeating: "f7", count: AppleNonce.byteCount))
    }

    // ── The two halves ───────────────────────────────────────────────────────

    /// ⛔ ONE INITIALISER, AND IT TAKES ONLY THE RAW VALUE. The two halves cannot
    /// be supplied out of step because there is no way to supply them
    /// separately: sending the hash in the body, or the raw value on the
    /// request, is refused by the server and reads as a replayed token.
    func testTheHashedHalfIsDerivedFromTheRawOne() {
        let nonce = AppleNonce(raw: "abc")

        XCTAssertEqual(nonce.raw, "abc")
        XCTAssertEqual(nonce.hashed, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        // ⚠️ And they are never equal, which is the shape of the bug this
        // guards: a client that "simplified" the pair to one value.
        XCTAssertNotEqual(nonce.raw, nonce.hashed)
    }

    func testTwoNoncesWithTheSameRawValueAreEqual() {
        XCTAssertEqual(AppleNonce(raw: "abc"), AppleNonce(raw: "abc"))
        XCTAssertNotEqual(AppleNonce(raw: "abc"), AppleNonce(raw: "abd"))
    }

    // ── Generation ───────────────────────────────────────────────────────────

    /// ⚠️ 32 BYTES ASKED FOR, 64 CHARACTERS PRODUCED, AND THE COUNT IS ASSERTED
    /// ON THE SOURCE rather than inferred from the string — a generator that
    /// asked for 16 and doubled them would produce a 64-character value too.
    func testGenerationAsksForThirtyTwoBytes() {
        let source = FixedBytes(Data(repeating: 0xAB, count: 64))

        let nonce = AppleNonce.new(using: source)

        XCTAssertEqual(source.requestedCounts, [32])
        XCTAssertEqual(AppleNonce.byteCount, 32)
        XCTAssertEqual(nonce.raw.count, 64)
        XCTAssertEqual(nonce.hashed.count, 64)
    }

    /// ⚠️ THE ALPHABET IS ASSERTED EVEN THOUGH THE SERVER DOES NOT CHECK IT. The
    /// value travels in a JSON body and in no URL, so nothing would break if it
    /// were not hex — but "URL-safe, JSON-safe, nothing an intermediary
    /// re-encodes" is the property the type claims, and an unasserted claim
    /// decays.
    func testAGeneratedNonceIsLowerCaseHexOnly() {
        let allowed = Set("0123456789abcdef")

        for _ in 0 ..< 32 {
            let nonce = AppleNonce.new()
            XCTAssertTrue(nonce.raw.allSatisfy(allowed.contains), nonce.raw)
            XCTAssertTrue(nonce.hashed.allSatisfy(allowed.contains), nonce.hashed)
            XCTAssertTrue(AppleNonce.isValidRaw(nonce.raw))
        }
    }

    /// ⛔ SINGLE USE MEANS IT MUST NOT REPEAT. The production source is
    /// swift-crypto's CSPRNG (see ``CryptoRandomByteSource``); this only proves
    /// the default argument is wired to it rather than to a constant, which is
    /// the mistake a test double makes easy.
    func testGeneratedNoncesVary() {
        let minted = Set((0 ..< 64).map { _ in AppleNonce.new().raw })

        XCTAssertEqual(minted.count, 64)
    }

    // ── The server's length window ───────────────────────────────────────────

    /// ⚠️ `z.string().min(16).max(256)`, LENGTH ONLY. Asserting a hex alphabet
    /// in `isValidRaw` would be this client inventing a rule the server does not
    /// have, and the first thing it would break is a future nonce format.
    func testTheLengthWindowMatchesTheRouteSchema() {
        XCTAssertFalse(AppleNonce.isValidRaw(""))
        XCTAssertFalse(AppleNonce.isValidRaw(String(repeating: "a", count: 15)))
        XCTAssertTrue(AppleNonce.isValidRaw(String(repeating: "a", count: 16)))
        XCTAssertTrue(AppleNonce.isValidRaw(String(repeating: "a", count: 256)))
        XCTAssertFalse(AppleNonce.isValidRaw(String(repeating: "a", count: 257)))
        // Not hex, and accepted: the schema has no alphabet.
        XCTAssertTrue(AppleNonce.isValidRaw(String(repeating: "z", count: 20)))
    }
}

// MARK: - Helpers

/// A deterministic entropy source that hands out a fixed byte pattern, so hex
/// encoding can be asserted against a known value.
///
/// ⚠️ SEPARATE FROM `PKCETests`' `FixedByteSource`, which repeats ONE byte. That
/// cannot catch a transposed nibble (`0xAB` and `0xBA` both repeat), which is
/// the specific bug the table test above exists for.
private final class FixedBytes: RandomByteSource, @unchecked Sendable {
    private let pattern: Data
    private let lock = NSLock()
    private var counts: [Int] = []

    init(_ pattern: Data) {
        self.pattern = pattern
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
        return pattern.prefix(count)
    }
}
