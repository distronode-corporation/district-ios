import DistrictModel
import DistrictNetwork
import Foundation

/// The persona: its vocabularies, its eleven editable fields, its preview session,
/// and the routing rules that override it per caller.
///
/// ⛔ SPLIT OUT OF `WorkspaceRepository.swift` BECAUSE THAT FILE IS AT SwiftLint's
/// 500-LINE `file_length` CEILING, exactly as `ImplementedFixtures+MessageThread.swift` and
/// `EndpointClassification+SchedulingAdmin.swift` were. Nothing here is a separate
/// concern from the settings surface next door, and the obligation stated there
/// — a save is only ever built on a successful ``WorkspaceRepository/config(workspaceId:)``
/// — covers every method in this file.
public extension WorkspaceRepository {
    // MARK: - The vocabularies

    /// The lists this workspace's persona form may offer.
    ///
    /// ⛔ A FAILURE HERE MUST LEAVE THE FORM READ-ONLY AND MUST NEVER FALL BACK TO A
    /// BUILT-IN CATALOGUE. `PATCH workspace/persona` COERCES rather than rejects, so
    /// a hardcoded Swift list does not fail when it drifts — every value it offers
    /// is still accepted, stored, and then silently substituted by the agent, with a
    /// 200 and nothing anywhere reporting it. That is the exact failure this route
    /// exists to retire, and a fallback list reintroduces it.
    ///
    /// ⚠️ THE ANSWER IS PER WORKSPACE, NOT PER PROCESS. Each engine's label states
    /// where its audio is processed — a public residency claim keyed on the
    /// WORKSPACE's region — so a cache shared across workspaces would tell an EU
    /// tenant their audio stays in the EU because a US workspace was read first.
    ///
    /// ⚠️ Rate limited at 60/min per workspace. Generous enough to refetch on an
    /// engine change, not enough to sit behind a keystroke.
    func personaOptions(workspaceId: String) async -> Result<PersonaOptionsResponse, ApiError> {
        let outcome = await client.send(
            DistrictEndpoints.personaOptions(workspaceId: workspaceId),
            as: PersonaOptionsResponse.self
        )
        return outcome
            .flatMap { ResponseEnvelope.affirm("PersonaOptionsResponse", $0.success, $0) }
    }

    // MARK: - The save

    /// Save persona fields.
    ///
    /// ⛔ SEND ONLY WHAT THE OPERATOR CHANGED. The route merges per field
    /// (`x !== undefined ? x : existing`), so an omitted key is PRESERVED, and a
    /// caller that posted its whole form state would overwrite the engine choice,
    /// the avatar settings and the tuning parameters with whatever it happened to
    /// hold. Passing nil is what drops a key from the wire, through
    /// ``JSONValue/object(_:)``.
    ///
    /// ⛔ AN EMPTY STRING IS A DELIBERATE CLEAR AND IS SENT AS ONE. nil means "leave
    /// it alone". Anything that helpfully mapped blank to nil would make a cleared
    /// greeting silently un-clearable.
    ///
    /// ⛔ `responseLength` WITHOUT `modelId` IS SILENTLY DISCARDED. The route stores
    /// the level under `aiPersona.responseLength[modelId]` and refuses to guess at
    /// the stored engine, so with no accepted engine id in the SAME request there is
    /// no key to write under — it writes nothing and answers 200. Callers send the
    /// pair or neither; ``PersonaModel`` is where that is enforced.
    ///
    /// ⛔ THE SEVEN VOCABULARY FIELDS MUST COME FROM ``personaOptions(workspaceId:)``.
    /// An unrecognised `modelId` is rewritten to `deepgram-pipeline`; an
    /// unrecognised `voice` is stored verbatim and then replaced by the agent's own
    /// fallback at synthesis time. Both answer 200, so a value typed by hand does
    /// not fail — it produces a persona nobody chose.
    ///
    /// ⚠️ `dgiEnabled` IS AN ENTITLEMENT AS WELL AS A CONSENT FLAG. Turning it ON for
    /// a workspace that is not on Voice Studio answers **403 `dgi_requires_studio`**,
    /// and only the transition is gated: re-sending `true` where it is already true
    /// is a no-op, so a greeting save that carries the flag along is never refused
    /// for it. ⛔ nil is not `false`; it means the workspace has never answered,
    /// which renders as off but must not be SENT as false unless the operator
    /// actually toggled it.
    ///
    /// ⚠️ Rate limited at 30/min per WORKSPACE, sized for an operator tuning a form.
    /// Every field save is its own PATCH.
    func savePersona(
        workspaceId: String,
        name: String? = nil,
        greeting: String? = nil,
        personality: String? = nil,
        dgiEnabled: Bool? = nil,
        voice: String? = nil,
        language: String? = nil,
        modelId: String? = nil,
        responseLength: String? = nil,
        temperature: Double? = nil,
        voiceStyle: String? = nil,
        preemptiveTts: Bool? = nil
    ) async -> Result<Void, ApiError> {
        let descriptor = DistrictEndpoints.savePersona(
            workspaceId: workspaceId,
            name: name,
            greeting: greeting,
            personality: personality,
            dgiEnabled: dgiEnabled,
            voice: voice,
            language: language,
            modelId: modelId,
            responseLength: responseLength,
            temperature: temperature,
            voiceStyle: voiceStyle,
            preemptiveTts: preemptiveTts
        )
        let outcome = await client.send(descriptor, as: SuccessResponse.self)
        return outcome
            .flatMap { ResponseEnvelope.affirm("PersonaPatchResponse", $0.success, $0) }
            .map { _ in }
    }

    // MARK: - The preview

    /// Mint a credential for one persona audition.
    ///
    /// ⛔ BILLABLE, NOT IDEMPOTENT, AND NEVER RETRIED. Every token invites the voice
    /// agent into a room and starts burning STT/LLM/TTS minutes; the ceiling is
    /// 10/min per WORKSPACE and it is the only thing bounding a loop, because the
    /// spend lands downstream in the agent rather than in the handler. A caller
    /// treats a failure as final and offers a button, never a retry.
    ///
    /// ⛔ IT CARRIES THE UNSAVED FORM ON PURPOSE. The agent reads this blob out of
    /// the token metadata for any `preview_*` room, so the audition is of what is on
    /// screen. Sending the SAVED persona instead would answer a different question
    /// convincingly.
    ///
    /// ⚠️ NO CONFIG READ IS REQUIRED FIRST, UNLIKE EVERY SAVE ON THIS SURFACE. This
    /// route persists nothing, so there is no stored value a blank form could
    /// destroy — the load-then-edit rule exists for wholesale replacement and does
    /// not apply. What IS required is the options read, because a `modelId` the
    /// registry does not know is coerced to `deepgram-pipeline` and the preview then
    /// runs on an engine nobody chose.
    func previewToken(
        workspaceId: String,
        form: PersonaPreviewForm
    ) async -> Result<PersonaPreviewTokenResponse, ApiError> {
        let outcome = await client.send(
            DistrictEndpoints.previewToken(workspaceId: workspaceId, form: form),
            as: PersonaPreviewTokenResponse.self
        )
        return outcome
            .flatMap { ResponseEnvelope.affirm("PersonaPreviewTokenResponse", $0.success, $0) }
    }

    // MARK: - The routing rules

    /// Replace the dynamic-persona rules from an editor's drafts.
    ///
    /// ⛔ WHOLESALE, LIKE THE ARRAY IT REPLACES, AND EVERY ROW GOES BACK — including
    /// the ones this build cannot read. A rule shaped `{id, match, action, target}`
    /// (two of the three rows in the committed fixture) has none of the six keys the
    /// editor owns; ``RoutingRuleDraft/carriedUnchanged()`` sends it byte-identically
    /// rather than stamping six invented keys onto it or dropping it. Dropping it
    /// would be a deletion answered 200, of a rule the agent is evaluating today.
    ///
    /// ⛔ AN EMPTY ARRAY IS ACCEPTED AND DELETES EVERY RULE. The route only refuses
    /// an OMITTED array (`Array.isArray` is checked, 400 "Invalid payload"), which
    /// the non-optional parameter makes unreachable. A screen confirms before
    /// sending an empty one; this layer does not second-guess a request it was
    /// given.
    ///
    /// ⚠️ A **400 HERE IS OFTEN A REAL, SPECIFIC REFUSAL** rather than a client
    /// fault: a workspace that restricts voices or models rejects a rule naming one
    /// outside its allow-list, BY NAME. That sentence is worth showing verbatim —
    /// this client cannot see either list and deliberately does not pre-validate
    /// against a guess.
    ///
    /// ⚠️ AN UNRECOGNISED ROW THAT WAS NEVER EDITED IS CARRIED; AN ADDED ROW THAT
    /// WAS NEVER FILLED IN IS DROPPED. See ``RoutingRuleDraft/isBlank``.
    func saveRoutingRules(
        workspaceId: String,
        rules: [RoutingRuleDraft]
    ) async -> Result<Void, ApiError> {
        let rows = rules.filter { !$0.isBlank }.map { draft -> JSONValue in
            draft.isRecognised ? draft.rendered() : (draft.carriedUnchanged() ?? draft.rendered())
        }
        return await saveRoutingRules(workspaceId: workspaceId, routingRules: rows)
    }
}
