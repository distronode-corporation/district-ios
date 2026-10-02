import XCTest

/// What the source-scanning tests share: where `App/Sources` is, its Swift files, and the
/// source with its comments blanked. Used by ``SourceBanTests`` and ``A11yImageTests``.
///
/// ⛔ THE SCANS STRIP COMMENTS FIRST: a comment explaining why a token is banned, or naming
/// an SF Symbol constructor, would otherwise count as a use of it. Line (`//`, `///`) and
/// block (`/* */`, nested as Swift nests them) comments go; string literals stay, and are
/// skipped over so a `//` inside a string does not start a comment.
enum SourceScan {
    /// ⛔ FOUND BY WALKING UP FROM `#filePath`, NOT FROM THE BUNDLE. A test bundle's
    /// resource path is inside DerivedData and says nothing about where the sources
    /// are; `#filePath` is the compiler's own record of this file's location.
    static func sourceRoot() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // App/Tests
            .deletingLastPathComponent() // App
        dir.appendPathComponent("Sources")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: dir.path),
            "sources are not on disk beside this test, so there is nothing to scan"
        )
        return dir
    }

    static func swiftFiles(under root: URL) throws -> [URL] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw XCTSkip("cannot walk \(root.path)")
        }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// A file's path relative to `App/Sources`, for a failure message.
    static func relativePath(_ file: URL) -> String {
        file.path.components(separatedBy: "App/Sources/").last ?? file.path
    }

    /// The source with every comment replaced by spaces, newlines kept, so line numbers survive.
    /// See ``CommentStripper``.
    static func stripComments(_ source: String) -> String {
        var stripper = CommentStripper(source)
        return stripper.run()
    }
}

/// Blanks every comment in a Swift source, keeping newlines so line numbers survive.
///
/// ⚠️ A SMALL LEXER, NOT A PARSER. It knows the four things that decide whether a `/` starts
/// a comment: line comments, nested block comments, string literals (single-line and
/// `"""` multi-line, with backslash escapes) and nothing else. Raw strings (`#"…"#`) are
/// read as ordinary strings, which is safe for this purpose: at worst a banned token inside
/// one is reported, never hidden.
///
/// ⚠️ ONE FUNCTION PER CONSTRUCT, each consuming exactly its own span and returning to
/// ``run()``, so the code state is the loop itself rather than a variable every branch
/// has to remember to reset.
private struct CommentStripper {
    private let chars: [Character]
    private var out: [Character] = []
    private var index = 0

    init(_ source: String) {
        chars = Array(source)
        out.reserveCapacity(chars.count)
    }

    mutating func run() -> String {
        while index < chars.count {
            switch chars[index] {
            case "/" where peek(1) == "/":
                skipLineComment()
            case "/" where peek(1) == "*":
                skipBlockComment()
            case "\"":
                copyString(multiline: peek(1) == "\"" && peek(2) == "\"")
            default:
                keep(1)
            }
        }
        return String(out)
    }

    /// Up to the newline, which is code again and is kept by ``run()``.
    private mutating func skipLineComment() {
        while index < chars.count, chars[index] != "\n" {
            blank(1)
        }
    }

    /// ⚠️ NESTED AS SWIFT NESTS THEM: `/* a /* b */ c */` is one comment, so an inner close
    /// only lowers the depth. An unterminated comment runs to the end of the source.
    private mutating func skipBlockComment() {
        var depth = 0
        repeat {
            if peek(0) == "/", peek(1) == "*" {
                depth += 1
                blank(2)
            } else if peek(0) == "*", peek(1) == "/" {
                depth -= 1
                blank(2)
            } else {
                blank(1)
            }
        } while depth > 0 && index < chars.count
    }

    /// A string literal, kept whole, escapes included, so a `//` inside one is not a comment.
    private mutating func copyString(multiline: Bool) {
        let delimiter = multiline ? 3 : 1
        keep(delimiter)
        while index < chars.count {
            if chars[index] == "\\", peek(1) != nil {
                keep(2)
            } else if closesString(multiline: multiline) {
                keep(delimiter)
                return
            } else {
                keep(1)
            }
        }
    }

    /// ⚠️ A SINGLE-LINE STRING ALSO ENDS AT A NEWLINE, so an unterminated one cannot swallow
    /// the rest of the file and hide a use of a banned token below it.
    private func closesString(multiline: Bool) -> Bool {
        guard multiline else { return peek(0) == "\"" || peek(0) == "\n" }
        return peek(0) == "\"" && peek(1) == "\"" && peek(2) == "\""
    }

    private func peek(_ offset: Int) -> Character? {
        index + offset < chars.count ? chars[index + offset] : nil
    }

    private mutating func blank(_ count: Int) {
        for step in 0 ..< count {
            out.append(chars[index + step] == "\n" ? "\n" : " ")
        }
        index += count
    }

    private mutating func keep(_ count: Int) {
        out.append(contentsOf: chars[index ..< index + count])
        index += count
    }
}
