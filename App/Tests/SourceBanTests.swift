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
/// ⛔ COMMENTS ARE STRIPPED BEFORE THE SCAN (``SourceScan``): a comment explaining why a token
/// is banned would otherwise count as a use of it, and this file's subject is exactly the kind
/// of thing a comment names.
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
        let root = try SourceScan.sourceRoot()
        let file = root.appendingPathComponent(Self.idiomExemption)
        let code = try SourceScan.stripComments(String(contentsOf: file, encoding: .utf8))
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
        let files = try SourceScan.swiftFiles(under: SourceScan.sourceRoot())
        XCTAssertGreaterThan(files.count, 100, "the scan walked \(files.count) files; the app has hundreds")
    }

    // MARK: - Scanning

    /// Every non-comment line under `App/Sources` that contains `token`, as `path:line  text`.
    private static func uses(of token: String, exempting exempt: Set<String>) throws -> [String] {
        let root = try SourceScan.sourceRoot()
        var offenders: [String] = []
        for file in try SourceScan.swiftFiles(under: root) {
            let path = SourceScan.relativePath(file)
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
        SourceScan.stripComments(source)
            .components(separatedBy: .newlines)
            .enumerated()
            .filter { $0.element.contains(token) }
            .map { $0.offset + 1 }
    }
}
