import Foundation

// The reply composer's three routes, whose cost and safety profiles are wildly
// different and whose names are nearly identical.
//
// ⛔ `messages/drafts` (PLURAL) IS PERSISTENCE; `messages/draft` (SINGULAR) IS A
// BILLED VERTEX GENERATION. One character apart. The plural one is cheap,
// idempotent and per-author, and is the only one of the three safe to call on a
// timer; the singular one spends money on every request and is capped
// server-side at 20/min per WORKSPACE with no entitlement check in front of it.
// Nothing in this client may retry, loop or auto-fire the singular route.
//
// ⛔ `messages/media` WRITES BYTES INTO POSTGRES AND HANDS BACK AN ANONYMOUS
// CAPABILITY URL. See `UploadedMedia.url`.

/// `POST /api/district/messages/media` — the response to a multipart attachment
/// upload.
///
/// ⚠️ THE ENVELOPE IS NOT THE MEDIA. The useful value is ``media``'s `url`, which
/// is the only thing `messages/send` accepts as an attachment.
///
/// ⚠️ ``media`` IS NON-OPTIONAL, WHICH DIVERGES FROM THE KOTLIN DTO. The route
/// answers `{success, media}` on every 2xx and `{success:false, error}` with a
/// 400 or 500 otherwise; the Kotlin type decodes both branches through one shape,
/// while this client routes non-2xx bodies through `ApiErrorEnvelope`. Requiring
/// the key here is what makes a 200 that omitted it a loud contract failure
/// rather than a silently empty attachment.
public struct MediaUploadResponse: Codable, Sendable {
    public let success: Bool
    public let media: UploadedMedia
}

/// One stored attachment.
///
/// ⛔ ``url`` IS AN ANONYMOUS CAPABILITY URL AND MUST NOT BE FETCHED WITH THE
/// BEARER TOKEN. It is `/api/media/<uuid>` and answers to anyone, deliberately,
/// because a carrier's MMS fetcher has no session either — which is also why the
/// id is a uuid rather than a guessable sequence. Attaching this client's
/// `Authorization` header to it would send an access token to a route that does
/// not need one: a credential-leak surface for no benefit.
///
/// ⚠️ ``sizeBytes`` IS THE SERVER'S COUNT, NOT THE CLIENT'S. They should agree;
/// if they ever do not, the server's is the one the carrier will be billed on.
public struct UploadedMedia: Codable, Sendable {
    public let id: String
    /// `image/jpeg`, `image/png`, `image/gif` or `image/webp`. The route allows
    /// nothing else and refuses anything else with a 400 naming the rule.
    public let mimeType: String
    /// ⚠️ The server's count. See the type note.
    public let sizeBytes: Int
    /// ⛔ Anonymous capability URL. See the type note.
    public let url: String
}

/// One persisted, unsent reply.
///
/// ⛔ AUTHOR-SCOPED, UNLIKE EVERYTHING ELSE IN THE INBOX. A message's read state
/// is workspace-level — one agent opening a thread marks it read for the team —
/// but a draft is unfinished thought, and a colleague reading it reads it as a
/// decision. The server keys the row by `authorEmail` as well, so two agents hold
/// their own draft on the same thread. This client never sends an author: the
/// session decides it, and a field for it would be a way to read someone else's.
///
/// ⛔ ``body`` IS NEVER BLANK ON A ROW THAT EXISTS. The route refuses to store one
/// (400 `empty_body`, telling the caller to send DELETE instead), so "a draft
/// exists" and "there is text to restore" are the same statement.
///
/// ⚠️ ``mediaUrls`` IS ALWAYS AN ARRAY ON THE WIRE, NEVER OMITTED AND NEVER NULL.
/// The route normalises its nullable JSON column to `[]` precisely so a strict
/// decoder never has to branch on absent-versus-empty.
///
/// ⚠️ ``subject`` IS EMAIL-ONLY AND ARRIVES AS AN EXPLICIT `null` ON AN SMS
/// THREAD. `district-drafts-list.json`'s second row carries `"subject": null`,
/// which is one of the paths in `StrictDecodeVerifier.allowedExplicitNulls` —
/// the column is nullable and the route passes it through rather than omitting
/// the key.
public struct MessageDraft: Codable, Sendable {
    /// `contact:<id>` or `addr:<normalized>` — the same thread identity the
    /// Inbox list uses, and the only safe list key.
    public let threadKey: String
    /// ⛔ Never blank. See the type note.
    public let body: String
    /// Email threads only. ⚠️ Explicitly null on the wire for an SMS thread.
    public let subject: String?
    public let mediaUrls: [String]
    /// ISO-8601, server-stamped. Used to decide which of two devices typed last.
    /// This module owns no date parsing, for the reason `WorkspaceMember`
    /// documents.
    public let updatedAt: String
}

/// `GET /api/district/messages/drafts?workspaceId=&threadKey=` and
/// `PUT /api/district/messages/drafts` — one thread's unsent draft, read or
/// upserted.
///
/// ⛔ `draft: null` IS THE NORMAL ANSWER TO THE READ, NOT AN ERROR, AND THE
/// SERVER CHOSE null OVER 404 FOR EXACTLY THAT REASON. Almost every thread has no
/// draft; a 404 would make the composer's ordinary open path look like a fault in
/// every log. A client that treated a null draft as a failure would show an error
/// on the common case. `district-draft-null.json` pins that branch and IS gated,
/// through the one-path `allowedExplicitNulls` entry `$.draft` — the null is the
/// contract here, not an artefact of the fixture.
///
/// ⛔ NEVER SEND A BLANK BODY ON THE PUT. The route answers 400 with
/// `code: "empty_body"` and tells the caller to DELETE instead. That refusal is
/// deliberate rather than a silent redirect: a client that clears the box should
/// learn to send DELETE, because doing it for them hides the bug until an offline
/// queue replays the two writes out of order.
///
/// ⚠️ ONE TYPE FOR THE READ AND THE UPSERT because the route genuinely answers one
/// shape. Both fixtures are gated separately, so a divergence fails on the one
/// that changed.
public struct DraftResponse: Codable, Sendable {
    public let success: Bool
    /// ⛔ nil is the ordinary answer to a read. See the type note.
    public let draft: MessageDraft?
}

/// `GET /api/district/messages/drafts?workspaceId=` with no `threadKey` — every
/// unsent draft the signed-in author holds in this workspace.
///
/// ⛔ ONE KEY APART FROM ``DraftResponse`` AND A DIFFERENT SHAPE: the same route
/// answers `draft` (singular, nullable object) when given a thread and `drafts`
/// (an array, never null) when not. Two DTOs rather than one union, so neither
/// branch can be decoded as the other by accident, and both are gated
/// separately.
///
/// ⚠️ AUTHOR-SCOPED LIKE EVERY DRAFT READ. This is the operator's own unfinished
/// thought across their threads, not the workspace's.
///
/// ⚠️ ORDERED BY THE SERVER, MOST RECENTLY UPDATED FIRST, and this client
/// preserves that order rather than re-sorting.
public struct MessageDraftsResponse: Codable, Sendable {
    public let success: Bool
    /// ⚠️ ALWAYS AN ARRAY, NEVER NULL AND NEVER OMITTED — an author with nothing
    /// saved gets `[]`. Emptiness is therefore the "nothing to restore" test.
    public let drafts: [MessageDraft]
}

/// `POST /api/district/messages/draft` (SINGULAR) — AI reply GENERATION, not
/// persistence.
///
/// ⛔ NON-IDEMPOTENT AND BILLABLE. Every call is one Vertex/Gemini generation
/// against the billing account `VERTEX_PROJECT_ID` names, capped server-side at
/// 20/min per workspace and with no entitlement check in front of it. Same rule
/// as `messages/send` and `contacts/enrich`: nothing in this client may retry it
/// automatically, and it must never be fired from a timer, a retry helper or a
/// view's `onAppear`.
///
/// ⚠️ ``draft`` IS A BARE STRING HERE, WHERE THE PERSISTENCE ROUTE'S `draft` IS AN
/// OBJECT. Two routes one letter apart use the same key name for two different
/// types; that is the server's shape and mirroring it is the only option. Both
/// fixtures are gated side by side so the difference is visible rather than
/// inferred.
///
/// ⚠️ IT CAN LEGITIMATELY BE EMPTY: the model occasionally returns nothing and the
/// route sends `""` rather than failing. An empty generation must not blank a
/// composer the operator has already typed in.
public struct AiDraftResponse: Codable, Sendable {
    public let success: Bool
    /// ⚠️ A String, not an object. May be `""`. See the type note.
    public let draft: String
}
