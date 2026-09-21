@testable import DistrictAuthCore
import Foundation
import XCTest

final class Base64URLTests: XCTestCase {
    /// The verifier octets from RFC 7636 Appendix B, whose base64url form is
    /// published in the RFC itself. Using the spec's own vector means a
    /// regression here fails against the standard rather than against a value
    /// this test made up.
    private static let rfc7636Bytes: [UInt8] = [
        116, 24, 223, 180, 151, 153, 224, 37, 79, 250, 96, 125, 216, 173,
        187, 186, 22, 212, 37, 77, 105, 214, 191, 240, 91, 88, 5, 88, 83,
        132, 141, 121,
    ]
    private static let rfc7636Encoded = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"

    func testEncodesTheRFC7636Vector() {
        let encoded = Base64URL.encode(Data(Self.rfc7636Bytes))
        XCTAssertEqual(encoded, Self.rfc7636Encoded)
    }

    func testEncodingIsUnpaddedAndUrlSafe() {
        // 0xFB 0xFF encodes to "+/8=" in standard base64: one of each
        // substituted character plus padding, so a single assertion covers all
        // three transformations.
        let encoded = Base64URL.encode(Data([0xFB, 0xFF]))
        XCTAssertEqual(encoded, "-_8")
        XCTAssertFalse(encoded.contains("="))
    }

    func testRoundTrips() {
        let original = Data(Self.rfc7636Bytes)
        XCTAssertEqual(Base64URL.decode(Base64URL.encode(original)), original)
        XCTAssertEqual(Base64URL.decode(Self.rfc7636Encoded), original)
    }

    func testDecodesEveryPaddingRemainder() {
        for length in 1 ... 4 {
            let data = Data(repeating: 0xA5, count: length)
            XCTAssertEqual(Base64URL.decode(Base64URL.encode(data)), data, "length \(length)")
        }
    }

    func testEmptyInput() {
        XCTAssertEqual(Base64URL.encode(Data()), "")
        XCTAssertEqual(Base64URL.decode(""), Data())
    }

    func testRejectsGarbage() {
        // A remainder of 1 cannot be produced by any valid encoding.
        XCTAssertNil(Base64URL.decode("A"))
        XCTAssertNil(Base64URL.decode("!!!!"))
    }
}
