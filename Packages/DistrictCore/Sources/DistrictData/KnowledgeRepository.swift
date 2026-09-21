import DistrictModel
import DistrictNetwork
import Foundation

/// The workspace knowledge base: what the agent may answer FROM, and where the
/// answer is composed.
///
/// ⛔ A REPOSITORY OF ITS OWN RATHER THAN MORE ``WorkspaceRepository``, AND THE
/// REASON IS THE ROLE CONTRACT RATHER THAN TIDINESS. Every workspace-settings call
/// excludes `viewer` server-side INCLUDING the config read, because that payload
/// carries staff transfer numbers and the operator's own prompt. Here the reads
/// ADMIT `viewer` and only the writes exclude them. Folding the two together would
/// put one "who may call this" rule on two surfaces that genuinely differ, and a UI
/// gate derived from the wrong one either hides a list a viewer is entitled to see
/// or walks them into a 403.
///
/// ⛔ NOTHING HERE RE-READS AFTER A WRITE, WHICH IS THE OPPOSITE OF THE SETTINGS
/// WRITES ON ``WorkspaceRepository`` AND IS CORRECT FOR THIS SURFACE. Those re-read
/// because their routes answer a bare `{success:true}` and they are rebuilding the
/// baseline a wholesale-replace save is constructed from. Neither applies here:
/// ``setMode(workspaceId:mode:)`` gets the stored config echoed back, so there IS a
/// body to adopt, and ``addDocument`` is a per-row create rather than an array
/// replacement, so nothing a later save is built on. A caller re-reads the LIST
/// after a create because the list is what is on screen, not because a save needs
/// it.
///
/// ⚠️ NO CACHE. The document list is opened to check what the agent knows, and the
/// mode is a data-residency setting; a process-scoped copy of either would let a
/// phone show a state that was changed on the web in between.
///
/// ⚠️ THE DELETE IS DELIBERATELY ABSENT FROM THIS TYPE FOR NOW.
/// `district-knowledge-delete.json` is gated against ``SuccessResponse`` and
/// ``DistrictEndpoints/deleteDocument(workspaceId:documentId:)`` exists, so
/// wrapping it is one method and one line of ``UntypedEndpoints``. It is left for
/// the change that adds the screen, because
/// the route has a property a caller has to be told about rather than discover:
/// it answers `{success:true}` even when nothing matched (a `deleteMany` scoped to
/// `{id, workspaceId}` whose count is never read), so another tenant's id and a
/// real delete are the same response and the list must be re-read rather than the
/// row removed locally.
public struct KnowledgeRepository: Sendable {
    private let client: ApiClient

    public init(client: ApiClient) {
        self.client = client
    }

    /// The document list, newest first.
    ///
    /// ⛔ AN EMPTY LIST IS A REAL ANSWER AND MUST NOT RENDER AS A FAILURE. It is a
    /// workspace that has uploaded nothing, which is where every workspace starts.
    ///
    /// ⚠️ ENVELOPE-CHECKED EVEN THOUGH THE DTO'S FIELDS ARE REQUIRED. A required
    /// field rejects `{}`; it does not reject a well-formed body that says
    /// `success: false`, which is exactly what this route's catch branch produces
    /// once the headers are written. Without the check, "we could not look" would
    /// render as "you have uploaded nothing" and an operator would upload it again.
    public func documents(workspaceId: String) async -> Result<[KnowledgeDocument], ApiError> {
        let outcome = await client.send(
            DistrictEndpoints.knowledgeDocuments(workspaceId: workspaceId),
            as: KnowledgeListResponse.self
        )
        return outcome
            .flatMap { ResponseEnvelope.affirm("KnowledgeListResponse", $0.success, $0) }
            .map(\.documents)
    }

    /// Ingest one document: chunk, embed, persist.
    ///
    /// ⛔ ONE CALL IS ONE BILL AND THE CALLER SIZES IT. The route chunks `content`
    /// and embeds every chunk in a single request, so one tap is one embedding run
    /// or four hundred. ⛔ NOTHING MAY RETRY THIS, here or above: a request that
    /// timed out may well have embedded and persisted, and repeating it pays twice
    /// for a duplicate document. The 20/min-per-workspace limiter is Redis-backed
    /// and FAIL-OPEN, so it is not a backstop for that.
    ///
    /// ⛔ A `success: true` WITH NO `document` IS REPORTED AS DRIFT RATHER THAN AS
    /// AN EMPTY SUCCESS. The route always echoes the row it created, so nil is a
    /// contract change and not a state; answering `.success` with nothing in hand
    /// would leave a caller to invent a row that was never made.
    ///
    /// ⚠️ THE ECHOED ROW IS ONE FIELD SHORT OF A LIST ROW. `sourceUrl` is not in
    /// the create route's `select`, so a list rebuilt by appending this document
    /// would show it with no source until the next full read. Prefer re-reading
    /// ``documents(workspaceId:)``.
    ///
    /// ⚠️ A `content` THAT CHUNKS TO NOTHING IS A **400 "Document has no usable
    /// text"**, not a zero-chunk document. Worth surfacing verbatim: "it saved but
    /// is empty" would be the wrong sentence.
    ///
    /// ⚠️ `title` IS TRUNCATED TO 200 CHARACTERS SERVER-SIDE and `sourceType`
    /// defaults to `"text"` when absent. Both are sent as given so the stored row
    /// matches what the form showed.
    public func addDocument(
        workspaceId: String,
        title: String,
        content: String,
        sourceType: String? = nil,
        sourceUrl: String? = nil
    ) async -> Result<KnowledgeDocument, ApiError> {
        let descriptor = DistrictEndpoints.createDocument(
            workspaceId: workspaceId,
            title: title,
            content: content,
            sourceType: sourceType,
            sourceUrl: sourceUrl
        )
        let outcome = await client.send(descriptor, as: KnowledgeCreateResponse.self)
        let affirmed = outcome.flatMap { ResponseEnvelope.affirm("KnowledgeCreateResponse", $0.success, $0) }
        switch affirmed {
        case let .success(response):
            guard let document = response.document else {
                return .failure(.decoding("KnowledgeCreateResponse affirmed success with no document"))
            }
            return .success(document)
        case let .failure(error):
            return .failure(error)
        }
    }

    /// Which knowledge source answers this workspace's questions.
    ///
    /// ⚠️ `mode` IS A TOP-LEVEL KEY OF THE ENVELOPE, not a nested config object,
    /// and the string is returned RATHER THAN a ``KnowledgeMode``: a third mode
    /// added server-side must reach the screen as a value to display instead of
    /// failing a settings read on a build that has not learned it. Call
    /// ``KnowledgeModeResponse/knownMode`` to branch.
    ///
    /// ⚠️ READABLE BY `viewer`. It discloses nothing beyond the document list they
    /// can already see.
    public func mode(workspaceId: String) async -> Result<String, ApiError> {
        let outcome = await client.send(
            DistrictEndpoints.knowledgeMode(workspaceId: workspaceId),
            as: KnowledgeModeResponse.self
        )
        return outcome
            .flatMap { ResponseEnvelope.affirm("KnowledgeModeResponse", $0.success, $0) }
            .map(\.mode)
    }

    /// Choose the knowledge source.
    ///
    /// ⛔ SWITCHING TO `linked` STARTS SENDING THIS WORKSPACE'S QUESTIONS TO
    /// ATLASSIAN. It is a data-residency change rather than a display preference,
    /// which is why the write excludes `viewer` while the read admits one, and why
    /// a UI must confirm it rather than treating it as a toggle.
    ///
    /// ⛔ THE SERVER'S ECHO IS ADOPTED, NEVER THE VALUE THAT WAS ASKED FOR. The
    /// route re-reads through its own total sanitiser before answering, so what
    /// comes back is what a later read will see; returning the requested value
    /// would report a mode nobody stored if the sanitiser ever disagreed. This is
    /// the whole reason this write needs no separate re-read.
    ///
    /// ⚠️ THE PARAMETER IS ``KnowledgeMode`` AND NOT A `String`, WHICH IS WHAT
    /// MAKES THE ROUTE'S 400 UNREACHABLE. It validates with `z.enum(KB_MODES)`, so
    /// an unrecognised mode is refused rather than stored.
    public func setMode(workspaceId: String, mode: KnowledgeMode) async -> Result<String, ApiError> {
        let descriptor = DistrictEndpoints.saveKnowledgeMode(
            workspaceId: workspaceId,
            mode: mode.rawValue
        )
        let outcome = await client.send(descriptor, as: KnowledgeModeResponse.self)
        return outcome
            .flatMap { ResponseEnvelope.affirm("KnowledgeModeResponse", $0.success, $0) }
            .map(\.mode)
    }
}
