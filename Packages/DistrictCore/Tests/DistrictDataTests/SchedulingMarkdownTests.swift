import DistrictData
import Foundation
import XCTest

/// The booking notes parser.
///
/// ⚠️ THE WEB'S RECORDINGS PARSER IS NOT PORTED (no screen here uses it); see the ⚠️ on
/// ``SchedulingMarkdown``. The booking-side halves of the old side-by-side assertions stay.
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

    // MARK: - Markers and flush order

    /// ⚠️ `•` IS NOT A BOOKING MARKER (the web's recordings parser treats it as one).
    func testABulletCharacterIsNotABookingMarker() {
        XCTAssertEqual(Markdown.bookingBlocks("• Item"), [.paragraph("• Item")])
    }

    /// ⚠️ THE FLUSH ORDER IS **NOT** OBSERVABLE: a list item flushes the pending paragraph
    /// and a paragraph line flushes the pending list, so at most one of the two is ever
    /// waiting and the order they drain in cannot show.
    func testAListThenTrailingTextKeepsLineOrder() {
        XCTAssertEqual(
            Markdown.bookingBlocks("- Item\nTrailing text\n"),
            [.list(items: ["Item"], ordered: false), .paragraph("Trailing text")]
        )
    }

    /// ⚠️ THE INVARIANT THAT MAKES THE ORDER INERT, ASSERTED DIRECTLY: a paragraph and a
    /// list never reach a flush point together, so the blocks alternate in the order the
    /// lines arrived.
    func testAParagraphAndAListNeverWaitTogether() {
        XCTAssertEqual(
            Markdown.bookingBlocks("Intro line\n- Item\nOutro line"),
            [
                .paragraph("Intro line"),
                .list(items: ["Item"], ordered: false),
                .paragraph("Outro line"),
            ]
        )
    }

    /// ⚠️ THE BOOKING PATTERNS CARRY THEIR OWN LEADING `\s*`, so an indented bullet is
    /// still a bullet.
    func testAnIndentedBulletIsStillABulletForBookings() {
        XCTAssertEqual(
            Markdown.bookingBlocks("    - Item"),
            [.list(items: ["Item"], ordered: false)]
        )
    }
}
