import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import Observation

/// The persona form's state machine. Ported from Android's `PersonaFormViewModel`.
///
/// ⛔ A FAILED LOAD PRODUCES NO EDITABLE STATE, AND THAT IS THIS CLASS'S ONE
/// NON-NEGOTIABLE PROPERTY. `PATCH workspace/persona` merges per field, so this
/// particular form is the gentler of the two savers on this surface — but the rule
/// is enforced here anyway, because the moment it is relaxed for the harmless case
/// somebody copies the shape onto the capability list, where the route REPLACES the
/// array wholesale and an empty form is a deletion. There is exactly one way to
/// reach ``SettingsConfigState/ready(_:)``, and it is a 200 from the config read.
///
/// ⛔ THE REQUEST CARRIES ONLY DIRTY FIELDS. The server preserves what a request
/// omits (`x !== undefined ? x : existing`), so this is how a phone saves a greeting
/// without overwriting the engine choice, the response-length map and the avatar
/// configuration with defaults it invented. ``JSONValue/object(_:)`` drops a nil
/// pair, so "not dirty" and "not on the wire" are the same thing by construction.
///
/// ⛔ AND THERE ARE TWO LOADS, NOT ONE, WITH DIFFERENT CONSEQUENCES FOR FAILING. The
/// configuration is the baseline every save is built on, so without it there is no
/// form at all. The VOCABULARIES (`persona/options`) decide only what the language and
/// answer-length controls may offer, so without them the three free-text fields stay
/// editable and those two fall back to showing the stored values and nothing else.
/// ⛔ THEY MUST NEVER FALL BACK TO A BUILT-IN CATALOGUE: every value a stale Swift list
/// offered would still be accepted, stored and then silently substituted by the agent,
/// with a 200 and nothing reporting it, which is the exact failure the options route
/// exists to retire.
///
/// ⚠️ AN EMPTY STRING IS SENT FOR THE THREE TEXT FIELDS AND NEVER FOR THE OTHERS.
/// Clearing a greeting is a real edit and the server stores `""` verbatim; clearing a
/// LANGUAGE would store an empty one and make the agent fall back to one nobody chose.
/// See the ⛔ on ``PersonaIdentityValues``.
///
/// ⛔ THE ENGINE, VOICE AND TUNING ARE THE VOICE STUDIO'S (``VoiceStudioModel``), a
/// sibling screen and never a child, so a stale persona form can never resend an engine id
/// the Studio changed. This form sends the stored engine id only beside an answer length,
/// where the route needs it as a key.
///
/// ⚠️ THE ENRICHMENT CONSENT FLAG ALSO RIDES THIS ROUTE AND IS NOT EDITED HERE. It
/// lives on the capabilities screen, matching the web console, where the enrichment
/// form sits inside the capabilities tab and posts to `workspace/persona`.
@MainActor
@Observable
final class PersonaModel {
    /// The three fields with no server-side vocabulary behind them.
    ///
    /// ⚠️ THREE, AND THE SPLIT IS ABOUT WHERE THE VALUE COMES FROM RATHER THAN
    /// ABOUT WHAT MAY BE EDITED. These are free text the route stores verbatim; the
    /// language and answer length are drawn from ``PersonaIdentityDraft``, which cannot
    /// exist without the server's own catalogue.
    enum Field: String, CaseIterable {
        case name
        case greeting
        case personality
    }

    private(set) var load: SettingsConfigState = .loading
    private(set) var save: SettingsSaveState = .idle

    /// The vocabulary-backed fields, or nil when the catalogue did not load.
    ///
    /// ⛔ NIL IS READ-ONLY, NOT "USE DEFAULTS". See the ⛔ on this type.
    private(set) var draft: PersonaIdentityDraft?

    /// ⚠️ WHY THE ENGINE CONTROLS ARE NOT OFFERED, SHOWN RATHER THAN SWALLOWED. A
    /// panel that silently turned read-only would read as a product decision.
    private(set) var optionsFailure: FailureText?

    /// ⚠️ A VIEWER NEVER REACHES THIS SCREEN — `workspace/config` excludes them, which
    /// is why ``RouteGate`` hides the row — but a control that was not drawn is not a
    /// boundary, so every write and the billable preview are gated here too.
    let canWrite: Bool

    /// ⚠️ EVERY FIELD THE OPERATOR HAS TOUCHED, including ones typed back to their
    /// original value. Dirtiness is decided against the loaded baseline, not against
    /// this.
    private var edits: [Field: String] = [:]

    private let gateway: SettingsConfigGateway

    /// ⚠️ THE REPOSITORY RATHER THAN THE CONTAINER, for the reason ``RoutingModel``'s
    /// own initialiser records: a test that had to build an ``AppContainer`` would touch
    /// the device keychain to ask which fields a save names.
    init(workspaces: WorkspaceRepository, workspaceId: String, role: WorkspaceRole?) {
        gateway = SettingsConfigGateway(workspaces: workspaces, workspaceId: workspaceId)
        canWrite = WorkspaceRole.allowsMutation(role)
    }

    @MainActor
    convenience init(container: AppContainer, workspaceId: String, role: WorkspaceRole?) {
        self.init(workspaces: container.workspaces, workspaceId: workspaceId, role: role)
    }

    /// The hydrated persona, or nil when nothing has loaded. ⛔ Nil is NOT an empty
    /// persona.
    var persona: AiPersona? {
        load.config?.aiPersona
    }

    /// What the server currently holds for a field.
    ///
    /// ⚠️ NIL BECOMES `""`, WHICH MIRRORS THE WEB EXACTLY (`initialData?.name || ""`).
    /// It also makes "never set" and "set to empty" indistinguishable in the form,
    /// which is correct: both render as an empty box and neither is dirty until
    /// someone types.
    func stored(_ field: Field) -> String {
        switch field {
        case .name: persona?.name ?? ""
        case .greeting: persona?.greeting ?? ""
        case .personality: persona?.personality ?? ""
        }
    }

    /// What to show in the box: the draft if there is one, otherwise what the server
    /// holds.
    func value(_ field: Field) -> String {
        edits[field] ?? stored(field)
    }

    /// Record a keystroke.
    ///
    /// ⚠️ IGNORED UNLESS THE CONFIG LOADED. The screen offers no field in that
    /// state, so this is belt and braces — but a draft accumulated against no
    /// baseline is exactly the thing that would later be saved as an overwrite.
    func edit(_ field: Field, to value: String) {
        guard canWrite, load.config != nil else { return }
        edits[field] = value
        // A new keystroke retires the previous save's banner; leaving "Saved" up
        // while the form is dirty again would be a claim about state that no longer
        // exists.
        save = .idle
    }

    /// Move the language or the answer length.
    ///
    /// ⛔ BOTH GO THROUGH ``PersonaIdentityDraft``, because the language moves the voice
    /// with it for the language-keyed engine. A binding straight to a stored property
    /// would apply the one and skip the other.
    func editIdentity(_ change: (inout PersonaIdentityDraft) -> Void) {
        guard canWrite, load.config != nil, draft != nil else { return }
        change(&draft!)
        save = .idle
    }

    /// ⛔ COMPARED AGAINST THE LOADED BASELINE, NOT MERELY "WAS TOUCHED". A field
    /// typed and typed back is not dirty, and naming it in the request anyway would
    /// break the whole contract of this form, which is that it names only what
    /// someone changed.
    var dirtyFields: Set<Field> {
        Set(Field.allCases.filter { edits[$0] != nil && edits[$0] != stored($0) })
    }

    /// ⛔ FALSE UNLESS THE CONFIG LOADED. A save is only ever built on a successful
    /// read.
    var canSave: Bool {
        guard canWrite, load.config != nil, !save.isSaving else { return false }
        return !dirtyFields.isEmpty || draft?.isDirty == true
    }

    /// The form as it stands, for one preview session, or nil when there is nothing
    /// to audition with.
    ///
    /// ⛔ NIL WITHOUT THE CATALOGUE, DELIBERATELY. The preview route coerces an
    /// unrecognised `modelId` to `deepgram-pipeline` exactly as the save route does,
    /// so auditioning a form whose engine this build could not verify would burn a
    /// billed session on an engine nobody chose.
    var previewForm: PersonaPreviewForm? {
        guard canWrite, load.config != nil, let draft else { return nil }
        return draft.previewForm(
            name: value(.name),
            greeting: value(.greeting),
            personality: value(.personality)
        )
    }

    /// Read the configuration this form hydrates from, and the lists it may offer.
    ///
    /// ⛔ DISCARDS NOTHING THE OPERATOR TYPED ON A FAILURE AND EVERYTHING ON A
    /// SUCCESS. A failed re-read leaves the draft alone (it is still theirs); a
    /// successful one adopts the server's values as the new baseline, which is what
    /// makes a saved field stop being dirty.
    ///
    /// ⚠️ SEQUENTIAL RATHER THAN CONCURRENT. Two reads on one screen open is not a
    /// latency problem worth an `async let` over two non-`Sendable` results, and the
    /// options read is skipped entirely when there is no configuration to edit.
    func loadConfig() async {
        load = .loading
        let state = await gateway.load()
        load = state
        guard state.config != nil else {
            draft = nil
            return
        }
        edits = [:]
        save = .idle
        await loadOptions()
    }

    /// Re-read the vocabularies alone.
    ///
    /// ⚠️ ITS OWN ENTRY POINT so the read-only panel can offer a retry that does not
    /// discard what the operator has typed into the three text fields. The GET is
    /// idempotent and rate limited at 60/min per workspace, so replaying it is honest
    /// and cheap.
    func loadOptions() async {
        guard let config = load.config else { return }
        switch await gateway.workspaces.personaOptions(workspaceId: gateway.workspaceId) {
        case let .success(options):
            optionsFailure = nil
            draft = PersonaIdentityDraft(persona: config.aiPersona, options: options)
        case let .failure(error):
            // ⛔ THE PREVIOUS DRAFT IS DROPPED RATHER THAN KEPT. It was built from a
            // catalogue this client can no longer vouch for, and the whole reason the
            // catalogue is read per workspace is that its engine labels are a public
            // claim about where audio is processed.
            draft = nil
            optionsFailure = FailureText.from(error)
        }
    }

    /// Send the dirty fields.
    ///
    /// ⛔ NOTHING IS SENT WHEN NOTHING IS DIRTY, and the guard is not an
    /// optimisation. A request carrying only a `workspaceId` still costs a
    /// rate-limit slot on a 30/min per-workspace budget and still stamps
    /// `updatedAt`, i.e. it would record an edit that did not happen.
    ///
    /// ⚠️ THE SECOND TAP IS DROPPED, NOT QUEUED. A save is followed by a re-read, and
    /// a queued second one would race that read and could write a draft the operator
    /// has already seen replaced.
    func saveChanges() async {
        guard canSave else { return }
        let dirty = dirtyFields
        let identity = draft?.write ?? PersonaIdentityWrite()
        save = .saving
        // ⛔ THE TERNARY IS THE MECHANISM, NOT A CONVENIENCE. nil drops the key from
        // the body and the server then PRESERVES the stored value; `""` reaches the
        // wire and CLEARS it. Swapping the two is the difference between clearing a
        // greeting and silently keeping it.
        let write = await gateway.workspaces.savePersona(
            workspaceId: gateway.workspaceId,
            name: dirty.contains(.name) ? value(.name) : nil,
            greeting: dirty.contains(.greeting) ? value(.greeting) : nil,
            personality: dirty.contains(.personality) ? value(.personality) : nil,
            // ⛔ NEVER SENT FROM THIS SCREEN. The consent flag is edited on the
            // capabilities screen, and sending `false` for a form that did not touch
            // it would be an opt-out nobody chose.
            dgiEnabled: nil,
            // ⛔ THE ENGINE ID ONLY AS THE ANSWER LENGTH'S KEY, AND NOTHING THE STUDIO OWNS.
            voice: identity.voice,
            language: identity.language,
            modelId: identity.modelId,
            responseLength: identity.responseLength
        )
        await apply(gateway.commit(write))
    }

    /// ⚠️ Lets the screen retire a banner without a re-read.
    func dismissNotice() {
        guard !save.isSaving else { return }
        save = .idle
    }

    /// ⛔ THE THREE OUTCOMES ARE THREE OUTCOMES. ``SettingsSaveOutcome/savedButStale(_:)``
    /// means the write LANDED and only the read back failed, so the draft is cleared
    /// (it is now what the server holds) but the screen is told its view is stale.
    /// Reporting it as a failure would invite a second save from state the client can
    /// no longer vouch for.
    private func apply(_ outcome: SettingsSaveOutcome) {
        switch outcome {
        case let .saved(config):
            load = .ready(config)
            edits = [:]
            // ⛔ RE-HYDRATED FROM THE SERVER'S ANSWER RATHER THAN LEFT AS THE DRAFT,
            // the same rule ``DirectoryModel`` follows: the NEXT save's dirty set is
            // computed against this baseline, so it has to be the stored one.
            rehydrate(config)
            save = .saved
        case let .savedButStale(failure):
            edits = [:]
            save = .savedButStale(failure)
        case let .notSaved(failure):
            // ⛔ THE EDITS SURVIVE. A failed save that also discarded what someone
            // typed would be two losses for one fault.
            save = .failed(failure)
        }
    }

    /// ⚠️ THE CATALOGUE IS NOT RE-READ, only the values it is interpreted against.
    /// The vocabularies are keyed on the workspace's region, which a save cannot
    /// change.
    private func rehydrate(_ config: WorkspaceConfig) {
        guard let options = draft?.options else { return }
        draft = PersonaIdentityDraft(persona: config.aiPersona, options: options)
    }
}
