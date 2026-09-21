import Foundation

/// `POST /api/district/contacts/enrich` — start a District Global Intelligence
/// dossier for one contact.
///
/// ⛔ IT DOES NOT CARRY THE DOSSIER, AND A CLIENT LOOKING HERE FOR THE RESULT
/// WOULD CONCLUDE THE PIPELINE HAD FAILED. The dossier lives on the CONTACT row
/// and is read back through `contacts/get`; this route only starts the work,
/// which is why its body is this small. Its sibling `contacts/clear-intel`
/// answers a bare acknowledgement and is decoded by ``SuccessResponse``.
///
/// ⛔ NON-IDEMPOTENT AND IT SPENDS MONEY. Same rule as `messages/send` and
/// `messages/draft`: never looped, never retried, never auto-fired. And it
/// ⛔ RETURNS 200 EVEN WHEN THE PUBLISH FAILED — the enqueue is best-effort — so
/// a 200 here is "accepted", not "enriched". Poll the contact's status instead.
///
/// ⛔ THE STATUS VOCABULARY IS THE SERVER'S, NOT THE WEB CONSOLE'S. The real
/// progression is `pending` → `crawling` → `synthesizing` → `complete`/`failed`,
/// with a null status meaning "no dossier and none queued". The web dashboard
/// additionally shows an optimistic "processing" that no route ever sends; a
/// client that polled for it would wait for a status that cannot arrive.
///
/// ⚠️ ``status`` AND ``message`` ARE NON-OPTIONAL, WHICH DIVERGES FROM THE KOTLIN
/// DTO. The route's 200 branch writes both as literals with no conditional
/// spread; Kotlin makes them nullable because the same type also decodes the
/// refusal body, whereas this client routes non-2xx through `ApiErrorEnvelope` —
/// `district-enrich-disabled.json` is gated as that type, not as this one.
public struct EnrichResponse: Codable, Sendable {
    public let success: Bool
    /// ⚠️ ALWAYS `pending` ON SUCCESS, and it is the value a poll loop's terminal
    /// check is written against. The row is stamped BEFORE the response returns,
    /// so the very next contact read sees `pending` rather than the
    /// pre-enrichment state — which is what lets a client tell "queued" apart
    /// from "the button did nothing".
    public let status: String
    /// Operator-facing, English, server-side. Not localised.
    public let message: String
}

/// The dossier states the server actually emits.
///
/// ⚠️ PLAIN CONSTANTS RATHER THAN AN ENUM, for the reason ``WorkspaceRole``
/// documents: the column is free text with no enum behind it, so a value this
/// client has never seen must degrade rather than throw and take out the contact
/// it arrived on.
///
/// ⛔ THERE IS NO `processing`. It is the web dashboard's optimistic local state
/// and no route sends it; polling for it never terminates.
public enum DgiStatus {
    /// What `contacts/enrich` stamps and answers with.
    public static let pending = "pending"
    public static let crawling = "crawling"
    public static let synthesizing = "synthesizing"
    public static let complete = "complete"
    public static let failed = "failed"

    /// The states a poll loop should keep polling through.
    ///
    /// ⛔ DERIVED FROM THE TERMINAL SET RATHER THAN LISTED AGAIN, so a state
    /// added above cannot be silently missing from the loop. ⚠️ An absent status
    /// is NOT in progress: after a clear the contact's status is null, which
    /// means "no dossier, and none queued" — exactly the state that should offer
    /// enrichment again rather than spin.
    public static func isInProgress(_ status: String?) -> Bool {
        guard let status else { return false }
        return ![complete, failed].contains(status)
    }
}
