import Foundation

/// A JSON value this client CARRIES but does not interpret.
///
/// ⛔ IT EXISTS FOR THE SEVEN `Json?` COLUMNS ON THIS API WHOSE SHAPE NOTHING
/// SERVER-SIDE ENFORCES, and modelling one of them as a struct is not a
/// stricter choice — it is a wrong one. `Contact.intelligence` is a dossier
/// written by a model and its keys change with the prompt;
/// `Contact.socialHandles` is cast to `Record<string, unknown>`;
/// `Contact.visualMemory` is documented as "array of strings" and enforced as
/// nothing; `Workspace.routingRules` holds two different row shapes in one
/// array today. A typed model over any of them would DROP the keys it had not
/// heard of, and both routes that write these values (`workspace/routing-rules`,
/// `workspace/directory`) are WHOLESALE REPLACE with a zod `.passthrough()` —
/// so a value read through a lossy type and written back is a silent deletion,
/// answered with a 200.
///
/// ⚠️ CARRIED, NEVER REWRITTEN. Nothing in this client constructs one of these
/// to send. Read known keys defensively at the point of display.
///
/// ⛔ THIS IS A SECOND JSON VALUE TYPE IN ONE PACKAGE AND THAT IS A RECORDED
/// DEBT, NOT AN OVERSIGHT. `DistrictNetwork.JSONValue` is the REQUEST-side type,
/// and its `object(_:)` factory DROPS nils because an explicit null is a
/// different instruction from an absent key on four of this API's routes. This
/// one is the RESPONSE-side carrier and drops nothing — a `null` inside an
/// opaque blob is part of the value and must round-trip as a null, which is
/// what lets the strict contract gate compare an unmodelled blob at all. They
/// can and should become one type, in this module, the day `DistrictNetwork`
/// may be edited: it already depends on `DistrictModel`, so the move is
/// downward and no target gains a dependency.
public enum WireJSON: Sendable, Equatable {
    case string(String)
    case integer(Int)
    case number(Double)
    case bool(Bool)
    case array([WireJSON])
    case object([String: WireJSON])
    /// ⚠️ A CASE, NOT AN ABSENCE. A key holding an explicit null inside a blob
    /// is not the same as a key that is not there, and collapsing the two would
    /// make this type lossy in exactly the way it exists to avoid.
    case null

    /// The value at `key`, when this is an object that has one.
    public subscript(key: String) -> WireJSON? {
        guard case let .object(fields) = self else { return nil }
        return fields[key]
    }

    /// The string payload, when this is a string.
    public var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    /// The elements, when this is an array.
    public var arrayValue: [WireJSON]? {
        guard case let .array(values) = self else { return nil }
        return values
    }

    /// The fields, when this is an object.
    public var objectValue: [String: WireJSON]? {
        guard case let .object(fields) = self else { return nil }
        return fields
    }
}

extension WireJSON: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            // ⚠️ `Int` BEFORE `Double`, DELIBERATELY, AND THE CONTRACT GATE IS
            // WHY. `Double` accepts every integer the API sends, and `42`
            // re-encoded as `42.0` is a value the fixture never carried.
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([WireJSON].self) {
            self = .array(value)
        } else {
            // ⚠️ THE LAST BRANCH IS NOT A `try?` AND HAS NO `else` AFTER IT, on
            // purpose: an object is the only remaining JSON shape, so letting
            // its decode throw is both the correct error and the only reachable
            // one. A hand-written `else { throw }` would be a line no input can
            // reach — uncoverable, and a claim no test could ever check.
            self = try .object(container.decode([String: WireJSON].self))
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
        // ⛔ `encodeNil`, NOT AN OMISSION. See the note on the `null` case: the
        // strict gate compares the re-encoded document against the fixture key
        // for key, so a dropped null inside a blob would read as a lost key.
        case .null: try container.encodeNil()
        }
    }
}
