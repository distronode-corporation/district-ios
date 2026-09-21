import XCTest

/// The layout gate: no screen decides its layout from the device.
///
/// ⛔ THE APP LAYS ITSELF OUT FROM SIZE CLASSES AND AVAILABLE WIDTH, NEVER FROM WHAT THE
/// HARDWARE IS. An iPad in narrow Split View or Slide Over is a compact window and gets the
/// phone's tab bar; an iPad full screen is a regular one and gets the sidebar. Code that asks
/// "is this an iPad" (`userInterfaceIdiom`) or "how big is the screen" (`UIScreen.main`)
/// answers a different question from "how much room does this window have", and is wrong in
/// exactly the multitasking layouts nobody tries by hand. `UIScreen.main` is also deprecated
/// since iOS 16 for the same reason: a scene, not the device, owns a window's size.
///
/// ⛔ ONE FILE IS EXEMPT FROM THE IDIOM BAN, AND ONLY THAT FILE: `Platform/SpeakerToggleRule.swift`.
/// It reads the idiom as a HARDWARE fact (no iPad has an earpiece, every iPhone has one) to
/// decide whether "Speaker off" means anything, not to choose a layout. AVFoundation lists
/// only the output in use, never the outputs a device has, so the device family is the only
/// first-hand statement of that fact available to an app; that file's own ⛔ says the same.
/// The exemption is checked to be LIVE, so it cannot outlast the read it exists for.
///
/// ⛔ COMMENTS ARE STRIPPED BEFORE THE SCAN, which ``A11yImageTests`` deliberately does not do
/// and has paid for: a comment explaining why a token is banned would otherwise count as a
/// use of it, and this file's subject is exactly the kind of thing a comment names. Line
/// (`//`, `///`) and block (`/* */`, nested as Swift nests them) comments go; string literals
/// stay, and are skipped over so a `//` inside a string does not start a comment.
final class SourceBanTests: XCTestCase {
    /// ⚠️ SPELLED IN PIECES so this file never contains either token outside a comment, which
    /// keeps it honest if the scan is ever pointed at the test sources too.
    private static let screenMain = "UIScreen" + ".main"
    private static let idiom = "userInterface" + "Idiom"

    /// The one file allowed to read the idiom, relative to `App/Sources`.
    private static let idiomExemption = "Platform/SpeakerToggleRule.swift"

    func testNoSourceReadsTheMainScreen() throws {
        let offenders = try Self.uses(of: Self.screenMain, exempting: [])
        XCTAssertTrue(
            offenders.isEmpty,
            """
            \(Self.screenMain) is the device's screen, not this window. Size from the view \
            (GeometryReader, size classes, containerRelativeFrame) instead:
            \(offenders.joined(separator: "\n"))
            """
        )
    }

    func testOnlyTheSpeakerRuleReadsTheIdiom() throws {
        let offenders = try Self.uses(of: Self.idiom, exempting: [Self.idiomExemption])
        XCTAssertTrue(
            offenders.isEmpty,
            """
            \(Self.idiom) says what the device is, not how much room the window has; an iPad \
            in Split View is compact. Decide layout from size classes. Only \
            \(Self.idiomExemption) may read it, as a hardware fact:
            \(offenders.joined(separator: "\n"))
            """
        )
    }

    /// ⚠️ AN EXEMPTION THAT NO LONGER EXEMPTS ANYTHING IS A HOLE WAITING FOR A NEW USE. If the
    /// speaker rule stops reading the idiom, the exemption comes out with it.
    func testTheIdiomExemptionIsStillUsed() throws {
        let root = try Self.sourceRoot()
        let file = root.appendingPathComponent(Self.idiomExemption)
        let code = try Self.stripComments(String(contentsOf: file, encoding: .utf8))
        XCTAssertTrue(
            code.contains(Self.idiom),
            "\(Self.idiomExemption) no longer reads \(Self.idiom); delete the exemption in this test"
        )
    }

    // MARK: - Positive controls

    /// ⛔ THE SCANNER IS PROVED TO FIND WHAT IT IS LOOKING FOR, because a scan that matched
    /// nothing would pass every case above and look exactly like a clean tree.
    func testTheScannerFindsATokenInCode() {
        let source = """
        let width = \(Self.screenMain).bounds.width
        let pad = UIDevice.current.\(Self.idiom) == .pad
        """
        XCTAssertEqual(Self.lines(in: source, containing: Self.screenMain), [1])
        XCTAssertEqual(Self.lines(in: source, containing: Self.idiom), [2])
    }

    /// ⛔ AND IT IGNORES EVERY KIND OF COMMENT, while still seeing code on either side of one
    /// and code that follows a `//` inside a string.
    func testTheScannerIgnoresCommentsButNotCode() {
        let source = """
        // \(Self.screenMain) in a line comment
        /// \(Self.idiom) in a doc comment
        /* \(Self.screenMain) in a block /* nested \(Self.idiom) */ still in the block */
        let url = "https://example.invalid/path" ; let w = \(Self.screenMain).scale
        /** \(Self.idiom)
            across lines */ let x = UIDevice.current.\(Self.idiom)
        """
        XCTAssertEqual(Self.lines(in: source, containing: Self.screenMain), [4])
        XCTAssertEqual(Self.lines(in: source, containing: Self.idiom), [6])
    }

    /// ⚠️ THE TREE IS NOT EMPTY, so a walk that silently found no files cannot pass as clean.
    func testTheWalkReachesTheSources() throws {
        let files = try Self.swiftFiles(under: Self.sourceRoot())
        XCTAssertGreaterThan(files.count, 100, "the scan walked \(files.count) files; the app has hundreds")
    }

    // MARK: - Scanning

    /// Every non-comment line under `App/Sources` that contains `token`, as `path:line  text`.
    private static func uses(of token: String, exempting exempt: Set<String>) throws -> [String] {
        let root = try sourceRoot()
        var offenders: [String] = []
        for file in try swiftFiles(under: root) {
            let path = file.path.components(separatedBy: "App/Sources/").last ?? file.path
            guard !exempt.contains(path) else { continue }
            let source = try String(contentsOf: file, encoding: .utf8)
            let raw = source.components(separatedBy: .newlines)
            for number in lines(in: source, containing: token) {
                offenders.append("\(path):\(number)  \(raw[number - 1].trimmingCharacters(in: .whitespaces))")
            }
        }
        return offenders
    }

    /// One-based numbers of the lines whose CODE contains `token`.
    private static func lines(in source: String, containing token: String) -> [Int] {
        stripComments(source)
            .components(separatedBy: .newlines)
            .enumerated()
            .filter { $0.element.contains(token) }
            .map { $0.offset + 1 }
    }

    /// The source with every comment replaced by spaces, newlines kept, so line numbers survive.
    /// See ``CommentStripper``.
    static func stripComments(_ source: String) -> String {
        var stripper = CommentStripper(source)
        return stripper.run()
    }

    // MARK: - Walking the tree

    /// ⛔ FOUND BY WALKING UP FROM `#filePath`, as ``A11yImageTests`` does and for its reason.
    private static func sourceRoot() throws -> URL {
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

    private static func swiftFiles(under root: URL) throws -> [URL] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw XCTSkip("cannot walk \(root.path)")
        }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
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
