import Foundation

/// Where a workspace's questions are ANSWERED.
///
/// ⛔ `linked` SENDS THE QUESTION TO ATLASSIAN, SO THIS IS A DATA-RESIDENCY
/// CONTROL AND NOT A DISPLAY PREFERENCE. `internal` retrieves inside the
/// workspace's own region, over documents the workspace uploaded; `linked` hands
/// the question to the support desk's assistant, which composes the answer from
/// help-centre content nobody holds per workspace. That is why the route's WRITE
/// excludes `viewer` while its READ admits one, and why a UI must confirm the
/// switch rather than treating it as an ordinary toggle.
///
/// ⛔ THE WRITE TAKES THIS AND NOT A `String`, WHICH IS WHAT MAKES THE ROUTE'S
/// 400 UNREACHABLE FROM THIS CLIENT. `PATCH knowledge-mode` validates with
/// `z.enum(KB_MODES)`, so an unrecognised mode is refused outright rather than
/// stored, and a repository that took a bare string would be a repository that
/// could earn that 400. See ``KnowledgeModeResponse/mode`` for why the READ is
/// deliberately NOT typed as this.
///
/// ⚠️ THEY ARE NOT ADDITIVE, which is the reason this is a choice rather than two
/// switches: two sources drift and then contradict each other in front of a
/// customer, which is worse than either alone.
///
/// ⚠️ `internal` CARRIES BACKTICKS because it is a Swift access-level keyword.
/// The wire spelling is unchanged, which is the only thing the server sees.
public enum KnowledgeMode: String, Sendable, CaseIterable {
    /// The server's default, and for a substantive reason rather than
    /// conservatism: a workspace that never opens this setting must not have its
    /// questions leave its region because of a choice nobody made.
    case `internal`
    /// ⛔ The question is sent to a third party to compose the answer.
    case linked
}

/// One uploaded document, as the list route selects it.
///
/// ⛔ THE SAME TYPE DECODES THE CREATE RESPONSE, WHICH SELECTS ONE FEWER FIELD.
/// `GET` selects `sourceUrl`; `POST` does not, so the create body carries six
/// keys where the list carries seven, and ``sourceUrl`` is ABSENT there rather
/// than null. That is the whole reason this one field is Optional while the others
/// are not, and it is why a list rebuilt by appending the echoed row would show a
/// document with no source until the next full read. Both shapes are gated:
/// `district-knowledge.json` and `district-knowledge-create.json`.
///
/// ⚠️ ABSENT AND NULL BOTH REACH nil HERE, AND THE FIXTURES CARRY ONE OF EACH.
/// Row 0 of the list is a pasted document whose `sourceUrl` column is null and
/// SENT as null (the route serialises the Prisma selection whole), so it needs an
/// exact `allowedExplicitNulls` path; the create body omits the key entirely,
/// which is the shape a nil Optional already round-trips.
///
/// ⚠️ EVERY OTHER FIELD IS NON-OPTIONAL BECAUSE THE COLUMN IS. `title` is a plain
/// `String`, and `sourceType`, `status` and `chunkCount` all carry database
/// defaults (`"text"`, `"ready"`, `0`), so neither route's `select` can produce a
/// null in any of them. A null there is contract drift and the strict gate is what
/// must see it.
///
/// ⚠️ ``status`` IS FREE TEXT ON THE WIRE. The ingest route writes `"ready"` today
/// and the column is a plain string, so an unrecognised status is DISPLAYED as
/// itself rather than switched on exhaustively. Same call as
/// ``SchedulingTenant/region``, and the opposite of the one
/// ``SchedulingTenantStatus`` makes, because nothing constrains this column
/// server-side.
///
/// ⚠️ ``chunkCount`` IS THE EMBEDDING COUNT, and it is what a Vertex bill is made
/// of. Worth showing: "this document became 400 chunks" is the only visible signal
/// that an upload was larger than intended.
///
/// ⚠️ ``createdAt`` IS AN ISO-8601 STRING, NOT AN INSTANT. This module owns no
/// date parsing, for the reason ``CallSummary`` and ``DeviceSession`` give: one
/// decoder strategy would have to be right for every timestamp on the surface and
/// they do not all agree.
public struct KnowledgeDocument: Codable, Sendable {
    public let id: String
    public let title: String
    /// `text`, `url` or `file`. Free text on the wire, and a database default
    /// rather than a nullable column.
    public let sourceType: String
    /// ⛔ Null on a pasted document and ABSENT in the create response. See the ⛔
    /// on the type.
    public let sourceUrl: String?
    /// ⚠️ Displayed, not switched on. See the ⚠️ on the type.
    public let status: String
    /// ⚠️ The embedding count, i.e. what the upload cost.
    public let chunkCount: Int
    public let createdAt: String
}

/// `GET /api/district/workspace/knowledge?workspaceId=`. The documents the agent
/// answers from, newest first.
///
/// ⛔ AN EMPTY ARRAY IS A LEGITIMATE ANSWER AND MUST NEVER RENDER AS A FAILURE.
/// It is a workspace that has uploaded nothing, which is the state every workspace
/// starts in. ``documents`` is non-Optional because `findMany` always emits the
/// array, so an absent key is contract drift, and the `success` flag is still
/// checked by hand at the repository because a required field rejects `{}` and
/// does not reject a well-formed `success: false`.
///
/// ⚠️ THIS READ ADMITS `viewer` AND THE WRITES DO NOT, which is the OPPOSITE split
/// from `workspace/config`, whose read excludes viewers too. Nothing here is a
/// staff phone number, so a read-only member may see the document list and the
/// mode; only `agency` and `client` may change either.
public struct KnowledgeListResponse: Codable, Sendable {
    public let success: Bool
    public let documents: [KnowledgeDocument]
}

/// `POST /api/district/workspace/knowledge`. The row a successful ingest made.
///
/// ⛔ THIS IS THE ONE CALL IN THIS CLIENT THAT SPENDS VERTEX EMBEDDING BUDGET,
/// AND THE CALLER SETS THE SIZE OF THE BILL. The route chunks the content and
/// embeds every chunk in ONE request, so a single tap is one embedding call or
/// four hundred. It is rate limited at 20/min per WORKSPACE (the spend lands on
/// the tenant, not the member) and that limiter is Redis-backed and FAIL-OPEN, so
/// a green response is not proof a cap held. ⛔ Nothing may retry it: a request
/// that timed out may well have embedded and persisted, and repeating it pays
/// twice for a duplicate document.
///
/// ⚠️ IT ECHOES THE ROW, UNLIKE EVERY WORKSPACE-SETTINGS SAVE ON THIS SURFACE,
/// and the echo is one field short of the list's. See the ⛔ on
/// ``KnowledgeDocument``.
///
/// ⚠️ ``document`` IS OPTIONAL FOR THE REASON ``WorkspaceConfigResponse/config``
/// IS: the route always emits it on the success path, so nil is contract drift
/// rather than a state, and the right handling is to report a failed create rather
/// than to hand a screen a document that was never made. The repository does
/// exactly that.
public struct KnowledgeCreateResponse: Codable, Sendable {
    public let success: Bool
    /// ⚠️ nil is DRIFT, not "created nothing". See the ⚠️ on the type.
    public let document: KnowledgeDocument?
}

/// `GET` and `PATCH /api/district/workspace/knowledge-mode`.
///
/// ⛔ THE ROUTE SPREADS THE STORED CONFIG INTO THE ENVELOPE
/// (`{success:true, ...config}`), SO `mode` IS A TOP-LEVEL KEY rather than a
/// nested object. A DTO shaped `{success, config:{mode}}` would decode to no mode
/// at all and read as `internal` for a workspace that chose `linked`, i.e. it
/// would report the safe answer while the questions were leaving the region.
///
/// ⚠️ THE WRITE ANSWERS THIS SAME SHAPE, which makes `knowledge-mode` the one
/// write on the workspace-settings surface that needs no re-read: the route
/// re-reads through its own total sanitiser before answering, so what comes back
/// is what a later read will see. ⛔ Adopt the echo, never the value that was
/// asked for.
public struct KnowledgeModeResponse: Codable, Sendable {
    public let success: Bool
    /// ⛔ A `String`, NOT ``KnowledgeMode``, AND THE ASYMMETRY WITH THE WRITE IS
    /// DELIBERATE. The write is closed because the route validates with
    /// `z.enum(KB_MODES)`; the read is open because a THIRD mode added
    /// server-side must arrive as a value to display rather than as a decode
    /// failure on a build that has not learned it yet. Failing a settings read
    /// over a new mode is the wrong direction, and a malformed STORED value is
    /// repaired by the server's own total sanitiser before it is ever sent.
    /// Branch on ``knownMode``.
    public let mode: String

    /// ``mode`` parsed into the vocabulary this build knows, or nil for anything
    /// outside it.
    ///
    /// ⚠️ nil MEANS "A MODE THIS BUILD DOES NOT KNOW", WHICH IS NOT AN ERROR. A
    /// selector should show ``mode`` as itself and leave it alone rather than
    /// silently rewriting it to a value the operator did not choose.
    ///
    /// ⚠️ COMPUTED, SO IT IS NOT ENCODED. Synthesised `Codable` covers stored
    /// properties only, which is what keeps this from adding a key the server
    /// never sent and failing the strict gate's key-set walk. Same reason
    /// ``SchedulingEnableResponse/tenantStatus`` is computed.
    public var knownMode: KnowledgeMode? {
        KnowledgeMode(rawValue: mode)
    }
}
