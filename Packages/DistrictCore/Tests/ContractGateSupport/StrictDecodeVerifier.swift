import Foundation

/// The strict contract gate for the Swift client, implemented as one generic
/// function that covers every fixture.
///
/// ⛔ THIS EXISTS BECAUSE `JSONDecoder` CANNOT REJECT UNKNOWN KEYS AT ALL.
/// kotlinx.serialization has `ignoreUnknownKeys = false`, which is the entire
/// mechanism of the Kotlin contract gate; Foundation has no equivalent and no
/// hook to build one on. So the check is reconstructed out of four steps:
///
///   1. assert the raw fixture contains **no nulls**,
///   2. decode it into the DTO,
///   3. **re-encode** the DTO,
///   4. compare the re-encoded key set against the raw fixture's, recursively.
///
/// A server key the DTO does not model survives steps 1–2 (the decoder ignores
/// it) and vanishes at step 3, so step 4 is what catches it. The same walk also
/// catches an **asymmetric custom `Codable`** — an `encode(to:)` that does not
/// mirror its `init(from:)` — which no decode-only test can see.
///
/// ⛔ STRICT HERE, LENIENT IN THE FIELD. The runtime DTOs do no unknown-key
/// rejection: a new server field must red CI, and must degrade to "ignored" on
/// phones already in people's pockets rather than breaking every response.
/// Strictness lives in this file and nowhere else.
///
/// ⚠️ SHAPE, NOT VALUES. Step 4 compares key sets, JSON shapes and array
/// lengths; it does not compare scalar values, because a lossless round trip of
/// a number through `Double` is not something Foundation guarantees and a gate
/// that fails on `1` vs `1.0` would be turned off within a week. Value-level
/// expectations belong in the per-fixture tests, which assert the specific
/// awkward rows a fixture is supposed to cover.
public enum StrictDecodeVerifier {
    // ⛔ THE ONLY SANCTIONED ESCAPE FROM THE NO-NULLS INVARIANT IS
    // `allowedExplicitNulls`, AND IT LIVES IN ITS OWN FILE
    // (`AllowedExplicitNulls.swift`) BECAUSE IT IS A REGISTER RATHER THAN A
    // CONSTANT. Keyed by fixture name; the value is the set of exact JSON paths
    // (`$.workspaces[2].subscriptionTier`) permitted to hold an explicit `null`.
    // An allowlisted path is exempt from the null assertion AND from the key-set
    // comparison, so the DTO may legitimately omit it on re-encode. Every entry
    // there carries the nullable column it describes and why the server sends
    // the key rather than omitting it.

    // MARK: - Entry points

    /// Run the full gate over a committed fixture.
    ///
    /// Returns the decoded value so a caller can go on to assert the specific
    /// rows the fixture is supposed to cover.
    @discardableResult
    public static func verify<T: Codable>(fixture name: String, as type: T.Type) throws -> T {
        let data = try ContractFixtures.read(name)
        return try verify(name: name, json: data, as: type)
    }

    /// Run the full gate over an in-memory payload.
    ///
    /// ⚠️ THE SELF-TEST ENTRY POINT. `StrictDecodeVerifierTests` drives
    /// deliberately-broken payloads through this so the gate is proven able to
    /// FAIL — a gate that has only ever been seen passing is not evidence of
    /// anything. `allowingExplicitNulls` is a parameter rather than a lookup so
    /// the allowlist mechanism can be exercised in both directions against
    /// payloads small enough to read, rather than only through the real entries,
    /// where a bug would present as one fixture out of the whole corpus.
    @discardableResult
    public static func verify<T: Codable>(
        name: String,
        json data: Data,
        as type: T.Type,
        allowingExplicitNulls allowed: Set<String>? = nil
    ) throws -> T {
        let allowedNulls = allowed ?? allowedExplicitNulls[name] ?? []
        let raw = try parse(name: name, data: data)
        try assertNoNulls(in: raw, fixture: name, allowed: allowedNulls)
        let decoded = try decode(type, from: data, fixture: name)
        let encoded = try encode(decoded, fixture: name)
        let reencoded = try parse(name: name, data: encoded)
        let context = ComparisonContext(
            fixture: name,
            type: String(describing: type),
            allowedNulls: allowedNulls
        )
        try compare(raw: raw, encoded: reencoded, at: JSONPath.root, in: context)
        return decoded
    }

    // MARK: - Step 1: the no-nulls invariant

    private static func assertNoNulls(in raw: Any, fixture: String, allowed: Set<String>) throws {
        var offenders: [String] = []
        collectNullPaths(raw, at: JSONPath.root, into: &offenders)
        for path in offenders where !allowed.contains(path) {
            throw ContractGateFailure.explicitNull(fixture: fixture, path: path)
        }
    }

    private static func collectNullPaths(_ value: Any, at path: String, into found: inout [String]) {
        switch JSONShape.of(value) {
        case .null:
            found.append(path)
        case .object:
            guard let object = value as? [String: Any] else { return }
            for key in object.keys.sorted() {
                collectNullPaths(object[key] as Any, at: JSONPath.key(path, key), into: &found)
            }
        case .array:
            guard let array = value as? [Any] else { return }
            for (offset, element) in array.enumerated() {
                collectNullPaths(element, at: JSONPath.index(path, offset), into: &found)
            }
        case .string, .scalar:
            return
        }
    }

    // MARK: - Steps 2 and 3: decode, re-encode

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data, fixture: String) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ContractGateFailure.decodeFailed(
                fixture: fixture,
                type: String(describing: type),
                reason: readable(error)
            )
        }
    }

    private static func encode(_ value: some Encodable, fixture: String) throws -> Data {
        do {
            return try JSONEncoder().encode(value)
        } catch {
            throw ContractGateFailure.encodeFailed(
                fixture: fixture,
                type: String(describing: type(of: value)),
                reason: readable(error)
            )
        }
    }

    // MARK: - Step 4: the recursive key-set comparison

    private static func compare(raw: Any, encoded: Any, at path: String, in context: ComparisonContext) throws {
        let rawShape = JSONShape.of(raw)
        let encodedShape = JSONShape.of(encoded)
        guard rawShape == encodedShape else {
            throw ContractGateFailure.shapeMismatch(
                fixture: context.fixture,
                type: context.type,
                path: path,
                raw: rawShape.rawValue,
                encoded: encodedShape.rawValue
            )
        }
        switch rawShape {
        case .object:
            try compareObjects(
                raw: raw as? [String: Any] ?? [:],
                encoded: encoded as? [String: Any] ?? [:],
                at: path,
                in: context
            )
        case .array:
            try compareArrays(
                raw: raw as? [Any] ?? [],
                encoded: encoded as? [Any] ?? [],
                at: path,
                in: context
            )
        case .string, .scalar, .null:
            return
        }
    }

    private static func compareObjects(
        raw: [String: Any],
        encoded: [String: Any],
        at path: String,
        in context: ComparisonContext
    ) throws {
        let rawKeys = Set(raw.keys)
        let encodedKeys = Set(encoded.keys)
        // A key whose fixture value is an ALLOWLISTED null may legitimately be
        // omitted on re-encode: Swift writes a nil Optional as an absent key.
        let exempt = rawKeys.filter { key in
            context.allowedNulls.contains(JSONPath.key(path, key)) && JSONShape.of(raw[key] as Any) == .null
        }
        let dropped = rawKeys.subtracting(encodedKeys).subtracting(exempt).sorted()
        if !dropped.isEmpty {
            throw ContractGateFailure.droppedKeys(
                fixture: context.fixture,
                type: context.type,
                path: path,
                keys: dropped
            )
        }
        let added = encodedKeys.subtracting(rawKeys).sorted()
        if !added.isEmpty {
            throw ContractGateFailure.addedKeys(
                fixture: context.fixture,
                type: context.type,
                path: path,
                keys: added
            )
        }
        for key in rawKeys.intersection(encodedKeys).sorted() {
            try compare(
                raw: raw[key] as Any,
                encoded: encoded[key] as Any,
                at: JSONPath.key(path, key),
                in: context
            )
        }
    }

    private static func compareArrays(
        raw: [Any],
        encoded: [Any],
        at path: String,
        in context: ComparisonContext
    ) throws {
        guard raw.count == encoded.count else {
            throw ContractGateFailure.arrayLengthMismatch(
                fixture: context.fixture,
                type: context.type,
                path: path,
                raw: raw.count,
                encoded: encoded.count
            )
        }
        // ⚠️ ELEMENT-WISE, NOT SET-WISE. Rows of the same collection can and do
        // carry different key sets — `district-room-token.json` versus its
        // viewer twin is exactly that shape at the top level — so comparing a
        // union of the elements' keys would let a DTO drop a key present in one
        // row as long as some other row happened to carry it.
        for (offset, element) in raw.enumerated() {
            try compare(
                raw: element,
                encoded: encoded[offset],
                at: JSONPath.index(path, offset),
                in: context
            )
        }
    }

    // MARK: - Helpers

    /// What the recursive walk needs to carry but never changes.
    ///
    /// ⚠️ A STRUCT RATHER THAN THREE MORE PARAMETERS, because every one of the
    /// three compare functions would otherwise take six — over SwiftLint's
    /// `function_parameter_count` ceiling, and past the point where a caller can
    /// see at a glance which argument is which.
    private struct ComparisonContext {
        let fixture: String
        let type: String
        let allowedNulls: Set<String>
    }

    private static func parse(name: String, data: Data) throws -> Any {
        do {
            // ⚠️ `.fragmentsAllowed` because a fixture is not guaranteed to be an
            // object or an array: some routes answer a bare scalar, and without
            // this the parse fails with a message about the top level rather than
            // about the contract.
            return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw ContractGateFailure.unreadable(fixture: name, reason: readable(error))
        }
    }

    /// `DecodingError`'s own `localizedDescription` on Linux is the useless
    /// "The operation could not be completed", so the coding path is pulled out
    /// by hand. Without it, a missing-key failure names neither the key nor
    /// where it was expected.
    private static func readable(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return String(describing: error) }
        switch decoding {
        case let .keyNotFound(key, context):
            return "missing key `\(key.stringValue)` at \(pathText(context)) — \(context.debugDescription)"
        case let .typeMismatch(expected, context):
            return "expected \(expected) at \(pathText(context)) — \(context.debugDescription)"
        case let .valueNotFound(expected, context):
            return "null where \(expected) was required at \(pathText(context)) — \(context.debugDescription)"
        case let .dataCorrupted(context):
            return "corrupted at \(pathText(context)) — \(context.debugDescription)"
        @unknown default:
            return String(describing: decoding)
        }
    }

    private static func pathText(_ context: DecodingError.Context) -> String {
        let path = context.codingPath.map(\.stringValue).joined(separator: ".")
        return path.isEmpty ? JSONPath.root : "\(JSONPath.root).\(path)"
    }
}
