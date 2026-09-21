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
    /// ⚠️ `ordered` IS ONLY EVER SET BY ``SchedulingMarkdown/bookingBlocks(_:)``. The
    /// recording parser cannot tell the two apart by design and always answers false; see
    /// the ⛔ on ``SchedulingMarkdown/recordingBlocks(_:)``.
    case list(items: [String], ordered: Bool)
}

/// The two notes parsers, ported from `booking-format.ts` and `recording-format.ts`.
///
/// ⛔ THERE ARE GENUINELY TWO AND THEY ARE **NOT** INTERCHANGEABLE, WHICH IS THE WHOLE
/// REASON THEY SHARE A FILE. Both turn a model's markdown into blocks and they disagree
/// on four things: the booking one strips inline markup and the recording one keeps it
/// verbatim; the booking one distinguishes ordered from unordered lists and the recording
/// one folds both into one kind; they flush a pending paragraph and a pending list in the
/// OPPOSITE ORDER; and the recording one tolerates a bare marker (`#` or `-` with no
/// text) that the booking one does not match at all. Every one of those was read off the
/// source. Collapsing them into one function would change what an operator sees on one of
/// the two screens, silently, and the difference would only show up in a document that
/// happened to use the feature.
///
/// ⚠️ THE FLUSH ORDER DIFFERS AND IS **NOT** OBSERVABLE, which is easy to get wrong by
/// reasoning and was settled by tracing both sources: in each parser a list item flushes
/// the pending PARAGRAPH before it appends, and a paragraph line flushes the pending LIST
/// before it appends — so at most one of the two is ever pending, and the order they are
/// drained in at a blank line or at end of input cannot matter. The difference is real in
/// the SOURCE and inert in BEHAVIOUR.
///
/// ⛔ IT IS STILL PORTED FAITHFULLY, because "inert today" is a property of the other
/// three rules rather than a promise. The day either parser grows a construct that can
/// leave both pending — a table, a block quote, anything that appends without flushing —
/// the order becomes load-bearing, and a port that had "simplified" it would diverge
/// silently at exactly that moment.
public enum SchedulingMarkdown {
    // MARK: - Booking notes

    /// The booking detail's Notes section.
    ///
    /// ⚠️ ON A BLANK LINE THE PARAGRAPH IS FLUSHED **BEFORE** THE LIST, and at the end of
    /// input likewise. The recording parser does the reverse.
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

    // MARK: - Recording notes

    /// The recordings screen's Notes modal.
    ///
    /// ⛔ NO INLINE STRIPPING AT ALL, AND THE LIST KIND IS NOT DISTINGUISHED. This is the
    /// source's behaviour verbatim: `-`, `*`, `•` and `1.` all produce the same list, and
    /// a `**bold**` run reaches the screen with its asterisks. It reads as the less
    /// finished of the two parsers and it is what the browser shows, so it is what this
    /// shows.
    ///
    /// ⚠️ LINES ARE TRIMMED **BEFORE** MATCHING, unlike the booking parser whose patterns
    /// carry their own leading `\s*`. The observable difference is an indented bullet: it
    /// is a list item here and also there, but an indented `#` heading is a heading here
    /// and a heading there too — the shapes coincide today and the reason they are
    /// written differently is that the sources are.
    ///
    /// ⚠️ ON A BLANK LINE AND ON A HEADING THE LIST IS FLUSHED **BEFORE** THE PARAGRAPH.
    /// The opposite of the booking parser; see the ⛔ on this type.
    ///
    /// ⚠️ A BARE `#` OR `-` WITH NO TEXT STILL FLUSHES AND ADDS NOTHING, because both
    /// patterns make their text group optional.
    public static func recordingBlocks(_ content: String) -> [SchedulingNotesBlock] {
        var blocks: [SchedulingNotesBlock] = []
        var paragraph: [String] = []
        var listItems: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph = []
        }
        func flushList() {
            guard !listItems.isEmpty else { return }
            blocks.append(.list(items: listItems, ordered: false))
            listItems = []
        }

        for raw in splitLines(content) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushList()
                flushParagraph()
                continue
            }
            if matches(Self.recordingHeading, line) {
                flushList()
                flushParagraph()
                let text = (firstGroup(Self.recordingHeading, in: line) ?? "")
                    .trimmingCharacters(in: .whitespaces)
                if !text.isEmpty {
                    blocks.append(.heading(text))
                }
                continue
            }
            if matches(Self.recordingBullet, line) {
                flushParagraph()
                let text = (firstGroup(Self.recordingBullet, in: line) ?? "")
                    .trimmingCharacters(in: .whitespaces)
                if !text.isEmpty {
                    listItems.append(text)
                }
                continue
            }
            flushList()
            paragraph.append(line)
        }

        flushList()
        flushParagraph()
        return blocks
    }

    // MARK: - Patterns

    /// ⚠️ SPLIT ON `\r\n` OR `\n`, MATCHING THE SOURCE'S `/\r?\n/`. A bare `\r` is NOT a
    /// separator to either implementation, so `components(separatedBy: .newlines)` is the
    /// wrong tool — it would also split on `\u{2028}`, which a model can emit inside a
    /// sentence.
    static func splitLines(_ source: String) -> [String] {
        source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }

    static let bookingHeading = regex(#"^\s*#{1,6}\s+(.*)$"#)
    static let bookingBullet = regex(#"^\s*[-*+]\s+(.*)$"#)
    static let bookingNumbered = regex(#"^\s*\d+[.)]\s+(.*)$"#)

    /// ⚠️ NO LEADING `\s*`, AN OPTIONAL TEXT GROUP, AND `•` AMONG THE MARKERS. All three
    /// differ from the booking patterns above and all three are the source's.
    static let recordingHeading = regex(#"^#{1,6}(?:\s+(.*))?$"#)
    static let recordingBullet = regex(#"^(?:[-*•]|\d+[.)])(?:\s+(.*))?$"#)

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

    static func matches(_ expression: NSRegularExpression, _ line: String) -> Bool {
        let range = NSRange(line.startIndex ..< line.endIndex, in: line)
        return expression.firstMatch(in: line, range: range) != nil
    }

    /// The first capture group of the first match, or nil.
    ///
    /// ⚠️ AN UNMATCHED OPTIONAL GROUP ANSWERS nil RATHER THAN AN EMPTY STRING, which is
    /// how a bare `#` is told apart from `# ` — and both callers then treat nil and empty
    /// the same way, so the distinction costs nothing and keeps the helper honest.
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
