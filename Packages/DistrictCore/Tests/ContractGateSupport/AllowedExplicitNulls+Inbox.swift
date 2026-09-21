import Foundation

// The Inbox's one allowlist entry, in a file of its own.
//
// ⛔ SPLIT OUT BECAUSE `AllowedExplicitNulls.swift` SITS AT SwiftLint's 500-LINE
// `file_length` CEILING, which is an ERROR under `--strict`. An entry plus
// the comment that justifies it does not fit there, and an entry WITHOUT that comment
// is the thing this whole register exists to prevent — see the ⛔ at the top of that
// file: "an entry is a DECISION, not a fix".
//
// ⚠️ THE UNION LIVES IN `+Union.swift`. The important property is a property of the
// merge rather than of the file: `merging(_:uniquingKeysWith:)` TRAPS
// on a duplicate key, so the same fixture named in two groups is a crash at load
// rather than one group silently winning.

extension StrictDecodeVerifier {
    /// `GET /api/district/messages/{id}` — the message-to-thread resolver.
    ///
    ///   readAt  `Message.readAt`. Null while the workspace has not marked the
    ///           message read, which on THIS route is the ordinary state rather than
    ///           an edge: the notification the resolver serves exists because nobody
    ///           has read the message yet. The route sends the key rather than
    ///           omitting it deliberately — it is what lets a notification shade drop
    ///           a "Mark read" action that would do nothing, since the inbox is
    ///           workspace-level and a colleague may have opened the thread between
    ///           the push and the tap.
    ///
    /// ⚠️ ONE PATH AND NOT THREE, WHICH IS WORTH STATING BECAUSE THE OTHER TWO
    /// OPTIONALS ON THIS RESPONSE LOOK LIKE CANDIDATES. `message.type` is nullable
    /// server-side (`Message.type` predates the column being written) and
    /// `thread.contactId` is null on an address-keyed thread — but the FIXTURE carries
    /// a real value for both, and an entry is permission rather than a requirement, so
    /// listing them would silence a null nobody has seen on a path nobody has checked.
    /// Those two branches are decoded from bytes in `InboxThreadResolveTests` instead.
    static let inbox: [String: Set<String>] = [
        "district-message-thread.json": [
            "$.message.readAt",
        ],
    ]
}
