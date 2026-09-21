import DistrictModel
import Foundation
import Observation

/// The capabilities this client knows how to name.
///
/// ⛔ A DISPLAY CATALOG, NOT THE SOURCE OF TRUTH FOR WHAT IS ENABLED, AND NOT THE
/// SOURCE OF TRUTH FOR WHAT AN ABSENT LIST MEANS EITHER. The stored `allowedTools`
/// array is the first, the server is the second, and this constant is neither. It can
/// legitimately be missing ids the server has: `transfer_to_creator` is retired, and
/// workspaces that still store it are migrated on load by the voice agent, so it is
/// live data rather than a hypothesis. Because `PATCH workspace/tools`
/// REPLACES the array wholesale, a toggle list built only from this catalog would
/// silently drop such an id on the next save. ``CapabilitiesModel/rows`` renders the
/// union, and the list that goes on the wire is never invented from this constant
/// alone.
///
/// ⛔ THIS IS NOT "THE WEB CONSOLE'S LIST IN THE WEB CONSOLE'S ORDER", AND TREATING IT AS
/// ONE IS HOW A DEFAULT CAPABILITY (`send_sms`) GETS DELETED BY A FIRST SAVE. The web
/// catalog holds THIRTEEN entries, of which NINE are the default set and four are the
/// District AI Scheduling tools, deliberately off until someone ticks them. This list
/// is the nine minus nothing; the four scheduling ids are not named here and render by
/// id when a workspace stores one. The web console groups capabilities by what a caller
/// is trying to do rather than by declaration order, so the order below is this
/// client's own.
enum CapabilityCatalog {
    /// ⚠️ THE NINE THE WEB TREATS AS ON FOR A WORKSPACE THAT HAS NEVER STORED A LIST,
    /// and they are here because this client can NAME them, not because it may write
    /// them. See ``CapabilitiesModel/storedTools``: nothing derives a save from this.
    static let ids = [
        "transfer_to_person",
        "transfer_to_agent",
        "dispatch_email",
        "check_availability",
        "book_appointment",
        "create_or_update_contact",
        "leave_message",
        "search_knowledge_base",
        "send_sms",
    ]

    /// The label for a known capability, or nil for one that arrived from the server
    /// unrecognised. ⚠️ Nil is a row that still renders, by id, and still saves.
    static func label(for id: String) -> String? {
        switch id {
        case "transfer_to_person": "Transfer to a person"
        case "transfer_to_agent": "Transfer to support"
        case "dispatch_email": "Send an email"
        case "check_availability": "Check the calendar"
        case "book_appointment": "Book an appointment"
        case "create_or_update_contact": "Save a caller's details"
        case "leave_message": "Take a message"
        case "search_knowledge_base": "Answer from the knowledge base"
        case "send_sms": "Text the caller"
        default: nil
        }
    }
}

/// One row in the capability list.
struct CapabilityRow: Identifiable {
    let id: String
    /// ⚠️ Nil for an id this client's catalog does not know. The row renders by id
    /// and still saves, because dropping it would be data loss through a
    /// wholesale-replace route.
    let label: String?
    let enabled: Bool
}

/// The capabilities screen's state machine. Ported from Android's
/// `CapabilitiesViewModel`.
///
/// ⛔ THIS IS THE DESTRUCTIVE ONE, AND EVERY GUARD HERE EXISTS FOR THAT REASON.
/// `PATCH workspace/tools` sets `toolConfig.allowedTools` to EXACTLY the array it
/// receives — no merge, no diff — so the list is only ever built from a configuration
/// that actually loaded, and it is built from that baseline rather than from this
/// client's catalog.
///
/// ⛔ AND AN ABSENT ALLOWLIST MEANS EVERY TOOL IS ON, WHICH IS A FACT ABOUT THE SERVER
/// THAT THIS CLIENT MAY DISPLAY AND MAY NOT WRITE DOWN. A brand-new workspace has
/// `toolConfig: null`; the web reads that as its own nine defaults enabled and may
/// materialise them on a first save, because the web form and the route ship from the
/// same deploy and cannot disagree about what "every tool" is. An installed build can
/// be months behind, so the same materialisation here DELETES whatever it has not
/// learned to name: a catalog one id short of the server's default set drops that id
/// permanently on the first save. ``storedTools`` therefore has NO fallback, and a section
/// with nothing stored is drawn read-only rather than saved from a guess. Reading nil
/// as an empty allowlist and saving would be the other, louder version of the same
/// mistake: switching the agent off entirely for someone who opened the screen to look
/// at it.
///
/// 🔑 THE RULE THAT PROTECTS THE NEXT ID SOMEONE ADDS SERVER-SIDE: a wholesale replace
/// is only ever built from an array the server sent. Adding an id to
/// ``CapabilityCatalog`` widens what this screen can NAME and can never widen what it
/// can delete, because the catalog is not in the path that produces
/// ``pendingTools``.
///
/// ⚠️ TWO SECTIONS, TWO ROUTES, TWO SAVE STATES. The enrichment flag is a persona
/// field and rides the merge-safe persona route, exactly as the web console does from
/// inside the same tab. Folding them into one
/// button would mean one tap writing through two routes with different failure modes,
/// and the wholesale-replace one would be the half nobody was thinking about.
@MainActor
@Observable
final class CapabilitiesModel {
    private(set) var load: SettingsConfigState = .loading
    private(set) var toolsSave: SettingsSaveState = .idle
    private(set) var enrichmentSave: SettingsSaveState = .idle

    /// ⚠️ SPARSE ON PURPOSE: only ids the operator actually flipped. Every row's
    /// effective state is derived from the LOADED baseline, so a row this client
    /// cannot name still renders and still saves.
    private var toggles: [String: Bool] = [:]

    /// The enrichment draft, or nil when untouched.
    ///
    /// ⚠️ NIL IS NOT `false`. The stored flag is itself optional (a workspace that has
    /// never answered) and both render as off — but only an explicit toggle may put a
    /// boolean on the wire, because the published sub-processor list's promise is that
    /// the feature is off until someone turns it on, and writing `false` for an
    /// untouched form would be a claim nobody made.
    private var enrichmentDraft: Bool?

    private let gateway: SettingsConfigGateway

    init(container: AppContainer, workspaceId: String) {
        gateway = SettingsConfigGateway(container: container, workspaceId: workspaceId)
    }

    /// The allowlist the server is actually storing.
    ///
    /// ⛔ NIL MEANS "THIS WORKSPACE HAS NEVER STORED ONE" AND THERE IS NO FALLBACK,
    /// AND THAT IS LOAD-BEARING. A `?? CapabilityCatalog.ids` here would give a workspace
    /// with `toolConfig: null` this client's own catalog, silently promoted into the
    /// baseline of a wholesale replace. ⚠️ An EMPTY array is a completely different
    /// answer and is returned as one: the operator turned everything off deliberately
    /// and that has to survive a round trip.
    var storedTools: [String]? {
        load.config?.toolConfig?.allowedTools
    }

    /// ⛔ WHETHER THERE IS ANYTHING FOR A WHOLESALE REPLACE TO REPLACE. See the ⛔ on the
    /// type: false is the state where this screen may show the capabilities and may not
    /// write them.
    ///
    /// ⚠️ SEPARATE FROM ``canEditTools`` BECAUSE THE SCREEN ASKS TWO DIFFERENT
    /// QUESTIONS. "Is this section permanently read-only" decides which CONTROL is drawn
    /// at all, and must not be confused with "is something in flight right now" — which
    /// on this screen includes the ENRICHMENT save, on the other route entirely. Folding
    /// them together would make saving the enrichment toggle replace the tools button with
    /// the sentence explaining that this workspace has never stored an allowlist, a lie
    /// for the length of a round trip.
    var hasStoredTools: Bool {
        storedTools != nil
    }

    /// ⛔ FALSE WHEN THERE IS NOTHING TO REPLACE, AND THE SECTION IS THEN READ-ONLY.
    /// See the ⛔ on the type: the toggles are drawn so the operator can see what the
    /// agent may do, and no control on them may reach ``saveTools()``.
    var canEditTools: Bool {
        hasStoredTools && !busy
    }

    /// The rows to draw: every catalog capability, plus anything stored the catalog
    /// does not know, appended in the order the server sent it.
    ///
    /// ⚠️ CATALOG ORDER FIRST so the familiar names read as a list, and unknown ids
    /// last so they are visibly the exception rather than interleaved with them.
    ///
    /// ⛔ WITH NOTHING STORED, EVERY NAMED CAPABILITY IS DRAWN ON AND NOTHING ELSE IS
    /// DRAWN AT ALL. That is the honest rendering of an absent allowlist: the nine this
    /// build knows are on, and this build cannot claim anything either way about ids it
    /// has never heard of. It is also why these rows are not editable.
    var rows: [CapabilityRow] {
        guard load.config != nil else { return [] }
        guard let stored = storedTools else {
            return CapabilityCatalog.ids.map { id in
                CapabilityRow(id: id, label: CapabilityCatalog.label(for: id), enabled: true)
            }
        }
        let unknown = stored.filter { !CapabilityCatalog.ids.contains($0) }
        return (CapabilityCatalog.ids + unknown).map { id in
            CapabilityRow(
                id: id,
                label: CapabilityCatalog.label(for: id),
                enabled: toggles[id] ?? stored.contains(id)
            )
        }
    }

    /// ⛔ THE COMPLETE LIST TO SEND, BUILT FROM WHAT THE SERVER STORED WITH THE TOGGLES
    /// APPLIED — never from the catalog — so an id the catalog does not know survives
    /// and the order the server is storing is preserved. Turning nothing off and
    /// nothing on produces the identical array that was loaded, which is the property
    /// that makes an accidental save harmless.
    ///
    /// ⚠️ Nil until a STORED list has been read, which is what makes "you cannot
    /// replace what the server never sent you" a fact about this type rather than a
    /// convention. `CapabilityCatalog` appears here only as an ORDER for ids the
    /// operator switched on, never as a source of ids.
    var pendingTools: [String]? {
        guard let stored = storedTools else { return nil }
        let kept = stored.filter { toggles[$0] != false }
        // ⚠️ Newly enabled ids are appended in CATALOG order rather than in dictionary
        // order, so the result does not depend on the sequence things were tapped in.
        let added = CapabilityCatalog.ids.filter { toggles[$0] == true && !stored.contains($0) }
        return kept + added
    }

    /// ⚠️ Compared as an ORDERED list: a reorder is a change to a value stored
    /// verbatim.
    var toolsDirty: Bool {
        guard let stored = storedTools, let pendingTools else { return false }
        return pendingTools != stored
    }

    /// What the enrichment switch shows: the draft, else the stored flag, else off.
    var enrichmentEnabled: Bool {
        enrichmentDraft ?? (load.config?.aiPersona?.dgiEnabled == true)
    }

    var enrichmentDirty: Bool {
        guard let draft = enrichmentDraft else { return false }
        return draft != (load.config?.aiPersona?.dgiEnabled == true)
    }

    private var busy: Bool {
        toolsSave.isSaving || enrichmentSave.isSaving
    }

    var canSaveTools: Bool {
        canEditTools && toolsDirty
    }

    var canSaveEnrichment: Bool {
        load.config != nil && !busy && enrichmentDirty
    }

    /// Read the configuration both sections hydrate from. ⛔ The only route to an
    /// editable state.
    func loadConfig() async {
        load = .loading
        let state = await gateway.load()
        load = state
        guard state.config != nil else { return }
        toggles = [:]
        enrichmentDraft = nil
        toolsSave = .idle
        enrichmentSave = .idle
    }

    /// Flip one capability.
    ///
    /// ⚠️ IGNORED UNLESS A STORED LIST WAS READ, for the reason the persona form
    /// ignores a keystroke and then one further: a toggle map accumulated against no
    /// baseline is the input to a wholesale replace, and with nothing stored there is
    /// no baseline at all rather than merely a failed one.
    func toggleTool(_ id: String, to enabled: Bool) {
        guard canEditTools else { return }
        toggles[id] = enabled
        toolsSave = .idle
    }

    /// Flip the external-lead-enrichment opt-in. ⚠️ Saved separately, through the
    /// persona route.
    func toggleEnrichment(to enabled: Bool) {
        guard load.config != nil else { return }
        enrichmentDraft = enabled
        enrichmentSave = .idle
    }

    /// Replace the allowlist.
    ///
    /// ⛔ SENDS ``pendingTools``, WHICH IS THE STORED LIST WITH THE TOGGLES APPLIED.
    /// Not the catalog, not the enabled rows rebuilt from scratch. The `else return`
    /// is the last line of defence behind ``canSaveTools``: with no config, or with a
    /// config carrying no stored allowlist, there is no list — and with no list there
    /// is nothing that may be sent to a route that replaces the stored one.
    func saveTools() async {
        guard canSaveTools, let tools = pendingTools else { return }
        toolsSave = .saving
        let write = await gateway.workspaces.saveTools(
            workspaceId: gateway.workspaceId,
            allowedTools: tools
        )
        await applyTools(gateway.commit(write))
    }

    /// Save the enrichment opt-in.
    ///
    /// ⚠️ ONE FIELD, THROUGH THE MERGE-SAFE PERSONA ROUTE. Every other persona field
    /// is omitted and therefore preserved, which is the contract that lets this toggle
    /// live on a different screen from the one that edits the persona's text.
    ///
    /// ⚠️ A **403** HERE IS USUALLY AN ENTITLEMENT AND NOT THE ROLE. Turning it on for
    /// a workspace that is not on Voice Studio answers `dgi_requires_studio` with copy
    /// naming the upgrade, and ``FailureText`` shows a 4xx sentence verbatim precisely
    /// so that reaches the screen instead of "you do not have permission".
    func saveEnrichment() async {
        guard canSaveEnrichment, let enabled = enrichmentDraft else { return }
        enrichmentSave = .saving
        let write = await gateway.workspaces.savePersona(
            workspaceId: gateway.workspaceId,
            name: nil,
            greeting: nil,
            personality: nil,
            dgiEnabled: enabled
        )
        await applyEnrichment(gateway.commit(write))
    }

    /// ⚠️ Retires both banners without a re-read.
    func dismissNotices() {
        guard !busy else { return }
        toolsSave = .idle
        enrichmentSave = .idle
    }

    // MARK: - Outcomes

    /// ⛔ ON SUCCESS THE TOGGLES ARE CLEARED AND THE FRESH CONFIG BECOMES THE
    /// BASELINE. Keeping them would leave the screen showing "changed" against a
    /// server that now agrees, and the NEXT save would re-send a diff against a
    /// baseline that had moved.
    ///
    /// ⛔ ON `savedButStale` THE TOGGLES ARE ALSO CLEARED — the write LANDED, so they
    /// are no longer pending — but the baseline is the stale one, which is exactly
    /// what the banner says. Re-saving from there is what the wording steers away
    /// from; re-reading is the fix.
    private func applyTools(_ outcome: SettingsSaveOutcome) {
        switch outcome {
        case let .saved(config):
            load = .ready(config)
            toggles = [:]
            toolsSave = .saved
        case let .savedButStale(failure):
            toggles = [:]
            toolsSave = .savedButStale(failure)
        case let .notSaved(failure):
            // ⛔ THE TOGGLES SURVIVE. The operator's intent is still on screen and
            // still theirs.
            toolsSave = .failed(failure)
        }
    }

    private func applyEnrichment(_ outcome: SettingsSaveOutcome) {
        switch outcome {
        case let .saved(config):
            load = .ready(config)
            enrichmentDraft = nil
            enrichmentSave = .saved
        case let .savedButStale(failure):
            enrichmentDraft = nil
            enrichmentSave = .savedButStale(failure)
        case let .notSaved(failure):
            enrichmentSave = .failed(failure)
        }
    }
}
