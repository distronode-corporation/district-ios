import DistrictModel
import Foundation
import XCTest

/// ``WireJSON`` — the carrier for the `Json?` columns whose shape nothing
/// server-side enforces.
///
/// ⛔ WHAT IS PROVEN HERE IS LOSSLESSNESS, NOT CONVENIENCE, AND A LOSSY CARRIER
/// WOULD NOT FAIL LOUDLY. `workspace/routing-rules` and `workspace/directory`
/// are WHOLESALE REPLACE with a zod `.passthrough()`, so a blob read through a
/// type that dropped a key and written back is a silent deletion answered with a
/// 200. The strict contract gate can only catch that because this type
/// round-trips a value it does not understand — including a `null` inside it.
///
/// ⚠️ NO KOTLIN MIRROR TO CROSS-CHECK AGAINST. The Android client carries the
/// same columns as kotlinx `JsonObject?` / `JsonElement?`, which are library
/// types with their own test suite upstream. This enum is hand-written because
/// Foundation ships nothing equivalent, so every property the gate leans on has
/// to be pinned here rather than inherited.
final class WireJSONTests: XCTestCase {
    // MARK: - Number handling, which the gate is sensitive to

    /// ⛔ `Int` IS TRIED BEFORE `Double` AND THE RE-ENCODE IS WHY. `Double`
    /// accepts every integer the API sends, and `42` coming back out as `42.0`
    /// is a value the fixture never carried — a difference the strict gate's
    /// shape comparison would report against a DTO that is in fact correct.
    func testAnIntegerStaysAnIntegerRatherThanBecomingAFloat() throws {
        let blob = try decodeBlob(#"{"count":42,"ratio":1.5}"#)
        XCTAssertEqual(blob["count"], .integer(42))
        XCTAssertEqual(blob["ratio"], .number(1.5), "a genuine float must not be truncated to an Int")

        let text = try encodeToString(blob)
        XCTAssertTrue(text.contains(#""count":42"#), text)
        XCTAssertFalse(text.contains("42.0"), "an integer re-encoded as a float is the failure this ordering prevents")
        XCTAssertEqual(try decodeBlob(text), blob, "and the whole blob survives the trip")
    }

    // MARK: - The null case

    /// ⛔ A KEY HOLDING `null` IS A VALUE, NOT AN ABSENCE, AND COLLAPSING THE TWO
    /// WOULD MAKE THIS TYPE LOSSY IN EXACTLY THE WAY IT EXISTS TO AVOID. Swift
    /// writes a nil Optional as an omitted key, so a carrier that decoded `null`
    /// to "nothing here" would hand the gate a document missing a key the
    /// fixture had — which reads as a dropped field rather than as a bug in the
    /// carrier. `district-workspace-config.json`'s `routingRules[1].target` is
    /// the shipped instance of this shape.
    func testEveryShapeRoundTripsIncludingTheNull() throws {
        let blob = try decodeBlob(
            #"""
            {"s":"str","i":7,"d":2.5,"b":true,
             "arr":[1,"two",null],"obj":{"nested":false},"absent":null}
            """#
        )
        XCTAssertEqual(blob["s"], .string("str"))
        XCTAssertEqual(blob["i"], .integer(7))
        XCTAssertEqual(blob["d"], .number(2.5))
        XCTAssertEqual(blob["b"], .bool(true))
        XCTAssertEqual(blob["obj"]?["nested"], .bool(false))
        XCTAssertEqual(blob["absent"], .null, "an explicit null is carried as a case")
        XCTAssertEqual(blob["arr"]?.arrayValue?.count, 3)
        XCTAssertEqual(blob["arr"]?.arrayValue?[2], .null, "including inside an array")

        let text = try encodeToString(blob)
        XCTAssertTrue(text.contains(#""absent":null"#), "the null key must survive the re-encode: \(text)")
        XCTAssertEqual(try decodeBlob(text), blob, "encode(to:) must mirror init(from:) or the gate reports a drop")
    }

    // MARK: - Reading a column nothing validates

    /// ⛔ A WRONG **TYPE** IS NOT RESCUED BY A LENIENT PARSER THE WAY AN UNKNOWN
    /// KEY IS, WHICH IS WHY THESE COLUMNS ARE CARRIED RATHER THAN MODELLED.
    /// `Contact.visualMemory` is documented as "array of strings" and enforced
    /// as nothing, so a row holding an object or a scalar is a shape this client
    /// will meet. The contract is that reading it the wrong way answers nil —
    /// there is nothing to show — instead of throwing on a phone.
    func testAnAccessorAnswersNilForTheWrongShapeRatherThanThrowing() throws {
        let documented = try decodeBlob(#"{"visualMemory":["https://images.contract.test/1.png"]}"#)
        XCTAssertEqual(documented["visualMemory"]?.arrayValue?.count, 1)

        // The same column, holding the two things nothing prevents it holding.
        let asObject = try decodeBlob(#"{"visualMemory":{"note":"not an array at all"}}"#)
        XCTAssertNil(asObject["visualMemory"]?.arrayValue, "an object read as an array is nothing to show")
        XCTAssertEqual(asObject["visualMemory"]?.objectValue?.count, 1)

        let asScalar = try decodeBlob(#"{"visualMemory":"just a string"}"#)
        XCTAssertNil(asScalar["visualMemory"]?.arrayValue)
        XCTAssertNil(asScalar["visualMemory"]?.objectValue)
        XCTAssertEqual(asScalar["visualMemory"]?.stringValue, "just a string")
    }

    /// The accessors' full negative surface, stated once so no caller has to
    /// discover it. ⚠️ ``WireJSON/null`` answers nil to every one of them, which
    /// is the same answer a wrong shape gives — the two are distinguished by
    /// matching the case, not by an accessor.
    func testEveryAccessorIsShapeGuarded() {
        let object = WireJSON.object(["k": .string("v")])
        XCTAssertEqual(object["k"]?.stringValue, "v")
        XCTAssertEqual(object.objectValue?.count, 1)
        XCTAssertNil(object["missing"], "a key that is not there is nil, and that is not the same as .null")
        XCTAssertNil(object.arrayValue)
        XCTAssertNil(object.stringValue)

        let array = WireJSON.array([.string("v")])
        XCTAssertEqual(array.arrayValue?.count, 1)
        XCTAssertNil(array["k"], "subscripting a non-object is nil rather than a trap")
        XCTAssertNil(array.objectValue)
        XCTAssertNil(array.stringValue)

        let scalar = WireJSON.integer(1)
        XCTAssertNil(scalar["k"])
        XCTAssertNil(scalar.arrayValue)
        XCTAssertNil(scalar.objectValue)
        XCTAssertNil(scalar.stringValue)

        XCTAssertNil(WireJSON.null["k"])
        XCTAssertNil(WireJSON.null.arrayValue)
        XCTAssertNil(WireJSON.null.objectValue)
        XCTAssertNil(WireJSON.null.stringValue)
        XCTAssertEqual(WireJSON.null, .null, "matching the case is how null is told from absent")
    }
}

// MARK: - Helpers

/// Decode a blob the way an opaque column on a DTO does.
private func decodeBlob(_ json: String) throws -> WireJSON {
    try JSONDecoder().decode(WireJSON.self, from: Data(json.utf8))
}

/// ⚠️ `.sortedKeys` SO THE ASSERTIONS ABOVE ARE ORDER-INDEPENDENT. Dictionary
/// iteration order is not stable between runs, and a substring check against an
/// unsorted encoding is a flake waiting for a rehash.
private func encodeToString(_ value: WireJSON) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    return try XCTUnwrap(String(bytes: data, encoding: .utf8), "the encoder produced invalid UTF-8")
}
