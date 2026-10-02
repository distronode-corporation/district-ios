import Foundation

/// One rendered piece of a notes document.
///
/// ⛔ BLOCKS, NEVER HTML, AND THAT IS A SAFETY PROPERTY RATHER THAN A STYLE ONE. Meeting
/// notes are written by a model from a customer conversation, so their text is untrusted
/// input; the web renders these as React children (text nodes) and never through
/// `dangerouslySetInnerHTML`. The iOS equivalent is `Text`, which draws a string and
/// cannot be talked into anything else. ⚠️ Nothing here is a sanitiser — the safety comes
/// from the SINK, and a future edit that renders a block as `AttributedString(markdown:)`
/// would reintroduce exactly what this shape avoids.
public enum SchedulingNotesBlock: Equatable, Sendable {
    case heading(String)
    case paragraph(String)
    case list(items: [String], ordered: Bool)
}

/// The booking notes parser, ported from `booking-format.ts`.
///
/// ⚠️ THE WEB HAS A SECOND PARSER IN `recording-format.ts` FOR ITS RECORDINGS NOTES
/// MODAL, AND IT IS **NOT** THIS ONE: it keeps inline markup verbatim, folds ordered and
/// unordered lists into one kind and tolerates a bare `#` or `-`. This app has no
/// recordings notes screen, so it is not ported; a screen that needs it ports it rather
/// than reusing ``bookingBlocks(_:)``, or an operator sees different notes per platform.
public enum SchedulingMarkdown {
    // MARK: - Booking notes

    /// The booking detail's Notes section.
    ///
    /// ⚠️ ON A BLANK LINE THE PARAGRAPH IS FLUSHED **BEFORE** THE LIST, and at the end of
    /// input likewise. At most one of the two is ever pending (a list item flushes the
    /// paragraph and a paragraph line flushes the list), so the order is inert today and
    /// is kept as the source's for the day a construct can leave both pending.
    ///
    /// ⚠️ A NUMBERED MARKER WINS OVER A BULLET, so `1. x` is an ordered item and never a
    /// bullet one; switching between the two kinds starts a new list block rather than
    /// mixing them.
    ///
    /// ⚠️ PARAGRAPH LINES ARE JOINED WITH A SINGLE SPACE, so a hard-wrapped paragraph
    /// reflows rather than keeping the model's line breaks.
    public static func bookingBlocks(_ source: String) -> [SchedulingNotesBlock] {
        var blocks: [SchedulingNotesBlock] = []
        var paragraph: [String] = []
        var listItems: [String] = []
        var listOrdered = false
        var listOpen = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let text = stripInline(paragraph.joined(separator: " "))
            if !text.isEmpty {
                blocks.append(.paragraph(text))
            }
            paragraph = []
        }
        func flushList() {
            guard listOpen else { return }
            if !listItems.isEmpty {
                blocks.append(.list(items: listItems, ordered: listOrdered))
            }
            listItems = []
            listOpen = false
        }

        for line in splitLines(source) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushParagraph()
                flushList()
                continue
            }
            if let heading = firstGroup(Self.bookingHeading, in: line) {
                flushParagraph()
                flushList()
                let text = stripInline(heading)
                if !text.isEmpty {
                    blocks.append(.heading(text))
                }
                continue
            }
            let numbered = firstGroup(Self.bookingNumbered, in: line)
            let bullet = numbered == nil ? firstGroup(Self.bookingBullet, in: line) : nil
            if let item = numbered ?? bullet {
                flushParagraph()
                let ordered = numbered != nil
                if !listOpen || listOrdered != ordered {
                    flushList()
                    listOrdered = ordered
                    listOpen = true
                }
                let text = stripInline(item)
                if !text.isEmpty {
                    listItems.append(text)
                }
                continue
            }
            flushList()
            paragraph.append(line.trimmingCharacters(in: .whitespaces))
        }

        flushParagraph()
        flushList()
        return blocks
    }

    /// Inline markup removed, link targets kept.
    ///
    /// ⛔ THE FIVE REPLACEMENTS RUN IN THIS ORDER AND THE ORDER IS LOAD-BEARING. Images
    /// go first so that `![alt](src)` keeps its alt rather than being caught by the link
    /// rule and rendered as `!alt (src)`; bold goes before italic so `**x**` does not lose
    /// one asterisk to the single-character rule and come out as `*x*`.
    ///
    /// ⚠️ A LINK BECOMES `text (url)` RATHER THAN JUST `text`. The URL is the half an
    /// operator may need to act on, and there is nothing tappable in a `Text`, so
    /// dropping it would lose it entirely.
    public static func stripInline(_ text: String) -> String {
        var value = text
        value = replace(Self.inlineImage, in: value, with: "$1")
        value = replace(Self.inlineLink, in: value, with: "$1 ($2)")
        value = replace(Self.inlineStrong, in: value, with: "$2")
        value = replace(Self.inlineEmphasis, in: value, with: "$1$2")
        value = replace(Self.inlineCode, in: value, with: "$1")
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Patterns

    /// ⚠️ SPLIT ON `\r\n` OR `\n`, MATCHING THE SOURCE'S `/\r?\n/`. A bare `\r` is NOT a
    /// separator to the source, so `components(separatedBy: .newlines)` is the
    /// wrong tool — it would also split on `\u{2028}`, which a model can emit inside a
    /// sentence.
    static func splitLines(_ source: String) -> [String] {
        source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }

    static let bookingHeading = regex(#"^\s*#{1,6}\s+(.*)$"#)
    static let bookingBullet = regex(#"^\s*[-*+]\s+(.*)$"#)
    static let bookingNumbered = regex(#"^\s*\d+[.)]\s+(.*)$"#)

    static let inlineImage = regex(#"!\[([^\]]*)\]\(([^)]+)\)"#)
    static let inlineLink = regex(#"\[([^\]]+)\]\(([^)]+)\)"#)
    static let inlineStrong = regex(#"(\*\*|__)(.*?)\1"#)
    static let inlineEmphasis = regex(#"(^|[\s(])[*_]([^*_\n]+)[*_](?=[\s).,;:!?]|$)"#)
    static let inlineCode = regex("`([^`]*)`")

    /// ⚠️ FORCE-TRIED AT MODULE SCOPE, WHICH IS SAFE ONLY BECAUSE EVERY PATTERN IS A
    /// LITERAL IN THIS FILE. A pattern that does not compile is a programmer error the
    /// first test run traps on, not a runtime condition; making these optional would push
    /// a `?? fallback` into five call sites for a branch that cannot be reached.
    static func regex(_ pattern: String) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern)
    }

    /// The first capture group of the first match, or nil when the line does not match.
    static func firstGroup(_ expression: NSRegularExpression, in line: String) -> String? {
        let range = NSRange(line.startIndex ..< line.endIndex, in: line)
        guard let match = expression.firstMatch(in: line, range: range), match.numberOfRanges > 1,
              let group = Range(match.range(at: 1), in: line)
        else { return nil }
        return String(line[group])
    }

    static func replace(_ expression: NSRegularExpression, in value: String, with template: String) -> String {
        let range = NSRange(value.startIndex ..< value.endIndex, in: value)
        return expression.stringByReplacingMatches(
            in: value,
            range: range,
            withTemplate: template
        )
    }
}
