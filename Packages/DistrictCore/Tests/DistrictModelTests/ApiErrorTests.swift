@testable import DistrictModel
import XCTest

final class ApiErrorTests: XCTestCase {
    func testHttpCarriesStatusAndMessage() {
        let error = ApiError.http(status: 429, message: "Too many requests")
        XCTAssertEqual(error.httpStatus, 429)
        XCTAssertEqual(error.message, "Too many requests")
    }

    func testHttpWithoutMessageInventsNothing() {
        // Deliberate: a missing server message must stay missing so a contract
        // regression is distinguishable from a normal error at the call site.
        let error = ApiError.http(status: 500, message: nil)
        XCTAssertNil(error.message)
        XCTAssertEqual(error.httpStatus, 500)
    }

    func testTransportAndDecodingHaveNoHttpStatus() {
        XCTAssertNil(ApiError.transport("offline").httpStatus)
        XCTAssertNil(ApiError.decoding("missing key `id`").httpStatus)
        XCTAssertEqual(ApiError.transport("offline").message, "offline")
        XCTAssertEqual(ApiError.decoding("missing key `id`").message, "missing key `id`")
    }

    func testOnly401IsUnauthorized() {
        XCTAssertTrue(ApiError.http(status: 401, message: nil).isUnauthorized)
        // 403 is authenticated-but-not-permitted. Refreshing cannot fix it, and
        // treating it as a refresh trigger produces a refresh loop.
        XCTAssertFalse(ApiError.http(status: 403, message: nil).isUnauthorized)
        XCTAssertFalse(ApiError.transport("offline").isUnauthorized)
    }

    func testEquatable() {
        XCTAssertEqual(ApiError.http(status: 404, message: "nope"), .http(status: 404, message: "nope"))
        XCTAssertNotEqual(ApiError.http(status: 404, message: "nope"), .http(status: 404, message: nil))
    }
}
