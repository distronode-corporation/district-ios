import DistrictData
import DistrictModel
import Foundation
import Observation

/// The weekly working-hours editor: read the rules, edit a week, save the
/// difference.
///
/// ⛔ THE SAVE IS A DIFF, NOT A REPLACE, AND THERE IS NO OP THAT WOULD LET IT BE A
/// REPLACE. `availability.rules.*` is create/patch/delete per row — there is no
/// "put the week" — so a screen that wanted to be simple would have to delete
/// seven days of rules and recreate them, which is two writes per window for a
/// save that changed one, and leaves the tenancy with NO working hours at all for
/// as long as the middle of that sequence takes.
///
/// ⛔ THE THREE PHASES RUN IN ORDER AND STOP AT THE FIRST REFUSAL, which means a
/// partial save is a real outcome and is reported as one. It is still the right
/// arrangement: the alternative is issuing the creates anyway, into a week whose
/// deletes did not happen, where every one of them overlaps something.
/// ⚠️ The re-read runs either way, so what is on screen afterwards is what the
/// fork holds rather than what this client hoped.
///
/// ⚠️ `event_type_id` IS NOT PATCHABLE, so nothing here offers to move a window
/// between event types. The schema takes the day and the two times and nothing
/// else; a control for it would be a 400 on a field the server never reads.
@MainActor
@Observable
final class SchedulingAvailabilityRulesModel {
    private(set) var week: [[SchedulingHoursDraftRange]] =
        Array(repeating: [], count: SchedulingWorkingHours.dayCount)
    private(set) var stored: [SchedulingAvailabilityRule] = []
    private(set) var loadState: SchedulingWriteState = .idle
    private(set) var state: SchedulingWriteState = .idle
    private(set) var notice: String?

    private let admin: SchedulingAdminRepository
    private let workspaceId: String
    private let onSaved: ([SchedulingAvailabilityRule]) -> Void

    init(
        admin: SchedulingAdminRepository,
        workspaceId: String,
        onSaved: @escaping ([SchedulingAvailabilityRule]) -> Void
    ) {
        self.admin = admin
        self.workspaceId = workspaceId
        self.onSaved = onSaved
    }

    /// ⚠️ SAVE IS DISABLED WHILE ANY RANGE IS INVALID, unlike the event-type
    /// editor's Save. The difference is that this screen reports per ROW: the
    /// operator can already see which window is wrong, so pressing a live button to
    /// be told again buys nothing.
    var canSave: Bool {
        !state.isSaving && SchedulingWorkingHours.isValid(week)
    }

    func errors(forRow row: Int) -> [String?] {
        guard week.indices.contains(row) else { return [] }
        return SchedulingWorkingHours.errors(in: week[row])
    }

    func load() async {
        loadState = .saving
        do {
            let rules = try await admin.availabilityRules(workspaceId: workspaceId)
            stored = rules
            week = SchedulingWorkingHours.week(from: rules)
            loadState = .saved
        } catch {
            loadState = .failed(SchedulingEventTypeEditorModel.failure(error))
        }
    }

    // MARK: - Editing the week

    func addRange(toRow row: Int) {
        guard week.indices.contains(row) else { return }
        week[row].append(
            SchedulingHoursDraftRange(
                ruleId: nil,
                start: SchedulingWorkingHours.defaultStart,
                end: SchedulingWorkingHours.defaultEnd
            )
        )
    }

    func removeRange(_ id: UUID, fromRow row: Int) {
        guard week.indices.contains(row) else { return }
        week[row].removeAll { $0.id == id }
    }

    func setStart(_ value: String, for id: UUID, inRow row: Int) {
        update(id, inRow: row) { $0.start = value }
    }

    func setEnd(_ value: String, for id: UUID, inRow row: Int) {
        update(id, inRow: row) { $0.end = value }
    }

    func copyToWeekdays(from row: Int) {
        week = SchedulingWorkingHours.copyToWeekdays(from: row, in: week)
    }

    func dismissNotice() {
        notice = nil
        state = .idle
    }

    private func update(_ id: UUID, inRow row: Int, _ transform: (inout SchedulingHoursDraftRange) -> Void) {
        guard week.indices.contains(row), let index = week[row].firstIndex(where: { $0.id == id }) else {
            return
        }
        transform(&week[row][index])
    }

    // MARK: - The save

    func save() async {
        guard !state.isSaving, canSave else { return }
        let diff = SchedulingWorkingHours.diff(week: week, stored: stored)
        guard !diff.isEmpty else {
            // ⚠️ NOT A FAILURE AND NOT A REQUEST. A no-op patch still spends a write
            // from the workspace's hourly budget, so the honest answer is a sentence.
            state = .saved
            notice = SchedulingWriteCopy.hoursNothingToSave
            return
        }
        state = .saving
        notice = nil
        do {
            try await apply(diff)
            state = .saved
            notice = SchedulingWriteCopy.hoursSaved
        } catch {
            state = .failed(SchedulingEventTypeEditorModel.failure(error))
        }
        // ⛔ THE RE-READ RUNS AFTER A FAILURE TOO, AND IT DISCARDS THE DRAFT — which
        // breaks the rule every other sheet here follows ("a failed save keeps the
        // edits") on purpose. The three phases stop at the first refusal, so a
        // failure means SOME of them landed; keeping the draft would build the next
        // diff on a baseline that is now wrong, and re-issue deletes and creates
        // that already happened. What is on screen afterwards is what the fork
        // holds.
        await load()
        onSaved(stored)
    }

    /// ⛔ DELETES, THEN PATCHES, THEN CREATES. See ``SchedulingHoursDiff``: the fork
    /// refuses overlapping windows, so a create that runs before the delete it
    /// replaces is refused against a window on its way out.
    private func apply(_ diff: SchedulingHoursDiff) async throws {
        for id in diff.deletes {
            try await admin.deleteAvailabilityRule(workspaceId: workspaceId, id: id)
        }
        for patch in diff.patches {
            _ = try await admin.patchAvailabilityRule(
                workspaceId: workspaceId,
                id: patch.id,
                dayOfWeek: patch.dayOfWeek,
                startTime: patch.start,
                endTime: patch.end
            )
        }
        for create in diff.creates {
            _ = try await admin.createAvailabilityRule(
                workspaceId: workspaceId,
                eventTypeId: nil,
                dayOfWeek: create.dayOfWeek,
                startTime: create.start,
                endTime: create.end
            )
        }
    }
}
