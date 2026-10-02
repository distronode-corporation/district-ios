import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import Observation

/// The desk's settings: two switches, a public name and a public logo.
///
/// ⛔ EVERY WRITE HERE PATCHES ONE KEY AND ADOPTS ONLY WHAT THE SERVER ECHOES BACK.
/// Sending the whole form would make this screen the writer of values it may have
/// read before another operator changed them on the web — and, after a failed load,
/// a form that writes blanks over live configuration. ``DeskRepository/updateSettings`` drops every nil,
/// which is the mechanism; passing one field per call is the discipline.
///
/// ⛔ THE BRAND-NAME DRAFT IS SEEDED ONLY FROM A SUCCESSFUL READ, AND `nil` IS NOT
/// `""`. Seeding an empty box from a read that FAILED and then saving would write a
/// blank over the heading a tenant's own customers see. That is why ``brandDraft``
/// starts nil and the field is not editable until a read has landed.
///
/// ⛔ TWO CONSEQUENCES OF `enabled` LAND ON A LIVE CALL — the agent's unresolved-call
/// teardown re-routes into this queue, and callers can ask it for the status of their
/// own requests — so the copy says both BEFORE the switch is flipped. Opt-in is the
/// whole safety story for this feature.
@MainActor
@Observable
final class DeskSettingsModel {
    private(set) var settings: DeskSettings?
    private(set) var loadFailure: FailureText?
    private(set) var save: SettingsSaveState = .idle

    /// ⚠️ nil = not loaded. See the ⛔ on the type; this is deliberately distinct
    /// from an empty string, which means "the operator cleared it".
    private(set) var brandDraft: String?

    private(set) var uploading = false

    /// ⛔ False for `viewer` and for a role that did not parse.
    let canWrite: Bool

    private let desk: DeskRepository
    private let workspaceId: String

    /// ⛔ THE CONTAINER'S ONE REPOSITORY. See the ⛔ on
    /// ``DeskModel/init(container:workspaceId:role:)``.
    init(container: AppContainer, workspaceId: String, role: WorkspaceRole?) {
        desk = container.desk
        self.workspaceId = workspaceId
        canWrite = WorkspaceRole.allowsMutation(role)
    }

    /// ⚠️ EVERY CONTROL IS INERT WHILE A WRITE IS IN FLIGHT, so a second tap is a
    /// no-op rather than a second write racing the first's response.
    var busy: Bool {
        save.isSaving || uploading
    }

    /// ⛔ THE THREE DEPENDENT CONTROLS FOLLOW `enabled`, matching the web. Emailing
    /// customers, the public name and the public logo are all properties of a queue
    /// that is running; offering them for a desk that is off would configure something
    /// no customer can reach.
    var canEditDependents: Bool {
        canWrite && !busy && settings?.enabled == true
    }

    func editBrandDraft(_ value: String) {
        brandDraft = value
    }

    func dismissNotice() {
        guard !busy else { return }
        save = .idle
    }

    func load() async {
        switch await desk.settings(workspaceId: workspaceId) {
        case let .success(row):
            settings = row
            loadFailure = nil
            // ⛔ SEEDED ONLY HERE. See the ⛔ on the type.
            brandDraft = row.publicBrandName ?? ""
        case let .failure(error):
            settings = nil
            loadFailure = FailureText.from(error)
        }
    }

    /// Turn the desk on or off.
    ///
    /// ⛔ THE ONE WRITE ON THIS SCREEN THAT CHANGES WHAT HAPPENS ON A LIVE CALL.
    func setEnabled(_ value: Bool) async {
        await patch { await $0.updateSettings(workspaceId: $1, enabled: value) }
    }

    func setNotifyCustomers(_ value: Bool) async {
        await patch { await $0.updateSettings(workspaceId: $1, notifyCustomersByEmail: value) }
    }

    /// Save the public name.
    ///
    /// ⛔ AN EMPTIED BOX IS AN EXPLICIT CLEAR, NOT AN OMITTED KEY. `DeskBrandName.clear`
    /// sends a null, which is what makes the tenant's customers fall back to the
    /// workspace's own name; omitting the key would mean "leave it alone" and the old
    /// heading would stay up.
    ///
    /// ⚠️ SAVED ON COMMIT AND SKIPPED WHEN NOTHING CHANGED. A patch per keystroke would
    /// write a tenant's public-facing name dozens of times per edit and race its own
    /// responses.
    func commitBrandName() async {
        guard let draft = brandDraft, let current = settings else { return }
        let next = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard next != (current.publicBrandName ?? "") else { return }
        let change: DeskBrandName = next.isEmpty ? .clear : .set(next)
        await patch { await $0.updateSettings(workspaceId: $1, publicBrandName: change) }
    }

    /// Publish a logo.
    ///
    /// ⛔ NO OPTIMISTIC PREVIEW. Showing the picked image as "your customers see this"
    /// would be a claim about an upload that may never have landed, on a page other
    /// people open. Only the server's echoed row is adopted.
    ///
    /// ⚠️ THE TYPE AND SIZE ARE REFUSED IN ``DeskRepository`` rather than here, so this
    /// screen shows the same sentence a real 415 or 413 would produce.
    func uploadLogo(_ bytes: Data, mimeType: String) async {
        guard canEditDependents else { return }
        uploading = true
        save = .idle
        switch await desk.uploadLogo(
            workspaceId: workspaceId,
            mimeType: mimeType,
            bytes: bytes
        ) {
        case let .success(row):
            adopt(row)
            save = .saved
        case let .failure(error):
            save = .failed(FailureText.from(error))
        }
        uploading = false
    }

    /// ⚠️ THE PICKER COULD NOT READ THE FILE, which is a different failure from a
    /// refused type or size and calls for a different next action.
    func refuseUnreadableLogo() {
        save = .failed(FailureText(message: DeskCopy.logoUnreadable, action: .none))
    }

    /// Take the logo down.
    ///
    /// ⛔ THE HALF-SUCCESS IS REPORTED RATHER THAN ROUNDED UP. `objectRemoved: false`
    /// means the image is off the customers' page and the stored file is still
    /// downloadable — which matters precisely when the reason for removing it was that
    /// it should not be public at all. ``SettingsSaveState/savedButStale(_:)`` is the
    /// existing vocabulary for "the write landed and something after it did not", and
    /// its notice offers a re-run rather than a re-save.
    func removeLogo() async {
        guard canWrite, !busy else { return }
        save = .saving
        switch await desk.removeLogo(workspaceId: workspaceId) {
        case let .success(removal):
            adopt(removal.settings)
            save = removal.objectRemoved
                ? .saved
                : .savedButStale(FailureText(message: DeskCopy.logoClearedNotDeleted, action: .retry))
        case let .failure(error):
            save = .failed(FailureText.from(error))
        }
    }

    // MARK: - Internals

    /// ⛔ ONE WRITE PATH, SO "ADOPT THE ECHO" CANNOT BE FORGOTTEN AT ONE CALL SITE.
    /// Every settings mutation answers the whole stored row, which is what a later
    /// read will see; a screen that kept the value it sent would be showing something
    /// nobody stored the moment the server disagreed.
    private func patch(
        _ write: (DeskRepository, String) async -> Result<DeskSettings, ApiError>
    ) async {
        guard canWrite, !busy else { return }
        save = .saving
        switch await write(desk, workspaceId) {
        case let .success(row):
            adopt(row)
            save = .saved
        case let .failure(error):
            save = .failed(FailureText.from(error))
        }
    }

    /// ⚠️ THE DRAFT IS RESEEDED FROM THE ECHO, so a name the server trimmed or refused
    /// is what the box shows afterwards rather than what was typed.
    private func adopt(_ row: DeskSettings) {
        settings = row
        brandDraft = row.publicBrandName ?? ""
    }
}
