import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import Observation

/// One transfer target, as the editor holds it.
///
/// ⛔ IT CARRIES THE ORIGINAL ROW, AND THAT IS THE WHOLE DESIGN. The route's per-entry zod
/// schema is `.passthrough()` and the column is `Json`, so a stored row can hold keys this
/// client has never modelled — and `PATCH workspace/directory` REPLACES the whole array. A
/// row rebuilt from the three fields below would strip the rest and be answered 200, which
/// is a silent deletion INSIDE somebody's row rather than of one. ``rendered()`` overwrites
/// exactly the keys this form owns and leaves everything else where it was.
///
/// ⚠️ `source` IS nil FOR A ROW THE OPERATOR ADDED, which is the only case where there is
/// nothing to preserve.
struct DirectoryDraft: Identifiable {
    let id: Int
    var name: String
    var phoneNumber: String
    /// `"pstn"` or `"app"`, or nil for a row that has never had a `type` key.
    ///
    /// ⛔ nil IS NOT `"pstn"` AND MUST NOT BE NORMALISED INTO IT ON SAVE. Every entry
    /// stored today has no `type`, every reader already treats an entry as a phone number,
    /// and writing the default in would rewrite every tenant's config on the next save to
    /// say what it already meant — while making "did an operator CHOOSE pstn?"
    /// unanswerable. The picker therefore shows nil AS "Phone number" and only writes the
    /// key when somebody selects one.
    var type: String?
    private let source: WireJSON?

    init(id: Int, row: WireJSON?) {
        self.id = id
        source = row
        name = Self.text(row?["name"])
        phoneNumber = Self.text(row?["phoneNumber"])
        type = row?["type"]?.stringValue
    }

    var isIncomplete: Bool {
        DirectoryDraft.trimmed(phoneNumber).isEmpty
    }

    /// Whether this row is worth sending at all.
    ///
    /// ⛔ A ROW WITH NEITHER A NAME NOR A NUMBER IS DROPPED, AND NOTHING ELSE IS. The
    /// server's schema has both fields `.nullish()`, so a half-filled row is legal and
    /// already exists in the corpus — it is a target the agent cannot use, which is worth
    /// SHOWING rather than deleting on somebody's behalf. An entirely blank row is the
    /// "Add someone" button pressed and then abandoned, and saving it would grow the
    /// stored array by one every time.
    var isBlank: Bool {
        DirectoryDraft.trimmed(name).isEmpty && DirectoryDraft.trimmed(phoneNumber).isEmpty
    }

    /// The row to send: the original with this form's keys overwritten.
    ///
    /// ⛔ IT STARTS FROM THE STORED OBJECT, NEVER FROM AN EMPTY ONE. See the ⛔ on this
    /// type. ⚠️ A trimmed-empty field is written as an empty STRING rather than dropped,
    /// because the operator clearing a name is a real edit and `.nullish()` accepts it;
    /// dropping the key would leave the old value in place on a wholesale replace, which
    /// is the one direction that looks like the save silently failed.
    func rendered() -> JSONValue {
        var fields: [String: JSONValue] = [:]
        if case let .object(stored) = source {
            fields = stored.mapValues(JSONValue.carrying)
        }
        fields["name"] = .string(DirectoryDraft.trimmed(name))
        fields["phoneNumber"] = .string(DirectoryDraft.trimmed(phoneNumber))
        if let type {
            fields["type"] = .string(type)
        } else {
            // ⛔ REMOVED RATHER THAN SET TO `pstn`. A row that never had the key keeps not
            // having it; a row whose operator switched BACK from "app" loses it, which is
            // the same stored state as every legacy row and means the same thing.
            fields.removeValue(forKey: "type")
        }
        return .object(fields)
    }

    private static func text(_ value: WireJSON?) -> String {
        value?.stringValue ?? ""
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The transfer directory, editable.
///
/// ⛔ IT MAY ONLY EVER SAVE FROM A SUCCESSFUL LOAD, AND `SettingsConfigState` IS WHERE THAT
/// IS ENFORCED: it has no case for "we could not read the configuration, here is an empty
/// form anyway". `PATCH workspace/directory` writes `callDirectory: (callDirectory || [])`,
/// so a form rendered from nothing and then saved does not save nothing — it removes every
/// human the voice agent can put a live caller through to, and answers `{success:true}`.
/// There is no undo and no export.
///
/// ⛔ AND AN INTENTIONALLY EMPTY SAVE IS CONFIRMED RATHER THAN REFUSED. An operator who
/// wants no transfer targets must be able to say so; what must not happen is an empty array
/// going out because a row was fumbled. ``wouldSaveEmpty`` is what the view asks before it
/// commits.
///
/// ⛔ THE ROWS ARE CARRIED WHOLE. Every draft holds its source row and overwrites only the
/// three keys this form owns — see ``DirectoryDraft``. Nothing here rebuilds a row from a
/// typed model.
///
/// ⚠️ IT RE-READS AFTER A SUCCESSFUL SAVE, because this route answers a bare
/// `{"success": true}` and echoes nothing. ``SettingsConfigGateway/commit(_:)`` owns that,
/// including the third outcome nobody expects: the write landed and the read back did not,
/// which must never be reported as a failed save.
@MainActor
@Observable
final class DirectoryModel {
    private(set) var load: SettingsConfigState = .loading

    /// The rows as edited, or nil when there is no baseline to edit.
    ///
    /// ⛔ nil ALSO COVERS THE THIRD STATE THAT IS NOT A FAILURE: a stored `callDirectory`
    /// whose rows are not objects. That column can hold rows written before its route
    /// validated anything, so such a value genuinely exists, and an editor that
    /// showed it would have to misrepresent part of it. ``notEditable`` tells the two apart.
    private(set) var drafts: [DirectoryDraft]?

    /// ⛔ THE READ SUCCEEDED AND THE VALUE STILL CANNOT BE EDITED. Distinct from a load
    /// failure, and no retry is offered: repeating the request returns the same value.
    private(set) var notEditable = false

    private(set) var save: SettingsSaveState = .idle

    let canWrite: Bool

    private let gateway: SettingsConfigGateway
    private let workspaces: WorkspaceRepository
    private let workspaceId: String

    /// Hands out ids for rows the operator adds, so `ForEach` identity survives a removal.
    ///
    /// ⚠️ MONOTONIC AND NEVER REUSED. Indexing rows by position would make removing row 1
    /// re-identify row 2 as row 1, which SwiftUI renders as the wrong text field keeping
    /// focus and the wrong row animating away.
    private var nextId: Int

    init(container: AppContainer, workspaceId: String, role: WorkspaceRole?) {
        gateway = SettingsConfigGateway(container: container, workspaceId: workspaceId)
        workspaces = container.workspaces
        self.workspaceId = workspaceId
        canWrite = WorkspaceRole.allowsMutation(role)
        nextId = 0
    }

    /// ⚠️ AN IDEMPOTENT GET WITH NO SIDE EFFECTS, so replaying it costs nothing and the
    /// retry button is honest.
    func loadConfig() async {
        load = .loading
        drafts = nil
        notEditable = false
        await adopt(gateway.load())
    }

    func editName(_ id: Int, _ value: String) {
        mutate(id) { $0.name = value }
    }

    func editNumber(_ id: Int, _ value: String) {
        mutate(id) { $0.phoneNumber = value }
    }

    /// ⛔ `nil` IS A REAL CHOICE HERE AND MEANS "leave the key off". See the ⛔ on
    /// ``DirectoryDraft/type``.
    func editType(_ id: Int, _ value: String?) {
        mutate(id) { $0.type = value }
    }

    func addRow() {
        guard canWrite, !save.isSaving, drafts != nil else { return }
        drafts?.append(DirectoryDraft(id: nextId, row: nil))
        nextId += 1
    }

    func removeRow(_ id: Int) {
        guard canWrite, !save.isSaving else { return }
        drafts?.removeAll { $0.id == id }
    }

    /// Whether committing right now would send an empty array.
    ///
    /// ⛔ THE VIEW CONFIRMS ON THIS RATHER THAN ON `drafts.isEmpty`, because a screen full
    /// of abandoned blank rows saves as empty too — and that is the case an operator would
    /// least expect to be destructive.
    var wouldSaveEmpty: Bool {
        rowsToSend().isEmpty
    }

    var canSave: Bool {
        canWrite && drafts != nil && !save.isSaving
    }

    /// Replace the stored directory with what is on screen.
    func saveDirectory() async {
        guard canWrite, !save.isSaving else { return }
        guard load.config != nil, drafts != nil else { return }
        save = .saving
        let result = await workspaces.saveDirectory(workspaceId: workspaceId, callDirectory: rowsToSend())
        switch await gateway.commit(result) {
        case let .saved(config):
            load = .ready(config)
            // ⛔ RE-HYDRATED FROM THE SERVER'S ANSWER, NOT LEFT AS THE DRAFT. The next save
            // is a wholesale replace built on this baseline, so it has to be the stored one.
            hydrate(config)
            save = .saved
        case let .savedButStale(failure):
            // ⚠️ THE WRITE LANDED AND ONLY THE READ BACK FAILED. The drafts stay, because
            // they are what was written; the banner says the screen may be out of date and
            // offers a re-read rather than a re-save.
            save = .savedButStale(failure)
        case let .notSaved(failure):
            // ⚠️ THE EDITS ARE KEPT. Nothing was written, and a failed save that also
            // discarded what somebody typed would be two losses for one fault.
            save = .failed(failure)
        }
    }

    func dismissNotices() {
        save = .idle
    }

    // MARK: - Internals

    private func adopt(_ state: SettingsConfigState) {
        load = state
        guard case let .ready(config) = state else { return }
        hydrate(config)
    }

    /// ⛔ ONE DEFENSIVE READ, IN ``SettingsWireDisplay/directoryRows(_:)``, AND NOT A
    /// SECOND COPY HERE. The nil it can answer is why ``notEditable`` exists: an absent
    /// column is an EMPTY list (the route writes `callDirectory || []`, so "never
    /// configured" and "explicitly empty" are the same stored value), while an array of
    /// something other than objects is a value this client will not claim to understand.
    private func hydrate(_ config: WorkspaceConfig) {
        guard let rows = SettingsWireDisplay.directoryRows(config.callDirectory) else {
            drafts = nil
            notEditable = true
            return
        }
        notEditable = false
        drafts = rows.enumerated().map { DirectoryDraft(id: $0.offset, row: $0.element) }
        nextId = rows.count
    }

    private func mutate(_ id: Int, _ change: (inout DirectoryDraft) -> Void) {
        guard canWrite, !save.isSaving else { return }
        guard let index = drafts?.firstIndex(where: { $0.id == id }) else { return }
        change(&drafts![index])
    }

    /// ⚠️ BLANK ROWS ARE DROPPED AND HALF-FILLED ONES ARE NOT. See the ⛔ on
    /// ``DirectoryDraft/isBlank``.
    private func rowsToSend() -> [JSONValue] {
        (drafts ?? []).filter { !$0.isBlank }.map { $0.rendered() }
    }
}
