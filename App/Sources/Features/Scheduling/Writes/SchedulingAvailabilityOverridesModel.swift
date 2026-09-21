import DistrictData
import DistrictModel
import Foundation
import Observation

/// Dated exceptions to the weekly hours: list, add, delete one day, delete a whole
/// range.
///
/// ⛔ THE ROWS ARE FOLDED BY ``SchedulingHoursFormat/upcomingOverrides(_:today:)``
/// AND NOT BY THIS TYPE. That fold — group by `group_id`, widen the ends, count
/// the days, drop anything whose LAST day is behind today — is the algorithm the
/// read screen already renders through, tested in `DistrictDataTests`. A second
/// copy here would let the editor and the screen behind it disagree about which
/// holiday is still ahead.
///
/// ⚠️ THE LIST OP TAKES NO PARAMS AT ALL — no date window, no event type — so
/// every narrowing is this side's job. Past overrides are filtered here.
@MainActor
@Observable
final class SchedulingAvailabilityOverridesModel {
    private(set) var overrides: [SchedulingAvailabilityOverride] = []
    private(set) var rows: [SchedulingOverrideRow] = []
    private(set) var loadState: SchedulingWriteState = .idle
    private(set) var state: SchedulingWriteState = .idle
    private(set) var validation: String?
    private(set) var notice: String?

    /// The add sheet's contents, or nil when it is closed.
    private(set) var adding: SchedulingOverrideForm?
    private(set) var confirmingDelete: SchedulingOverrideRow?

    private let admin: SchedulingAdminRepository
    private let workspaceId: String
    private let today: String
    private let onSaved: ([SchedulingAvailabilityOverride]) -> Void

    /// - Parameter today: `YYYY-MM-DD` in the MEMBER'S scheduler timezone, which is
    ///   not necessarily the device's. ⛔ Injected rather than computed here: a row
    ///   is hidden once its last day is behind today, and deriving "today" from
    ///   `TimeZone.current` would hide a travelling member's day off a few hours
    ///   early or late with nothing on screen saying so.
    init(
        admin: SchedulingAdminRepository,
        workspaceId: String,
        today: String,
        onSaved: @escaping ([SchedulingAvailabilityOverride]) -> Void
    ) {
        self.admin = admin
        self.workspaceId = workspaceId
        self.today = today
        self.onSaved = onSaved
    }

    func load() async {
        loadState = .saving
        do {
            overrides = try await admin.availabilityOverrides(workspaceId: workspaceId)
            rows = SchedulingHoursFormat.upcomingOverrides(overrides, today: today)
            loadState = .saved
        } catch {
            loadState = .failed(SchedulingEventTypeEditorModel.failure(error))
        }
    }

    // MARK: - The add sheet

    func beginAdd() {
        adding = SchedulingOverrideForm()
        validation = nil
    }

    func updateAdding(_ transform: (inout SchedulingOverrideForm) -> Void) {
        guard var form = adding else { return }
        transform(&form)
        adding = form
    }

    func cancelAdd() {
        adding = nil
        validation = nil
    }

    func beginDelete(_ row: SchedulingOverrideRow) {
        confirmingDelete = row
    }

    func cancelDelete() {
        confirmingDelete = nil
    }

    /// ⚠️ ONE DIALOG, TWO SENTENCES. A range says how many days go back to the
    /// weekly hours, because that is the number somebody is agreeing to.
    func deleteBody(for row: SchedulingOverrideRow) -> String {
        row.days > 1
            ? SchedulingWriteCopy.overrideDeleteGroupBody(days: row.days)
            : SchedulingWriteCopy.overrideDeleteSingleBody
    }

    func dismissNotice() {
        notice = nil
        validation = nil
        state = .idle
    }

    // MARK: - The writes

    func submit() async {
        guard let form = adding, !state.isSaving else { return }
        if let error = form.error {
            validation = error
            return
        }
        guard let draft = form.draft() else { return }
        validation = nil
        state = .saving
        do {
            // ⚠️ THE ANSWER IS A UNION AND IS DELIBERATELY DISCARDED. A single date
            // answers the row, a range answers a summary with no `id` in it at all,
            // and neither says where it sits among the others — which is what the
            // table draws. The re-read is the cheaper correct answer.
            _ = try await admin.createAvailabilityOverride(workspaceId: workspaceId, draft: draft)
            state = .saved
            notice = SchedulingWriteCopy.overrideAdded
            adding = nil
            await reread()
        } catch {
            // ⛔ A 409 HERE MEANS "there is already an override on that date" AND
            // THIS CLIENT CANNOT SAY SO. The web reads `error.status === 409` and
            // writes its own sentence; ``SchedulingAdminError`` drops the status on
            // purpose (there is no `.http(status:)` escape hatch), so a 409 that is
            // not `scheduling_not_ready` arrives as `.unknown` and gets the generic
            // sentence. Divergence from the browser, recorded rather than papered
            // over with a guess about which refusal this was.
            state = .failed(SchedulingEventTypeEditorModel.failure(error))
        }
    }

    func delete() async {
        guard let row = confirmingDelete, !state.isSaving else { return }
        confirmingDelete = nil
        state = .saving
        do {
            // ⛔ `target` IS THE ID A DELETE NAMES AND `kind` IS WHICH OP NAMES IT —
            // the row's own id for a single day, the GROUP's for a span. A fortnight
            // away is fourteen stored rows, and deleting one of them is thirteen ways
            // to half-cancel a holiday.
            switch row.kind {
            case .single:
                try await admin.deleteAvailabilityOverride(workspaceId: workspaceId, id: row.target)
            case .group:
                try await admin.deleteAvailabilityOverrideGroup(
                    workspaceId: workspaceId,
                    groupId: row.target
                )
            }
            state = .saved
            notice = SchedulingWriteCopy.overrideDeleted
            await reread()
        } catch {
            state = .failed(SchedulingEventTypeEditorModel.failure(error))
        }
    }

    private func reread() async {
        do {
            overrides = try await admin.availabilityOverrides(workspaceId: workspaceId)
            rows = SchedulingHoursFormat.upcomingOverrides(overrides, today: today)
            onSaved(overrides)
        } catch {
            loadState = .failed(SchedulingEventTypeEditorModel.failure(error))
        }
    }
}
