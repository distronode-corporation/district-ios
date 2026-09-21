@testable import DistrictNetwork
import XCTest

final class ApiPathTests: XCTestCase {
    func testJoinsSegments() {
        XCTAssertEqual(ApiPath.build(["calls", "abc123"]), "/calls/abc123")
        XCTAssertEqual(
            ApiPath.build(["workspaces", "ws_1", "contacts"]),
            "/workspaces/ws_1/contacts"
        )
    }

    func testSingleSegment() {
        XCTAssertEqual(ApiPath.build(["overview"]), "/overview")
    }

    /// The reason this type exists: an id that contains a separator must not be
    /// able to address a different route.
    func testEncodesSeparatorsInsideASegment() {
        XCTAssertEqual(ApiPath.build(["calls", "a/b"]), "/calls/a%2Fb")
        XCTAssertEqual(ApiPath.build(["calls", ".."]), "/calls/..")
        XCTAssertEqual(ApiPath.build(["calls", "a?b#c"]), "/calls/a%3Fb%23c")
        XCTAssertEqual(ApiPath.build(["calls", "a&b=c"]), "/calls/a%26b%3Dc")
    }

    func testKeepsUnreservedCharactersLiteral() {
        XCTAssertEqual(ApiPath.build(["a-b_c.d~e"]), "/a-b_c.d~e")
    }

    func testEncodesNonASCII() {
        XCTAssertEqual(ApiPath.build(["contacts", "café"]), "/contacts/caf%C3%A9")
    }

    func testRejectsEmptyInput() {
        XCTAssertNil(ApiPath.build([]))
        XCTAssertNil(ApiPath.build(["calls", ""]))
        XCTAssertNil(ApiPath.build([""]))
    }
}
