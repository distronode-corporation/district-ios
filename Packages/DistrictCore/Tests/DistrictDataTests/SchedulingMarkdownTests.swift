import DistrictData
import Foundation
import XCTest

/// The two notes parsers, and the four ways they differ.
///
/// ⛔ THE DIFFERENCES ARE ASSERTED SIDE BY SIDE, WHICH IS THE POINT OF THIS FILE. Two
/// functions that both turn markdown into blocks are exactly the shape somebody unifies,
/// and unifying them would change what one of the two screens renders — silently, and only
/// for a document that happened to use the feature.
final class SchedulingMarkdownTests: XCTestCase {
    private typealias Markdown = SchedulingMarkdown

    // MARK: - Booking notes

    func testAHeadingAParagraphAndAListAreSeparateBlocks() {
        let blocks = Markdown.bookingBlocks("""
        # Summary

        We agreed the scope.

        - Ship on Friday
        - Invoice after
        """)
        XCTAssertEqual(blocks, [
            .heading("Summary"),
            .paragraph("We agreed the scope."),
            .list(items: ["Ship on Friday", "Invoice after"], ordered: false),
        ])
    }

    /// ⚠️ A NUMBERED MARKER WINS OVER A BULLET and produces an ORDERED list.
    func testANumberedListIsOrdered() {
        XCTAssertEqual(
            Markdown.bookingBlocks("1. First\n2. Second"),
            [.list(items: ["First", "Second"], ordered: true)]
        )
        XCTAssertEqual(
            Markdown.bookingBlocks("1) First"),
            [.list(items: ["First"], ordered: true)]
        )
    }

    /// ⚠️ SWITCHING KINDS STARTS A NEW BLOCK rather than mixing them.
    func testSwitchingBetweenOrderedAndUnorderedStartsANewList() {
        XCTAssertEqual(
            Markdown.bookingBlocks("- A\n1. B"),
            [.list(items: ["A"], ordered: false), .list(items: ["B"], ordered: true)]
        )
    }

    /// ⚠️ PARAGRAPH LINES JOIN WITH A SINGLE SPACE, so a hard-wrapped paragraph reflows.
    func testParagraphLinesReflowWithASingleSpace() {
        XCTAssertEqual(
            Markdown.bookingBlocks("One line\nand another"),
            [.paragraph("One line and another")]
        )
    }

    func testTheThreeBulletMarkersAllWork() {
        for marker in ["-", "*", "+"] {
            XCTAssertEqual(
                Markdown.bookingBlocks("\(marker) Item"),
                [.list(items: ["Item"], ordered: false)],
                marker
            )
        }
    }

    /// ⚠️ A BARE `#` WITH NO SPACE IS NOT A HEADING to this parser — the pattern needs
    /// `\s+`. It becomes a paragraph, which is the source's behaviour.
    func testABareHashIsAParagraphToTheBookingParser() {
        XCTAssertEqual(Markdown.bookingBlocks("#"), [.paragraph("#")])
    }

    func testEmptyInputIsNoBlocks() {
        XCTAssertTrue(Markdown.bookingBlocks("").isEmpty)
        XCTAssertTrue(Markdown.bookingBlocks("   \n\n  ").isEmpty)
    }

    func testCarriageReturnsAreHandled() {
        XCTAssertEqual(
            Markdown.bookingBlocks("# Title\r\n\r\nBody"),
            [.heading("Title"), .paragraph("Body")]
        )
    }

    // MARK: - stripInline

    /// ⛔ THE ORDER OF THE FIVE REPLACEMENTS IS LOAD-BEARING. An image handled after the
    /// link rule comes out as `!alt (src)`.
    func testAnImageKeepsItsAltAndLosesItsSource() {
        XCTAssertEqual(Markdown.stripInline("![a picture](https://x/y.png)"), "a picture")
    }

    /// ⚠️ A LINK BECOMES `text (url)`: there is nothing tappable in a `Text`, so dropping
    /// the target would lose it entirely.
    func testALinkKeepsItsTargetInBrackets() {
        XCTAssertEqual(
            Markdown.stripInline("see [the doc](https://x/y)"),
            "see the doc (https://x/y)"
        )
    }

    /// ⛔ BOLD BEFORE ITALIC, or `**x**` loses one asterisk and comes out as `*x*`.
    func testBoldIsStrippedBeforeItalic() {
        XCTAssertEqual(Markdown.stripInline("**bold**"), "bold")
        XCTAssertEqual(Markdown.stripInline("__bold__"), "bold")
    }

    func testItalicAndCodeAreStripped() {
        XCTAssertEqual(Markdown.stripInline("an *italic* word"), "an italic word")
        XCTAssertEqual(Markdown.stripInline("an _italic_ word"), "an italic word")
        XCTAssertEqual(Markdown.stripInline("a `code` span"), "a code span")
    }

    func testTheResultIsTrimmed() {
        XCTAssertEqual(Markdown.stripInline("  spaced  "), "spaced")
    }

    /// ⚠️ AN UNDERSCORE INSIDE A WORD IS NOT ITALIC. The pattern requires a boundary
    /// before it, which is what keeps `event_type_slug` readable in a note.
    func testAnUnderscoreInsideAWordSurvives() {
        XCTAssertEqual(Markdown.stripInline("event_type_slug"), "event_type_slug")
    }

    func testInlineMarkupIsStrippedInsideBookingBlocks() {
        XCTAssertEqual(
            Markdown.bookingBlocks("- **Ship** on Friday"),
            [.list(items: ["Ship on Friday"], ordered: false)]
        )
    }

    // MARK: - Recording notes

    /// ⛔ NO INLINE STRIPPING AT ALL — the asterisks reach the screen. This is the
    /// source's behaviour and the single sharpest difference between the two parsers.
    func testTheRecordingParserKeepsInlineMarkupVerbatim() {
        XCTAssertEqual(
            Markdown.recordingBlocks("**bold** stays"),
            [.paragraph("**bold** stays")]
        )
    }

    /// ⛔ ORDERED AND UNORDERED ARE NOT DISTINGUISHED: both fold into one list, always
    /// `ordered: false`.
    func testTheRecordingParserFoldsBothListKindsIntoOne() {
        XCTAssertEqual(
            Markdown.recordingBlocks("- A\n1. B"),
            [.list(items: ["A", "B"], ordered: false)]
        )
    }

    /// ⚠️ `•` IS A MARKER HERE AND NOT IN THE BOOKING PARSER.
    func testABulletCharacterIsAMarkerOnlyForRecordings() {
        XCTAssertEqual(
            Markdown.recordingBlocks("• Item"),
            [.list(items: ["Item"], ordered: false)]
        )
        XCTAssertEqual(Markdown.bookingBlocks("• Item"), [.paragraph("• Item")])
    }

    /// ⚠️ A BARE MARKER IS TOLERATED: it flushes and adds nothing, because the text group
    /// is optional.
    func testABareMarkerIsConsumedWithoutAddingAnything() {
        XCTAssertTrue(Markdown.recordingBlocks("#").isEmpty)
        XCTAssertTrue(Markdown.recordingBlocks("-").isEmpty)
    }

    func testTheRecordingParserReadsAHeadingAndAList() {
        XCTAssertEqual(
            Markdown.recordingBlocks("# Notes\n\n- One\n- Two"),
            [.heading("Notes"), .list(items: ["One", "Two"], ordered: false)]
        )
    }

    /// ⚠️ THE FLUSH ORDER DIFFERS IN THE SOURCE AND IS **NOT** OBSERVABLE, AND THIS TEST
    /// WAS WRITTEN TO PROVE THE OPPOSITE BEFORE THE SOURCES WERE TRACED. In each parser a
    /// list item flushes the pending paragraph and a paragraph line flushes the pending
    /// list, so at most one of the two is ever waiting and the order they drain in cannot
    /// show. Kept, asserting the agreement, because "these two produce the same sequence"
    /// is the fact — and because the ⛔ on ``SchedulingMarkdown`` explains why the port
    /// still keeps the orders apart.
    func testTheDifferingFlushOrdersProduceTheSameSequence() {
        let source = "- Item\nTrailing text\n"
        let expected: [SchedulingNotesBlock] = [
            .list(items: ["Item"], ordered: false),
            .paragraph("Trailing text"),
        ]
        XCTAssertEqual(Markdown.bookingBlocks(source), expected)
        XCTAssertEqual(Markdown.recordingBlocks(source), expected)
    }

    /// ⚠️ THE INVARIANT THAT MAKES THE ORDER INERT, ASSERTED DIRECTLY: a paragraph and a
    /// list never reach a flush point together, so whichever drains first, the blocks
    /// alternate in the order the lines arrived.
    func testAParagraphAndAListNeverWaitTogether() {
        XCTAssertEqual(
            Markdown.bookingBlocks("Intro line\n- Item\nOutro line"),
            [
                .paragraph("Intro line"),
                .list(items: ["Item"], ordered: false),
                .paragraph("Outro line"),
            ]
        )
        XCTAssertEqual(
            Markdown.recordingBlocks("Intro line\n- Item\nOutro line"),
            [
                .paragraph("Intro line"),
                .list(items: ["Item"], ordered: false),
                .paragraph("Outro line"),
            ]
        )
    }

    func testRecordingInputThatIsOnlyWhitespaceIsEmpty() {
        XCTAssertTrue(Markdown.recordingBlocks("").isEmpty)
        XCTAssertTrue(Markdown.recordingBlocks("  \n \n").isEmpty)
    }

    /// ⚠️ LINES ARE TRIMMED BEFORE MATCHING HERE, so an indented bullet is still a bullet.
    func testAnIndentedBulletIsStillABulletForRecordings() {
        XCTAssertEqual(
            Markdown.recordingBlocks("    - Item"),
            [.list(items: ["Item"], ordered: false)]
        )
    }

    /// ⚠️ THE BOOKING PATTERNS CARRY THEIR OWN LEADING `\s*`, so an indented bullet works
    /// there too — by a different mechanism, which is why both are asserted.
    func testAnIndentedBulletIsStillABulletForBookings() {
        XCTAssertEqual(
            Markdown.bookingBlocks("    - Item"),
            [.list(items: ["Item"], ordered: false)]
        )
    }
}
