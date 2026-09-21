import DistrictModel
@testable import DistrictNetwork
import Foundation
import XCTest

/// Carrying a response-side blob back onto the request side.
///
/// ⛔ THE ONE ASSERTION THAT MATTERS IS THE NULL. ``JSONValue/object(_:)`` DROPS nil pairs
/// by design — an explicit null is a different instruction from an absent key on four of
/// this API's routes — and ``JSONValue/carrying(_:)`` must not go anywhere near it, because
/// a `null` inside an opaque blob is part of the VALUE. Both `workspace/directory` and
/// `workspace/routing-rules` replace their stored array wholesale and answer 200 either
/// way, so a dropped key here is a silent deletion inside somebody's stored row.
final class JSONValueCarryingTests: XCTestCase {
    /// ⛔ AN EXPLICIT NULL SURVIVES THE CROSSING, AT THE TOP LEVEL AND NESTED. The nested
    /// case is the one a lossy implementation would still pass: dropping nils happens per
    /// object, so a shallow test on a flat row would go green.
    func testAnExplicitNullSurvivesAtEveryDepth() throws {
        let wire = WireJSON.object([
            "top": .null,
            "row": .object(["name": .string("Front desk"), "phoneNumber": .null]),
            "list": .array([.null, .string("x")]),
        ])

        let carried = JSONValue.carrying(wire)

        XCTAssertEqual(carried["top"], .null)
        XCTAssertEqual(carried["row"]?["phoneNumber"], .null)
        XCTAssertEqual(carried["list"]?.arrayValue?.first, .null)
        XCTAssertEqual(
            try encoded(carried),
            #"{"list":[null,"x"],"row":{"name":"Front desk","phoneNumber":null},"top":null}"#
        )
    }

    /// ⚠️ `Int` STAYS `Int`. Both types decode integers before doubles so the contract gate
    /// can re-encode `42` as `42`; a crossing that collapsed the numeric cases would put a
    /// decimal point into a body the server validates with a zod `.int()`.
    func testAnIntegerDoesNotBecomeADoubleOnTheWayAcross() throws {
        let carried = JSONValue.carrying(.object(["count": .integer(42), "ratio": .number(1.5)]))

        XCTAssertEqual(carried["count"], .integer(42))
        XCTAssertEqual(carried["ratio"], .number(1.5))
        XCTAssertEqual(try encoded(carried), #"{"count":42,"ratio":1.5}"#)
    }

    /// ⛔ EVERY CASE IS CARRIED, AND AN UNMODELLED KEY IS THE POINT OF THE WHOLE EXERCISE.
    /// A directory row can hold anything anyone ever wrote through the route's
    /// `.passthrough()` schema; a request rebuilt from a typed model would strip the rest.
    func testEveryCaseCrossesAndUnmodelledKeysSurvive() throws {
        let wire = WireJSON.array([
            .object([
                "name": .string("Front desk"),
                "phoneNumber": .string("+14165550101"),
                "type": .string("app"),
                "extension": .integer(204),
                "afterHours": .bool(false),
                "weight": .number(0.5),
                "tags": .array([.string("ops")]),
                "meta": .object(["source": .string("import")]),
                "retired": .null,
            ]),
        ])

        let carried = JSONValue.carrying(wire)
        let row = try XCTUnwrap(carried.arrayValue?.first)

        XCTAssertEqual(row["extension"], .integer(204))
        XCTAssertEqual(row["afterHours"], .bool(false))
        XCTAssertEqual(row["weight"], .number(0.5))
        XCTAssertEqual(row["tags"], .array([.string("ops")]))
        XCTAssertEqual(row["meta"]?["source"], .string("import"))
        XCTAssertEqual(row["retired"], .null)
        XCTAssertEqual(row["type"], .string("app"))
    }

    /// ⚠️ A BARE SCALAR IS A LEGITIMATE INPUT. The two `Json` columns hold arrays today,
    /// but the type does not promise one and a crossing that only handled containers would
    /// fail on a column somebody set to a string.
    func testABareScalarCrosses() {
        XCTAssertEqual(JSONValue.carrying(.string("x")), .string("x"))
        XCTAssertEqual(JSONValue.carrying(.bool(true)), .bool(true))
        XCTAssertEqual(JSONValue.carrying(.null), .null)
        XCTAssertEqual(JSONValue.carrying(.array([])), .array([]))
        XCTAssertEqual(JSONValue.carrying(.object([:])), .object([:]))
    }

    /// ⛔ THE ROUND TRIP IS WHAT "BYTE-IDENTICAL" ACTUALLY MEANS HERE: decode a real body
    /// into the response type, carry it across, re-encode, and get the same bytes. Anything
    /// less is a claim about the cases rather than about the value.
    func testAReadBlobReEncodesToTheSameBytes() throws {
        let source = #"{"callDirectory":[{"name":"On call","phoneNumber":null,"type":"app","x":[1,null]}]}"#
        let decoded = try JSONDecoder().decode(WireJSON.self, from: Data(source.utf8))

        XCTAssertEqual(try encoded(JSONValue.carrying(decoded)), source)
    }

    private func encoded(_ value: JSONValue) throws -> String {
        try XCTUnwrap(String(data: JSONWire.encode(value), encoding: .utf8))
    }
}
