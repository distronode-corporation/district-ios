import XCTest

/// The bare-symbol gate.
///
/// ⛔ THIS READS THE SOURCE RATHER THAN THE VIEW TREE, and that is the only way it
/// can work. An `Image(systemName:)` with no accessibility treatment is announced by
/// VoiceOver as its SF Symbol name — "chevron dot right", "exclamationmark dot
/// triangle" — and nothing in a unit test's reach can observe that: SwiftUI exposes
/// no inspectable accessibility tree, and a UI test can only see the symbols on
/// whatever screen it happens to be standing on. So the gate is a scan, in the same
/// shape as ``StoreCopyTests``.
///
/// ⛔ IT IS A CEILING, NOT A PROOF. Passing means every symbol carries SOME
/// treatment, not that the treatment is right — hiding a symbol that carried the
/// only meaning on screen passes this and fails a person. What it stops is the
/// regression that actually happens: a new symbol added with no thought given to it
/// at all, which is how an untreated symbol gets there.
final class A11yImageTests: XCTestCase {
    /// ⚠️ ANY ONE OF THESE COUNTS AS A DECISION HAVING BEEN MADE. `accessibilityHidden`
    /// says decoration, `accessibilityLabel` says it carries meaning, and
    /// `accessibilityElement` says an ancestor speaks for it.
    private static let treatments = [
        ".accessibilityHidden(",
        ".accessibilityLabel(",
        ".accessibilityElement(",
    ]

    /// ⚠️ HOW FAR AFTER THE `Image(` A TREATMENT MAY APPEAR. A symbol's modifiers are
    /// one per line and this app's longest styled symbol runs to four; eight is slack
    /// enough for a formatter's line wrapping without reaching the next statement.
    private static let window = 8

    /// ⚠️ SPELLED IN PIECES, as ``SourceBanTests`` spells its tokens, so this file never
    /// contains the constructor outside a comment.
    private static let constructor = "Image(" + "systemName:"

    func testEverySFSymbolCarriesAnAccessibilityDecision() throws {
        let root = try SourceScan.sourceRoot()
        var offenders: [String] = []

        for file in try SourceScan.swiftFiles(under: root) {
            // Comments stripped (``SourceScan``), so neither a symbol nor a treatment named in
            // one counts; line numbers survive the stripping.
            let lines = try SourceScan.stripComments(String(contentsOf: file, encoding: .utf8))
                .components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() where line.contains(Self.constructor) {
                let upper = min(index + Self.window, lines.count - 1)
                let window = lines[index ... upper].joined(separator: "\n")
                let treated = Self.treatments.contains { window.contains($0) }
                if !treated {
                    let path = SourceScan.relativePath(file)
                    offenders.append("\(path):\(index + 1)  \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }

        XCTAssertTrue(
            offenders.isEmpty,
            """
            An SF Symbol with no accessibility decision is announced by VoiceOver as \
            its symbol name. Add `.accessibilityHidden(true)` if it is decoration, or \
            `.accessibilityLabel(…)` if it carries meaning the text around it does not:
            \(offenders.joined(separator: "\n"))
            """
        )
    }

    /// ⚠️ AND THE COUNT IS PINNED, so a symbol DELETED along with its treatment does
    /// not quietly shrink the surface this gate covers.
    func testTheNumberOfSymbolsIsWhatWeThinkItIs() throws {
        let root = try SourceScan.sourceRoot()
        var count = 0
        for file in try SourceScan.swiftFiles(under: root) {
            count += try SourceScan.stripComments(String(contentsOf: file, encoding: .utf8))
                .components(separatedBy: Self.constructor).count - 1
        }
        // ⚠️ ELEVEN. The tenth is the chevron on
        // ``SchedulingHubView``'s section rows and the eleventh is the radio glyph on
        // ``SchedulingCalendarPickerSheet``'s destination rows; both carry
        // `.accessibilityHidden(true)`, because each sits inside a control VoiceOver
        // already announces — a `NavigationLink` for the first, a button carrying
        // `.isSelected` for the second — and the symbol on top of that is
        // "chevron dot right" or "largecircle fill circle" read beside every row.
        // ⚠️ `SchedulingEmptyState`'s glyph is NOT among these — `EmptyStateView` takes a
        // symbol NAME and constructs the `Image` itself, so it is counted at that one
        // definition rather than per caller.
        // Comments do not count: both scans read comment-stripped source.
        XCTAssertEqual(
            count, 11,
            "the app has \(count) SF Symbols, not 11 — update this number in the same "
                + "commit that adds or removes one, having decided how it is announced"
        )
    }
}
