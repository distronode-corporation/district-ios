import Foundation

/// Every way the strict contract gate can refuse a fixture.
///
/// ⛔ EACH CASE NAMES THE FIXTURE AND THE JSON PATH, AND THAT IS THE POINT.
/// The gate runs over the whole fixture corpus in one test, so "the contract
/// gate failed" without a path is a bisect by hand through dozens of files.
/// `description` is what XCTest prints, so it carries the fixture, the path,
/// the offending keys and — where there is one — the fix.
public enum ContractGateFailure: Error, CustomStringConvertible, Equatable {
    /// Step 1: the fixture carries an explicit `null`.
    case explicitNull(fixture: String, path: String)
    /// The fixture is not readable, or is not JSON at all.
    case unreadable(fixture: String, reason: String)
    /// Step 2: `JSONDecoder` refused the fixture.
    case decodeFailed(fixture: String, type: String, reason: String)
    /// Step 3: `JSONEncoder` refused the decoded value.
    case encodeFailed(fixture: String, type: String, reason: String)
    /// Step 4: keys present in the fixture that the DTO did not re-emit.
    case droppedKeys(fixture: String, type: String, path: String, keys: [String])
    /// Step 4: keys the DTO emitted that the fixture never carried.
    case addedKeys(fixture: String, type: String, path: String, keys: [String])
    /// Step 4: the value at `path` changed JSON shape across the round trip.
    case shapeMismatch(fixture: String, type: String, path: String, raw: String, encoded: String)
    /// Step 4: an array changed length across the round trip.
    case arrayLengthMismatch(fixture: String, type: String, path: String, raw: Int, encoded: Int)

    public var description: String {
        switch self {
        case let .explicitNull(fixture, path):
            explicitNullDescription(fixture: fixture, path: path)
        case let .unreadable(fixture, reason):
            "contract gate [\(fixture)]: fixture is unreadable — \(reason)"
        case let .decodeFailed(fixture, type, reason):
            """
            contract gate [\(fixture)] -> \(type): DECODE FAILED.
              \(reason)
              The fixture is generated from the real route handler, so the DTO is
              what is wrong. Add the field, or make it Optional if the route only
              sometimes emits it.
            """
        case let .encodeFailed(fixture, type, reason):
            "contract gate [\(fixture)] -> \(type): RE-ENCODE FAILED — \(reason)"
        case let .droppedKeys(fixture, type, path, keys):
            droppedKeysDescription(fixture: fixture, type: type, path: path, keys: keys)
        case let .addedKeys(fixture, type, path, keys):
            addedKeysDescription(fixture: fixture, type: type, path: path, keys: keys)
        case let .shapeMismatch(fixture, type, path, raw, encoded):
            """
            contract gate [\(fixture)] -> \(type): SHAPE CHANGED at \(path).
              fixture: \(raw)   re-encoded: \(encoded)
              The DTO models this position as a different kind of JSON value than
              the server sends.
            """
        case let .arrayLengthMismatch(fixture, type, path, raw, encoded):
            """
            contract gate [\(fixture)] -> \(type): ARRAY LENGTH CHANGED at \(path).
              fixture: \(raw) element(s)   re-encoded: \(encoded)
              A custom Codable implementation is filtering or padding elements.
            """
        }
    }

    private func explicitNullDescription(fixture: String, path: String) -> String {
        """
        contract gate [\(fixture)]: EXPLICIT NULL at \(path).
          The gate's soundness rests on the no-nulls fixture invariant: Swift
          encodes a nil Optional as an OMITTED key, so an explicit null in the
          fixture makes the key-set comparison report a mismatch that is not a
          real contract break.
          ⛔ Do NOT loosen the comparison to make this pass — that silently
          retires the check for every other fixture. If this null is genuinely
          part of the contract, add the exact path above to
          StrictDecodeVerifier.allowedExplicitNulls[\"\(fixture)\"].
        """
    }

    private func droppedKeysDescription(fixture: String, type: String, path: String, keys: [String]) -> String {
        """
        contract gate [\(fixture)] -> \(type): KEYS LOST at \(path).
          \(keys.joined(separator: ", "))
          JSONDecoder cannot reject unknown keys, so these decoded away silently
          and only reappeared as missing on re-encode. Either the DTO is missing
          a field the server sends, or a hand-written encode(to:) is asymmetric
          with its init(from:).
        """
    }

    private func addedKeysDescription(fixture: String, type: String, path: String, keys: [String]) -> String {
        """
        contract gate [\(fixture)] -> \(type): KEYS INVENTED at \(path).
          \(keys.joined(separator: ", "))
          The DTO re-encoded keys the server never sent. A non-Optional property
          with a default, or an asymmetric encode(to:), will do this — and it
          means the app is modelling a field the contract does not carry.
        """
    }
}
