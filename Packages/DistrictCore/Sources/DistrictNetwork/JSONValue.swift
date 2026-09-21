import Foundation

/// A JSON document, as a value.
///
/// ⛔ THIS EXISTS BECAUSE THE REQUEST BODIES ON THIS SURFACE ARE NOT DTOs YET AND
/// THE WIRE RULE IS STRICTER THAN `Encodable`'S DEFAULT. Kotlin encodes every
/// body through `Json { explicitNulls = false }`, so a null field is **omitted**
/// rather than sent as an explicit null — and that is load-bearing on at least
/// four routes:
///
///   - `contacts/update` treats an explicit null as "clear this column" and an
///     absent key as "leave it alone";
///   - `workspace/persona` merges per field (`x !== undefined ? x : existing`),
///     so an explicit null overwrites the operator's stored persona;
///   - `workspace/messaging` reads a blank/absent secret as "keep the stored
///     ciphertext" and a present one as "store this";
///   - `messages/mark-read` requires that at least one of two keys be PRESENT.
///
/// Swift's synthesised `Encodable` omits nothing unless every optional is
/// modelled by hand on every body, which is the shape that eventually forgets
/// one. ``object(_:)`` drops nils once, centrally.
///
/// ⚠️ `.null` STILL EXISTS AS A CASE, because RESPONSES legitimately carry
/// explicit nulls (`{success, draft: null}` is the ordinary answer for a thread
/// with no draft, and `latestRun` is an explicit null for a workflow that has
/// never run). Dropping nulls is a rule about what this client SENDS.
public enum JSONValue: Sendable, Equatable {
    case string(String)
    case integer(Int)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    /// Build an object from `(key, value?)` pairs, **dropping every nil**.
    ///
    /// ⛔ THE DROP IS THE POINT. See the type note: an explicit null is a
    /// different instruction from an absent key on four of this API's routes,
    /// and on `workspace/directory` the difference between them is a wiped
    /// transfer directory answered with a 200.
    ///
    /// ⚠️ A pair whose value is `.some(.null)` is KEPT. That is the escape hatch
    /// for a route that genuinely wants an explicit null; nothing uses it today,
    /// and it must stay an explicit choice at the call site rather than a
    /// property of optionality.
    public static func object(_ pairs: [(String, JSONValue?)]) -> JSONValue {
        var result: [String: JSONValue] = [:]
        for (key, value) in pairs {
            guard let value else { continue }
            result[key] = value
        }
        return .object(result)
    }

    /// A string value, or nothing when the value is absent.
    ///
    /// ⚠️ NAMED `optional` RATHER THAN OVERLOADING `string`, on purpose: an
    /// overload taking `String?` alongside the case taking `String` resolves by
    /// inference, and the day a non-optional argument picks the wrong one the
    /// symptom is a dropped body field rather than a compile error. The request
    /// builders take `String?` parameters mirroring the Kotlin request types'
    /// nullable fields, and this is what turns one into a droppable pair.
    public static func optional(_ value: String?) -> JSONValue? {
        value.map { JSONValue.string($0) }
    }

    /// The value at `key`, when this is an object that has one.
    public subscript(key: String) -> JSONValue? {
        guard case let .object(fields) = self else { return nil }
        return fields[key]
    }

    /// The string payload, when this is a string.
    public var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    /// The boolean payload, when this is a bool.
    public var boolValue: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }

    /// The integer payload, when this is an integer.
    public var integerValue: Int? {
        guard case let .integer(value) = self else { return nil }
        return value
    }

    /// The elements, when this is an array.
    ///
    /// ⚠️ NEEDED BY MORE ROUTES THAN IT LOOKS. `GET /api/district/calls` and
    /// `GET /api/district/meetings` both answer a **bare JSON array** rather than an
    /// envelope. See ``BareArrayEndpoints``.
    public var arrayValue: [JSONValue]? {
        guard case let .array(values) = self else { return nil }
        return values
    }
}

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            // ⚠️ Int BEFORE Double, deliberately. `Double` accepts every integer
            // the API sends, and round-tripping 42 back out as `42.0` would fail
            // the strict contract gate's re-encode comparison.
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            // ⚠️ THE LAST BRANCH IS NOT A `try?` AND HAS NO `else` AFTER IT, on
            // purpose: an object is the only remaining JSON shape, so letting its
            // decode throw is both the correct error and the only reachable one.
            // A hand-written `else { throw }` here would be a branch no input can
            // reach, which is a line that can never be covered and a claim that
            // can never be tested.
            self = try .object(container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .integer(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .array(values): try container.encode(values)
        case let .object(fields): try container.encode(fields)
        case .null: try container.encodeNil()
        }
    }
}

/// Encoding and decoding of JSON bodies, with the one setting that matters.
public enum JSONWire {
    /// ⚠️ `sortedKeys` SO THE BYTES ARE DETERMINISTIC. Swift's dictionary order
    /// is seeded per process, so without this the same body encodes differently
    /// on every run — which makes a byte-exact assertion in the endpoint table
    /// flaky rather than wrong, i.e. the worst kind of test.
    public static func encode(_ value: JSONValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    /// Decode a response body, tolerating anything that is not JSON by
    /// answering nil rather than throwing.
    ///
    /// ⚠️ A NON-JSON BODY IS EXPECTED, NOT EXCEPTIONAL. A captive portal (hotel,
    /// airport, conference wifi) answers 200 with an HTML login page for every
    /// request the app makes, and an edge 502 answers HTML too.
    public static func decode(_ data: Data?) -> JSONValue? {
        guard let data, !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }
}
