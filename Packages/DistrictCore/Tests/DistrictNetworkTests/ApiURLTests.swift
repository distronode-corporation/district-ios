@testable import DistrictNetwork
import Foundation
import XCTest

final class ApiURLTests: XCTestCase {
    private let base = URL(string: "https://www.distronode.com")!

    /// ⛔ THE `+` CASE IS WHY THIS IS NOT `URLComponents`. That type's default
    /// query encoding leaves `+` literal, and a server that form-decodes reads it
    /// as a SPACE — so a timeline read for `+15555550123` would address
    /// ` 15555550123` and answer an empty thread, which reads as "no messages"
    /// rather than as an encoding bug. E.164 is the ordinary form this API's
    /// address selector carries.
    func testAPlusInAQueryValueIsPercentEncoded() {
        let url = ApiURL.build(
            base: base,
            segments: ["api", "district", "timeline"],
            query: [ApiQueryItem("phoneNumber", "+15555550123")]
        )
        XCTAssertEqual(
            url?.absoluteString,
            "https://www.distronode.com/api/district/timeline?phoneNumber=%2B15555550123"
        )
    }

    func testReservedCharactersCannotOpenANewParameter() {
        let url = ApiURL.build(
            base: base,
            segments: ["api"],
            query: [ApiQueryItem("q", "a&b=c#d e/f?g")]
        )
        XCTAssertEqual(url?.absoluteString, "https://www.distronode.com/api?q=a%26b%3Dc%23d%20e%2Ff%3Fg")
    }

    func testNilValuesAreDropped() {
        let url = ApiURL.build(
            base: base,
            segments: ["api"],
            query: [
                ApiQueryItem("kept", "1"),
                ApiQueryItem("dropped", nil),
                ApiQueryItem("alsoKept", "2"),
            ]
        )
        XCTAssertEqual(url?.absoluteString, "https://www.distronode.com/api?kept=1&alsoKept=2")
    }

    func testATrailingSlashOnTheBaseDoesNotDoubleUp() throws {
        let url = try ApiURL.build(
            base: XCTUnwrap(URL(string: "https://www.distronode.com/")),
            segments: ["api", "billing"],
            query: []
        )
        XCTAssertEqual(url?.absoluteString, "https://www.distronode.com/api/billing")
    }

    func testAnEmptySegmentProducesNoUrlAtAll() {
        XCTAssertNil(ApiURL.build(base: base, segments: ["api", ""], query: []))
        XCTAssertNil(ApiURL.build(base: base, segments: [], query: []))
    }

    func testAQueryNameIsEncodedToo() {
        let url = ApiURL.build(base: base, segments: ["api"], query: [ApiQueryItem("a b", "c")])
        XCTAssertEqual(url?.absoluteString, "https://www.distronode.com/api?a%20b=c")
    }

    /// ⚠️ Every ``HTTPMethod`` this API uses, named so an added verb is a
    /// deliberate change rather than a silent one.
    func testTheVerbSetIsTheFiveThisApiUses() {
        XCTAssertEqual(
            Set(HTTPMethod.allCases.map(\.rawValue)),
            ["GET", "POST", "PUT", "PATCH", "DELETE"]
        )
    }

    /// ⚠️ HEADER LOOKUP IS CASE-INSENSITIVE because the two transports disagree:
    /// Darwin's URLSession canonicalises header names and the libcurl-backed Linux
    /// one does not, so a literal lookup works on a Mac and returns nil on the
    /// runner.
    func testHeaderLookupIgnoresCase() {
        let response = HTTPResponse(statusCode: 302, headers: ["LOCATION": "https://x"], body: nil)
        XCTAssertEqual(response.header("location"), "https://x")
        XCTAssertEqual(response.header("Location"), "https://x")
        XCTAssertNil(response.header("Content-Type"))
    }
}
