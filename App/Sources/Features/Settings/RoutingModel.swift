import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import Observation

/// The dynamic-persona rules, editable.
///
/// ⛔ TWO FACTS ABOUT THE ROUTE WOULD MAKE A NAIVE EDITOR UNSAFE, AND EACH IS HANDLED
/// RATHER THAN WAIVED.
///
///   1. `POST workspace/routing-rules` REPLACES the stored array wholesale, the column
///      is `Json`, and its per-rule schema is `.passthrough()` — the committed fixture
///      holds rows shaped `{id, match, action, target}` that the web's own rule builder
///      does not edit. A row rebuilt from six typed fields would strip the rest and be
///      answered 200, which is a silent deletion INSIDE somebody's rule rather than of
///      one. ``RoutingRuleDraft`` carries the original object and overwrites only the
///      six keys this form owns, and a row it cannot read is sent back byte-identically.
///   2. The only server-side validation is a per-workspace voice and model allow-list
///      that this client cannot see. So the editor does NOT pre-validate against a
///      guess: it offers the catalogue `persona/options` publishes, sends what was
///      chosen, and shows the server's refusal verbatim — that refusal names the value.
///
/// ⛔ AND AN INTENTIONALLY EMPTY SAVE IS CONFIRMED RATHER THAN REFUSED. An operator who
/// wants no rules must be able to say so; what must not happen is an empty array going
/// out because a row was fumbled. ``wouldSaveEmpty`` is what the view asks first.
///
/// ⚠️ THE VOCABULARY READ IS ALLOWED TO FAIL WITHOUT TAKING THE SCREEN WITH IT. A rule's
/// field, operator, value and instruction need no catalogue; only its voice and engine
/// pickers do, and those fall back to showing what is stored. A built-in list is not an
/// option here for the same reason it is not on the persona form: the route stores
/// whatever it is sent.
@MainActor
@Observable
final class RoutingModel {
    private(set) var load: SettingsConfigState = .loading

    /// The rules as edited, or nil when there is no baseline to edit.
    ///
    /// ⛔ nil ALSO COVERS THE THIRD STATE THAT IS NOT A FAILURE: a stored `routingRules`
    /// whose rows are not objects. That column can hold rows written before its route
    /// validated anything, so such a value genuinely exists, and an editor
    /// over it would have to misrepresent part of it. ``notEditable`` tells the two
    /// apart.
    private(set) var drafts: [RoutingRuleDraft]?

    private(set) var notEditable = false

    private(set) var save: SettingsSaveState = .idle

    /// ⚠️ The voice and engine catalogue, or nil when that read failed. Never a
    /// built-in list.
    private(set) var options: PersonaOptionsResponse?

    let canWrite: Bool

    private let gateway: SettingsConfigGateway
    private let workspaces: WorkspaceRepository
    private let workspaceId: String

    /// Hands out ids for rows the operator adds, so `ForEach` identity survives a
    /// removal.
    ///
    /// ⚠️ MONOTONIC AND NEVER REUSED, the rule ``DirectoryModel`` records: indexing rows
    /// by position makes removing row 1 re-identify row 2 as row 1, which SwiftUI
    /// renders as the wrong text field keeping focus and the wrong row animating away.
    private var nextId: Int

    /// ⚠️ THE REPOSITORY RATHER THAN THE CONTAINER, so the editor is reachable from a
    /// test over a stub transport — which is the only way "an unrecognised row goes back
    /// byte-identically" can be checked, since that is a claim about request BYTES.
    init(workspaces: WorkspaceRepository, workspaceId: String, role: WorkspaceRole?) {
        gateway = SettingsConfigGateway(workspaces: workspaces, workspaceId: workspaceId)
        self.workspaces = workspaces
        self.workspaceId = workspaceId
        canWrite = WorkspaceRole.allowsMutation(role)
        nextId = 0
    }

    @MainActor
    convenience init(container: AppContainer, workspaceId: String, role: WorkspaceRole?) {
        self.init(workspaces: container.workspaces, workspaceId: workspaceId, role: role)
    }

    /// ⚠️ AN IDEMPOTENT GET WITH NO SIDE EFFECTS, so replaying it costs nothing and the
    /// retry button is honest.
    func loadConfig() async {
        load = .loading
        drafts = nil
        notEditable = false
        let state = await gateway.load()
        load = state
        guard case let .ready(config) = state else { return }
        hydrate(config)
        await loadOptions()
    }

    /// ⚠️ ITS OWN STEP, AND ITS FAILURE IS NOT THE SCREEN'S. See the ⚠️ on this type.
    func loadOptions() async {
        options = try? await workspaces.personaOptions(workspaceId: workspaceId).get()
    }

    /// The voices a rule may name.
    ///
    /// ⛔ DERIVED FROM THE CATALOGUE, NEVER RESTATED. The five voice names a hand-written
    /// list would carry are exactly the realtime engine's catalogue, and a hand-written
    /// MODEL list drifts the same way: one that never gains `inworld-pipeline` leaves a
    /// rule unable to select an engine the persona form and the agent both support.
    var ruleVoices: [PersonaLabelledValue] {
        options?.routingVoices() ?? []
    }

    /// ⚠️ EVERY ENGINE, AND THE OUT-OF-REGION ONES ARE DISABLED BY THE VIEW exactly as
    /// they are on the persona form. The residency consequence of a rule is the same as
    /// the workspace's.
    var ruleEngines: [PersonaEngineOption] {
        options?.routingEngines() ?? []
    }

    /// Change one rule.
    ///
    /// ⛔ A ROW THIS BUILD CANNOT READ IS NOT EDITED, only shown and kept. The fixture's
    /// `{id, match, action, target}` rows are live rules the agent evaluates; an editor
    /// over one would have to invent the six keys this form owns, and saving would then
    /// stamp them beside the four it could not read.
    func edit(_ id: Int, _ change: (inout RoutingRuleDraft) -> Void) {
        guard canWrite, !save.isSaving else { return }
        guard let index = drafts?.firstIndex(where: { $0.id == id }) else { return }
        guard drafts?[index].isRecognised == true else { return }
        change(&drafts![index])
        save = .idle
    }

    func addRule() {
        guard canWrite, !save.isSaving, drafts != nil else { return }
        drafts?.append(RoutingRuleDraft.added(id: nextId))
        nextId += 1
        save = .idle
    }

    /// ⚠️ AN UNRECOGNISED ROW MAY BE REMOVED even though it may not be edited. It is on
    /// screen, it is labelled as unreadable, and deleting it is an explicit act — which
    /// is not the same as this client quietly dropping it on a wholesale save.
    func removeRule(_ id: Int) {
        guard canWrite, !save.isSaving else { return }
        drafts?.removeAll { $0.id == id }
        save = .idle
    }

    /// Whether committing right now would send an empty array.
    ///
    /// ⛔ ASKED OF WHAT WOULD BE SENT, NOT OF `drafts.isEmpty`. A screen full of
    /// abandoned blank rows saves as empty too, and that is the case an operator would
    /// least expect to delete every rule.
    var wouldSaveEmpty: Bool {
        (drafts ?? []).allSatisfy(\.isBlank)
    }

    var canSave: Bool {
        canWrite && drafts != nil && !save.isSaving
    }

    /// Replace the stored rules with what is on screen.
    ///
    /// ⛔ EVERY ROW GOES BACK, INCLUDING THE ONES THIS BUILD CANNOT READ. The repository
    /// owns that: a recognised draft renders its six keys over the stored object, an
    /// unrecognised one is carried byte-identically, and only an ADDED row that was
    /// never filled in is dropped.
    func saveRules() async {
        guard canSave, let drafts else { return }
        save = .saving
        let result = await workspaces.saveRoutingRules(workspaceId: workspaceId, rules: drafts)
        switch await gateway.commit(result) {
        case let .saved(config):
            load = .ready(config)
            // ⛔ RE-HYDRATED FROM THE SERVER'S ANSWER, NOT LEFT AS THE DRAFT. The next
            // save is a wholesale replace built on this baseline, so it has to be the
            // stored one.
            hydrate(config)
            save = .saved
        case let .savedButStale(failure):
            // ⚠️ THE WRITE LANDED AND ONLY THE READ BACK FAILED. The drafts stay, because
            // they are what was written; the banner offers a re-read rather than a
            // re-save.
            save = .savedButStale(failure)
        case let .notSaved(failure):
            // ⚠️ THE EDITS ARE KEPT, AND HERE THE MESSAGE MATTERS AS MUCH AS THEY DO: a
            // 400 from this route is usually a real, specific refusal naming the voice or
            // model a workspace does not permit.
            save = .failed(failure)
        }
    }

    func dismissNotices() {
        save = .idle
    }

    // MARK: - Internals

    /// ⛔ ONE DEFENSIVE READ, IN ``SettingsWireDisplay/ruleRows(_:)``, AND NOT A SECOND
    /// COPY HERE. An absent column is an EMPTY list; an array of something other than
    /// objects is a value this client will not claim to understand.
    private func hydrate(_ config: WorkspaceConfig) {
        guard let rows = SettingsWireDisplay.ruleRows(config.routingRules) else {
            drafts = nil
            notEditable = true
            return
        }
        notEditable = false
        drafts = rows.enumerated().map { RoutingRuleDraft(id: $0.offset, row: $0.element) }
        nextId = rows.count
    }
}
