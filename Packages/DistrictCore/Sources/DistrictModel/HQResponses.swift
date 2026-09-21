import Foundation

/// A change District HQ has PROPOSED and not applied.
///
/// ⛔ THIS IS THE HANDLE THE CONFIRM CALL TAKES, AND THAT IS THE WHOLE DESIGN
/// RATHER THAN A CONVENIENCE. ``HQRepository/confirm(workspaceId:pendingWrite:)``
/// accepts one of these and nothing else: no tool name, no argument object, no id
/// string. A signature that let a caller assemble its own pair would make
/// substituting one possible, and the substitution would be INVISIBLE, because
/// ``summary`` is the only description of the change the operator ever read. The
/// two-step is only worth having if the thing confirmed is provably the thing
/// proposed, and a value that can only come out of a prompt response is how that
/// is expressed in the type system instead of in a comment.
///
/// ⛔ ``args`` IS OPAQUE ``WireJSON`` AND MUST STAY THAT WAY. These are the
/// arguments the MODEL chose, so the shape depends on which write tool it picked:
/// a persona update carries `greeting`/`personality`/`voice`, a routing
/// replacement carries a rules array, a campaign carries a goal. Typing them would
/// mean a struct per tool and a decode failure on an installed build the day a
/// tool gains a field. Nothing here reads them; the client shows ``summary`` and
/// echoes ``args`` back verbatim.
///
/// ⛔ AND VERBATIM MEANS VERBATIM. Re-deriving, re-ordering or "cleaning up" the
/// arguments on the way to the confirm would apply a different change from the one
/// described. ``WireJSON`` round-trips a null inside a blob as a null for exactly
/// this reason.
///
/// ⚠️ ONLY THE FIRST PROPOSAL OF A TURN IS SURFACED by the server, even if the
/// model emitted several. So a confirmed write is one change, never a batch.
public struct HqPendingWrite: Codable, Sendable {
    /// The tool name, echoed back on confirm so the applied action can be checked
    /// against it.
    public let tool: String
    /// ⛔ Opaque, and echoed unchanged. See the ⛔ on the type.
    public let args: WireJSON
    /// The operator-facing sentence describing exactly what would happen.
    ///
    /// ⛔ THE ONLY THING A CONFIRM PROMPT MAY BE BUILT FROM. It is composed
    /// server-side from the real arguments, so a screen that rendered ``tool``
    /// instead would ask an operator to approve `update_call_routing` rather than
    /// "REPLACE the workspace call-routing rules".
    public let summary: String
}

/// `POST /api/district/hq` without a `confirm` key. What HQ says back, and the
/// change it wants permission for.
///
/// ⛔ TWO STRUCTURALLY DIFFERENT BODIES ON ONE BRANCH, AND THE DIFFERENCE IS TWO
/// ABSENT KEYS. A plain answer is `{success, answer}` and nothing else;
/// a proposal adds `needsConfirmation` and `pendingWrite`. Both are ABSENT rather
/// than null on the plain branch, which is why both are Optional here and why
/// `district-hq-answer.json` exists beside `district-hq-pending-write.json`: a
/// single fixture would make ``pendingWrite`` look either mandatory or impossible,
/// and getting it wrong in the second direction means a phone that silently drops
/// the confirmation prompt for a deletion.
///
/// ⛔ `needsConfirmation` TRUE MEANS NOTHING HAS BEEN WRITTEN YET. The model can
/// only PROPOSE; the server gates every write behind an explicit second call.
/// Rendering the answer text without the confirm affordance would leave an
/// operator believing a change they asked for had been applied, and the prose
/// usually says it was proposed, which makes the omission worse rather than
/// self-correcting.
///
/// ⚠️ ``answer`` IS ALWAYS POPULATED, even when the model produced nothing usable:
/// the route substitutes its own sentence rather than returning an empty string.
/// So an empty answer is contract drift, not a quiet model, and the field is
/// non-Optional.
///
/// ⚠️ STATELESS AND NON-STREAMING. The server holds no conversation and keeps only
/// the last six turns of whatever history the client replays, so the client is the
/// single owner of the transcript across process death.
public struct HqPromptResponse: Codable, Sendable {
    public let success: Bool
    /// ⚠️ Never empty. See the ⚠️ on the type.
    public let answer: String
    /// ⛔ ABSENT on a plain answer, not false. True means a change is waiting for
    /// permission and nothing has happened yet.
    public let needsConfirmation: Bool?
    /// ⛔ The proposal itself, and the only thing that can be confirmed.
    public let pendingWrite: HqPendingWrite?
}

/// `POST /api/district/hq` WITH a `confirm` key. What actually happened.
///
/// ⛔ ``success`` AND ``executed`` ARE DIFFERENT QUESTIONS AND CONFLATING THEM IS
/// THE FAILURE THIS PAIR EXISTS TO PREVENT. `success` means the request was
/// handled; `executed` means the write took effect, and the route derives it from
/// the tool's own `ok` field. A viewer's confirm, or a tool that refused
/// internally, answers `success: true, executed: false`. Reporting that as done is
/// a claim that somebody's persona, routing rules or contact list changed when it
/// did not.
///
/// ⛔ ``tool`` AND ``args`` ARE ECHOED SO THE CLIENT CAN PROVE THE APPLIED ACTION
/// IS THE APPROVED ONE, and ``HQRepository`` checks the tool rather than trusting
/// it. "We applied something, but not what you approved" has no honest rendering,
/// so it is reported as drift.
///
/// ⚠️ ``result`` IS THE TOOL'S OWN RETURN VALUE AND IS NOT NECESSARILY AN OBJECT.
/// Nothing in the route constrains it, so it is carried as opaque ``WireJSON`` for
/// diagnostics only. ⛔ Never decide "applied" by inspecting it; that is
/// ``executed``'s job, and the server has already done the inspecting.
public struct HqConfirmResponse: Codable, Sendable {
    public let success: Bool
    /// ⛔ The write took effect. Not the same as ``success``.
    public let executed: Bool
    /// ⛔ Compared against the approved tool by the repository.
    public let tool: String
    public let args: WireJSON
    /// ⚠️ Diagnostics only, and any JSON shape. See the ⚠️ on the type.
    public let result: WireJSON?
}
