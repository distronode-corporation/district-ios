import Foundation

/// Builds request paths from a list of SEGMENTS rather than from an
/// interpolated string.
///
/// ⛔ SEGMENT LIST, NEVER STRING INTERPOLATION. The Kotlin client
/// (`HttpDistrictApi.kt`) carries the same rule for the same reason: an id
/// interpolated into a path is percent-encoded as a whole path, so a value
/// containing `/` or `..` silently addresses a different endpoint. Every
/// segment here is encoded individually, and an empty segment is a programming
/// error rather than a collapsed path.
public enum ApiPath {
    /// Join segments into an absolute path, percent-encoding each one.
    /// Returns nil if any segment is empty (which would produce `//` and
    /// address a different route).
    public static func build(_ segments: [String]) -> String? {
        guard !segments.isEmpty else { return nil }
        var encoded: [String] = []
        encoded.reserveCapacity(segments.count)
        for segment in segments {
            guard !segment.isEmpty else { return nil }
            guard let part = segment.addingPercentEncoding(
                withAllowedCharacters: pathSegmentAllowed
            ) else { return nil }
            encoded.append(part)
        }
        return "/" + encoded.joined(separator: "/")
    }

    /// ⚠️ `.urlPathAllowed` is NOT usable here: it permits `/`, which is
    /// exactly the character a single segment must not be allowed to smuggle
    /// through. Sub-delims are also dropped so a segment cannot open a query
    /// or a fragment.
    private static let pathSegmentAllowed: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()
}
