import Foundation

/// Turns a descriptor's segments and query into one absolute URL.
///
/// ⛔ BUILT BY HAND RATHER THAN THROUGH `URLComponents`, AND NOT FOR TASTE.
/// `URLComponents.queryItems` percent-encodes with a permissive set that leaves
/// `+` literal, so a value containing one arrives at the server as a SPACE after
/// its own form decoding — and the values passed here include phone numbers
/// (`+15555550123` is the ordinary E.164 form this API's `phoneNumber` selector
/// carries) and thread keys built from them. A timeline read for `+1555…` would
/// silently address ` 1555…` and answer an empty thread, which reads as "no
/// messages" rather than as an encoding bug.
enum ApiURL {
    /// - Returns: nil when the path could not be built — an empty segment, which
    ///   would collapse to `//` and address a different route. ``ApiClient``
    ///   turns that into a transport failure rather than sending anything.
    static func build(base: URL, segments: [String], query: [ApiQueryItem]) -> URL? {
        guard let path = ApiPath.build(segments) else { return nil }

        var text = base.absoluteString
        if text.hasSuffix("/") {
            text.removeLast()
        }
        text += path

        // ⛔ NIL ENTRIES ARE DROPPED HERE, ONCE. See the ⛔ on ``ApiQueryItem``:
        // absent and present-but-empty are different instructions to this API,
        // and one of the differences is a 400 on every thread open.
        let pairs = query.compactMap { item -> String? in
            guard let value = item.value else { return nil }
            return escape(item.name) + "=" + escape(value)
        }
        if !pairs.isEmpty {
            text += "?" + pairs.joined(separator: "&")
        }
        return URL(string: text)
    }

    /// ⚠️ THE UNRESERVED SET AND NOTHING ELSE (RFC 3986 §2.3). Everything else —
    /// `+`, `&`, `=`, `?`, `#`, space, non-ASCII — is percent-encoded, so a
    /// value can neither open a new parameter nor be re-read as a space.
    ///
    /// ⚠️ WRITTEN OVER UTF-8 BYTES RATHER THAN THROUGH
    /// `addingPercentEncoding(withAllowedCharacters:)`, which returns an OPTIONAL.
    /// The `?? value` fallback that would need is a branch no input can reach, so
    /// it is a line that can never be covered and a claim that can never be
    /// tested. Byte-wise encoding is total.
    private static func escape(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            if isUnreserved(byte) {
                out.append(Character(UnicodeScalar(byte)))
            } else {
                out.append("%")
                out.append(hex[Int(byte >> 4)])
                out.append(hex[Int(byte & 0x0F)])
            }
        }
        return out
    }

    private static func isUnreserved(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A") ... UInt8(ascii: "Z"),
             UInt8(ascii: "a") ... UInt8(ascii: "z"),
             UInt8(ascii: "0") ... UInt8(ascii: "9"),
             UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
            true
        default:
            false
        }
    }

    private static let hex = Array("0123456789ABCDEF")
}
