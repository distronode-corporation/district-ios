import Foundation

// The meetings allowlist entry, in a file of its own.
//
// ⛔ KEPT OUT OF `AllowedExplicitNulls.swift` FOR SwiftLint's 500-LINE `file_length`
// CEILING, the same reason `+Union` and `+Inbox` exist. The call-log groups there
// cannot move: the union traps on a fixture named in two groups, so every path for
// `district-calls.json` must stay in the core table. This group lives here instead.

extension StrictDecodeVerifier {
    static let meetings: [String: Set<String>] = [
        // ⛔ THREE PATHS, ALL ON ROW 0, AND THEY ARE ONE FACT RATHER THAN THREE:
        // this meeting has not ended. The voice agent's Companion writes the
        // minutes when the room closes, so an in-progress meeting has no
        // `summaryPreview`, no `endedAt` and no `title` — and it is the row most
        // likely to be at the TOP of a live user's list, i.e. the ordinary case
        // and not an edge one. ⚠️ Row 1 nulls nothing, so this single fixture
        // covers both branches and a DTO that regressed any of the three
        // Optionals to non-null fails here rather than on a phone.
        //
        //   title            `Meeting.title`. Null until somebody names the
        //                    meeting; nothing generates one.
        //   endedAt          Stamped when the room closes.
        //   summaryPreview   `summary.slice(0, 220)`, and there is no summary
        //                    until the Companion has written one.
        //
        // ⚠️ `district-meeting-detail.json` GETS NO ENTRY AND MUST NOT BE GIVEN
        // ONE. It is the whole row returned verbatim and its committed copy is a
        // COMPLETED meeting with every column populated, so there is no null to
        // permit — and an entry would silence one on a row a regeneration adds.
        "district-meetings.json": [
            "$[0].endedAt",
            "$[0].summaryPreview",
            "$[0].title",
        ],
    ]
}
