import Foundation
import XCTest

/// The entries of `l10n/ios.toml`, read for the tests that scan what the app says.
///
/// ⚠️ A READER FOR THE CANONICAL FILE, NOT FOR TOML. `l10n.py check` (CI's `l10n` job)
/// refuses a catalog that is not in its own canonical form, so every entry is a
/// `[group.key]` header followed by `field = value` lines, with each string a basic
/// TOML string on one line. Anything else here is a reason to fail loudly, never to
/// guess: a scan that silently read nothing would pass every assertion built on it.
enum CatalogScan {
    struct Entry: Equatable {
        let key: String
        var screen = ""
        /// One string, or one per plural form (`en.one`, `en.other`), in file order.
        var english: [String] = []
        var french: [String] = []
    }

    enum Failure: Error, CustomStringConvertible {
        case unreadable(String)
        case malformed(line: Int, text: String)

        var description: String {
            switch self {
            case let .unreadable(path): "cannot read the catalog at \(path)"
            case let .malformed(line, text): "line \(line) is not canonical catalog text: \(text)"
            }
        }
    }

    static func entries(of file: URL) throws -> [Entry] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            throw Failure.unreadable(file.path)
        }
        var entries: [Entry] = []
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            if line.isEmpty {
                continue
            }
            if line.hasPrefix("[") {
                guard line.hasSuffix("]") else { throw Failure.malformed(line: index + 1, text: line) }
                let key = String(line.dropFirst().dropLast())
                if key != "meta" {
                    entries.append(Entry(key: key))
                }
                continue
            }
            guard let equals = line.range(of: " = ") else { throw Failure.malformed(line: index + 1, text: line) }
            let field = String(line[..<equals.lowerBound])
            let value = String(line[equals.upperBound...])
            guard !entries.isEmpty, value.hasPrefix("\"") else { continue }
            guard let string = basicString(value) else { throw Failure.malformed(line: index + 1, text: line) }
            switch field {
            case "en", "en.one", "en.other": entries[entries.count - 1].english.append(string)
            case "fr", "fr.one", "fr.many", "fr.other": entries[entries.count - 1].french.append(string)
            case "screen": entries[entries.count - 1].screen = string
            default: break
            }
        }
        return entries
    }

    /// A one-line TOML basic string, `"` to `"`, with its escapes decoded; nil if malformed.
    static func basicString(_ value: String) -> String? {
        var scalars = Array(value.unicodeScalars)
        guard scalars.count >= 2, scalars.first == "\"", scalars.last == "\"" else { return nil }
        scalars = Array(scalars.dropFirst().dropLast())
        var out = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            guard scalar == "\\" else {
                if scalar == "\"" {
                    return nil
                }
                out.append(scalar)
                index += 1
                continue
            }
            guard index + 1 < scalars.count else { return nil }
            let escape = scalars[index + 1]
            switch escape {
            case "\"": out.append("\"")
            case "\\": out.append("\\")
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "u", "U":
                let width = escape == "u" ? 4 : 8
                guard index + 2 + width <= scalars.count else { return nil }
                let hex = String(String.UnicodeScalarView(scalars[(index + 2) ..< (index + 2 + width)]))
                guard let code = UInt32(hex, radix: 16), let decoded = Unicode.Scalar(code) else { return nil }
                out.append(decoded)
                index += width
            default:
                return nil
            }
            index += 2
        }
        return String(out)
    }
}
