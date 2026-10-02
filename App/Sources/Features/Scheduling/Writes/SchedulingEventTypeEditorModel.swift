import DistrictData
import DistrictModel
import Foundation
import Observation

/// What an event-type write changed, as the screen behind the sheet needs it.
///
/// ⛔ THE ROW IS CARRIED RATHER THAN A "something changed" SIGNAL, because both
/// write ops ECHO it: `eventTypes.create` answers the created row and
/// `eventTypes.patch` answers the whole updated one. A callback that only said
/// "re-read" would throw away an answer already in hand and spend a second request
/// to get it back — and on a create it would throw away the SLUG the fork kept,
/// which is not necessarily the one that was sent.
enum SchedulingEventTypeChange {
    case saved(SchedulingEventType)
    case deleted(slug: String)
}

/// The create-and-edit form's state machine.
///
/// ⛔ ONE MODEL FOR BOTH, AND THE MODE DECIDES WHICH OP AND WHICH FIELD SET. The
/// two schemas are not nested — `create` takes fourteen fields and REFUSES
/// fourteen that `patch` accepts (see ``SchedulingEventTypeDraft``) — so the sheet
/// draws a short form on a create and the full one on an edit. Two models would
/// duplicate the name rule, the slug rule and the whole failure path to express a
/// difference that is four lines wide.
///
/// ⛔ THE REPOSITORY IS INJECTED, NEVER THE CONTAINER, WHICH IS THE OPPOSITE OF
/// ``SchedulingModel`` AND IS DELIBERATE. This sheet is presented BY a screen that
/// already holds the repository; taking the container would build the process's
/// token coordinator and resolve a keychain store in order to ask a question about
/// JSON, which is what stops the settings models being unit-testable.
/// ``SchedulingAdminRepository`` is a `Sendable` struct over the one ``ApiClient``,
/// so passing it costs nothing.
///
/// ⚠️ `onSaved` FIRES AFTER THE WRITE AND BEFORE THE SHEET DISMISSES, so the list
/// behind it is correct by the time it is visible again. Nothing here dismisses
/// anything: the view owns presentation.
@MainActor
@Observable
final class SchedulingEventTypeEditorModel {
    /// Which op a save performs.
    enum Mode: Equatable {
        case create
        /// The slug ADDRESSES the row and is not a field on it. See
        /// ``SchedulingEventTypeSlug``.
        case edit(slug: String)
    }

    private(set) var state: SchedulingWriteState = .idle
    /// The client-side refusal, which is not a ``SchedulingWriteState/failed(_:)``.
    ///
    /// ⛔ SEPARATE FROM THE WRITE'S OWN FAILURE BECAUSE NOTHING WAS SENT. A
    /// validation message rendered through the same slot as a server refusal would
    /// leave "we could not reach the booking system" on screen after the operator
    /// fixed a typo, and clearing the server's failure on every keystroke would
    /// hide the one sentence they need.
    private(set) var validation: String?

    var form: SchedulingEventTypeForm

    let mode: Mode
    /// ⚠️ READ-ONLY, and shown on an edit. It is the public address.
    let slug: String?

    /// ⛔ THE TYPE AS IT WAS LOADED, NOT AS IT IS NOW, AND THE DIFFERENCE IS THE
    /// WHOLE REASON IT IS STORED. A row can legitimately carry a location this
    /// build does not offer (`google_meet`); reading the live field instead would
    /// drop that choice out of the picker the moment somebody selected another one,
    /// which is a one-way change made by looking.
    private let storedLocation: String?

    private let admin: SchedulingAdminRepository
    private let workspaceId: String
    private let takenSlugs: [String]
    private let onSaved: (SchedulingEventTypeChange) -> Void

    /// - Parameters:
    ///   - editing: nil creates, a row edits it.
    ///   - takenSlugs: the slugs already on screen, so a create does not collide
    ///     with one the operator can see. ⚠️ Not a uniqueness guarantee — see
    ///     ``SchedulingEventTypeSlug/unique(from:taken:now:)``.
    init(
        admin: SchedulingAdminRepository,
        workspaceId: String,
        editing: SchedulingEventType? = nil,
        takenSlugs: [String] = [],
        onSaved: @escaping (SchedulingEventTypeChange) -> Void
    ) {
        self.admin = admin
        self.workspaceId = workspaceId
        self.takenSlugs = takenSlugs
        self.onSaved = onSaved
        if let editing {
            mode = .edit(slug: editing.slug)
            slug = editing.slug
            form = SchedulingEventTypeForm.from(editing)
            storedLocation = editing.locationType
        } else {
            mode = .create
            slug = nil
            form = SchedulingEventTypeForm()
            storedLocation = nil
        }
    }

    var isCreating: Bool {
        mode == .create
    }

    var title: String {
        isCreating ? SchedulingWriteCopy.createTitle : SchedulingWriteCopy.editTitle
    }

    /// ⚠️ THE BUTTON IS LIVE WHILE THE FORM IS INVALID, and the refusal is shown on
    /// the press. A disabled Save with no explanation is the shape that makes people
    /// hunt for the field they got wrong; the web behaves the same way.
    var canSave: Bool {
        !state.isWorking
    }

    /// What `location_value` is called here, or nil when the type generates it.
    var locationValueTitle: String? {
        SchedulingEventTypeForm.locationTitle(for: form.location)
    }

    var locationChoices: [(value: String, label: String)] {
        SchedulingEventTypeForm.locationChoices(including: storedLocation)
    }

    func save() async {
        guard !state.isWorking else { return }
        switch mode {
        case .create:
            await create()
        case let .edit(slug):
            await patch(slug: slug)
        }
    }

    func dismissNotice() {
        state = .idle
        validation = nil
    }

    // MARK: - The two writes

    private func create() async {
        if let error = form.createError {
            validation = error
            return
        }
        let slug = SchedulingEventTypeSlug.unique(from: form.trimmedName, taken: takenSlugs)
        guard let draft = form.createDraft(slug: slug) else { return }
        validation = nil
        state = .working
        do {
            let row = try await admin.createEventType(workspaceId: workspaceId, draft: draft)
            // ⚠️ IDLE, NOT A NOTICE: `onSaved` closes the sheet, so there is no one to read one.
            state = .idle
            onSaved(.saved(row))
        } catch {
            state = .failed(SchedulingFailureCopy.text(forAny: error))
        }
    }

    private func patch(slug: String) async {
        if let error = form.editError {
            validation = error
            return
        }
        guard let changes = form.changes() else { return }
        validation = nil
        state = .working
        do {
            let row = try await admin.patchEventType(workspaceId: workspaceId, slug: slug, changes: changes)
            // ⚠️ IDLE, NOT A NOTICE: `onSaved` closes the sheet, so there is no one to read one.
            state = .idle
            onSaved(.saved(row))
        } catch {
            state = .failed(SchedulingFailureCopy.text(forAny: error))
        }
    }
}
