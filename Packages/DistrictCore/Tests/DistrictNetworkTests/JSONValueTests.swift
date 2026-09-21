@testable import DistrictNetwork
import Foundation
import XCTest

final class JSONValueTests: XCTestCase {
    /// ⛔ THE NIL-DROP IS THE WHOLE REASON THIS TYPE EXISTS. An explicit null is a
    /// different instruction from an absent key on `contacts/update` (clear the
    /// column), `workspace/persona` (overwrite the stored value),
    /// `workspace/messaging` (store an empty secret) and `messages/mark-read`
    /// (which validates that at least one key is PRESENT).
    func testNilPairsAreDropped() throws {
        let value = JSONValue.object([
            ("kept", .string("a")),
            ("dropped", .optional(nil)),
            ("alsoKept", .integer(1)),
        ])
        XCTAssertEqual(try encoded(value), #"{"alsoKept":1,"kept":"a"}"#)
    }

    /// ⚠️ AN EXPLICIT `.null` SURVIVES. That is the escape hatch for a route that
    /// genuinely wants one; nothing uses it today, and it must stay an explicit
    /// choice at the call site rather than a property of optionality.
    func testAnExplicitNullIsKept() throws {
        let value = JSONValue.object([("cleared", JSONValue.null)])
        XCTAssertEqual(try encoded(value), #"{"cleared":null}"#)
    }

    func testEveryScalarRoundTrips() throws {
        let value = JSONValue.object([
            ("s", .string("x")),
            ("i", .integer(42)),
            ("d", .number(1.5)),
            ("b", .bool(true)),
            ("n", JSONValue.null),
            ("a", .array([.string("one"), .integer(2)])),
            ("o", .object(["k": .string("v")])),
        ])
        let data = try JSONWire.encode(value)
        XCTAssertEqual(JSONWire.decode(data), value)
    }

    /// ⚠️ `Int` BEFORE `Double` ON DECODE. `Double` accepts every integer the API
    /// sends, and round-tripping 42 back out as `42.0` would fail the strict
    /// contract gate's re-encode comparison.
    func testAnIntegerDoesNotBecomeADouble() throws {
        let decoded = try XCTUnwrap(JSONWire.decode(Data(#"{"count":42}"#.utf8)))
        XCTAssertEqual(decoded["count"], .integer(42))
        XCTAssertEqual(try encoded(decoded), #"{"count":42}"#)
    }

    /// ⚠️ A NON-JSON BODY IS EXPECTED, NOT EXCEPTIONAL: a captive portal answers
    /// 200 with an HTML login page for every request the app makes.
    func testDecodingSomethingThatIsNotJsonAnswersNil() {
        XCTAssertNil(JSONWire.decode(nil))
        XCTAssertNil(JSONWire.decode(Data()))
        XCTAssertNil(JSONWire.decode(Data("<html>sign in</html>".utf8)))
    }

    func testAccessorsReadOnlyTheirOwnCase() {
        XCTAssertEqual(JSONValue.string("a").stringValue, "a")
        XCTAssertNil(JSONValue.integer(1).stringValue)
        XCTAssertEqual(JSONValue.integer(1).integerValue, 1)
        XCTAssertNil(JSONValue.string("1").integerValue)
        XCTAssertEqual(JSONValue.bool(false).boolValue, false)
        XCTAssertNil(JSONValue.string("false").boolValue)
        XCTAssertEqual(JSONValue.array([.integer(1)]).arrayValue, [.integer(1)])
        XCTAssertNil(JSONValue.object([:]).arrayValue)
        XCTAssertNil(JSONValue.array([]).subscriptOrNil("k"))
        XCTAssertEqual(JSONValue.object(["k": .integer(2)])["k"], .integer(2))
    }

    func testOptionalStringLifting() {
        XCTAssertEqual(JSONValue.optional("a"), .string("a"))
        XCTAssertNil(JSONValue.optional(nil))
    }

    private func encoded(_ value: JSONValue) throws -> String {
        try XCTUnwrap(String(data: JSONWire.encode(value), encoding: .utf8))
    }
}

private extension JSONValue {
    /// `subscript` on a non-object answers nil; named here so the assertion reads
    /// as a statement about the type rather than about Swift's optional chaining.
    func subscriptOrNil(_ key: String) -> JSONValue? {
        self[key]
    }
}
