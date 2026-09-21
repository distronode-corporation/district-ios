import Foundation

/// The coarse JSON shape of a value, used by the strict gate's recursive walk.
///
/// ⚠️ `bool` AND `number` ARE ONE CASE ON PURPOSE. `JSONSerialization` hands
/// back an `NSNumber` for both on Darwin *and* on swift-corelibs-foundation,
/// and the portable ways to tell them apart (`CFBooleanGetTypeID`,
/// `objCType`) either do not exist on Linux or disagree between the two. The
/// gate compares STRUCTURE, not values, so collapsing them costs nothing it
/// was ever going to catch — whereas a check that behaved differently on the
/// Linux tier than on a Mac would be worse than no check at all.
///
/// `string` is kept separate from `scalar` because that distinction *is*
/// portable (`value is String`) and a field changing from a string to a number
/// is a real contract break worth naming.
enum JSONShape: String, Sendable {
    case object
    case array
    case string
    case scalar
    case null

    /// Classify a value produced by `JSONSerialization`.
    ///
    /// ⚠️ ORDER MATTERS. `NSNull` is checked first because it is bridgeable to
    /// several of the later casts on Linux, and the dictionary/array casts come
    /// before `String` because an `NSString` inside a container would otherwise
    /// be reachable by the wrong branch.
    static func of(_ value: Any) -> JSONShape {
        if value is NSNull {
            return .null
        }
        if value is [String: Any] {
            return .object
        }
        if value is [Any] {
            return .array
        }
        if value is String {
            return .string
        }
        return .scalar
    }
}

/// Renders a JSON pointer-ish path for error messages: `$.workspaces[2].role`.
///
/// ⚠️ NOT RFC 6901. It is meant to be pasted into `jq` or read by a human
/// staring at a fixture, which the RFC's `/workspaces/2/role` form is worse at.
enum JSONPath {
    static let root = "$"

    static func key(_ base: String, _ name: String) -> String {
        "\(base).\(name)"
    }

    static func index(_ base: String, _ position: Int) -> String {
        "\(base)[\(position)]"
    }
}
