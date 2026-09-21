import DistrictData
import DistrictModel
import Foundation

/// One bookable window on one day, while it is being edited.
///
/// ⚠️ `ruleId` nil MEANS "not stored yet". It is what separates a create from a
/// patch at save time, and it is why ``id`` is a separate local value: SwiftUI
/// needs a stable identity for a row that has no server id at all.
///
/// ⛔ `Draft` IN THE NAME IS LOAD-BEARING AND NOT DECORATION. `DistrictData` already
/// publishes a ``SchedulingHoursRange`` — the READ row, immutable, with a non-optional
/// `ruleId` — and a type of that name declared here would shadow it for the whole
/// app module and stop the working-hours SCREEN compiling against its own library.
/// The two are not the same value: a draft range can exist with no rule behind it,
/// which is exactly what the read row cannot express.
struct SchedulingHoursDraftRange: Identifiable, Equatable {
    let id = UUID()
    var ruleId: String?
    var start: String
    var end: String

    /// ⚠️ IDENTITY IS DELIBERATELY OUT OF EQUALITY. ``id`` is a local handle for
    /// the list, not part of what a window IS; leaving it in synthesised `==` would
    /// make two identical windows unequal and every diff assertion meaningless.
    static func == (lhs: SchedulingHoursDraftRange, rhs: SchedulingHoursDraftRange) -> Bool {
        lhs.ruleId == rhs.ruleId && lhs.start == rhs.start && lhs.end == rhs.end
    }
}

/// What one save has to send.
///
/// ⛔ THREE LISTS IN A FIXED ORDER — DELETES, THEN PATCHES, THEN CREATES — AND THE
/// ORDER IS NOT COSMETIC. The fork refuses overlapping windows on a day, so a
/// create issued before the delete it replaces is refused against a window that is
/// on its way out. The web runs the same three phases in the same order.
struct SchedulingHoursDiff: Equatable {
    var deletes: [String] = []
    var patches: [SchedulingHoursPatch] = []
    var creates: [SchedulingHoursCreate] = []

    var isEmpty: Bool {
        deletes.isEmpty && patches.isEmpty && creates.isEmpty
    }

    var count: Int {
        deletes.count + patches.count + creates.count
    }
}

struct SchedulingHoursPatch: Equatable {
    let id: String
    let dayOfWeek: Int
    let start: String
    let end: String
}

struct SchedulingHoursCreate: Equatable {
    let dayOfWeek: Int
    let start: String
    let end: String
}

/// The week model behind the working-hours editor: seven rows, Monday first.
///
/// ⛔ THE ROW ORDER AND THE WIRE ORDER DISAGREE BY ONE DAY, AND THAT IS THE SINGLE
/// EASIEST THING TO GET WRONG HERE. `day_of_week` is 0...6 with **0 = Sunday** (the
/// fork's own column, and `me.get`'s `week_start`); the editor reads Monday first
/// because that is a working week. It is also not `Calendar`'s `weekday`, which is
/// 1...7. Both conversions live here and nowhere else.
///
/// ⛔ ONLY GLOBAL RULES ARE EDITED. A rule with a non-nil `event_type_id` governs
/// ONE event type, and this editor is the tenancy's own week — so those rows are
/// skipped on the way in and never appear in a diff, which means they are never
/// rewritten and never deleted by a save here. A screen that folded them in would
/// silently promote one event type's hours to everybody's. Creates always send a
/// nil `event_type_id` for the same reason.
///
/// ⚠️ THE TIMES ARE WALL-CLOCK STRINGS IN THE MEMBER'S SCHEDULER TIMEZONE, not the
/// device's, and they are zero-padded. The fork refuses `9:00`.
enum SchedulingWorkingHours {
    static let dayCount = 7
    /// Monday…Friday, for "copy to all weekdays".
    static let weekdayRows = [0, 1, 2, 3, 4]
    static let defaultStart = "09:00"
    static let defaultEnd = "17:00"

    /// Row index (Monday = 0) to `day_of_week` (Sunday = 0).
    ///
    /// ⚠️ THE ARITHMETIC IS ``SchedulingHoursFormat``'s AND IS NOT RESTATED HERE.
    /// The library's pair carries the double modulo that keeps a negative index from
    /// landing on a real day, and one of two copies having that guard is worse than
    /// neither.
    static func wireDay(forRow row: Int) -> Int {
        SchedulingHoursFormat.wireDay(row)
    }

    /// `day_of_week` (Sunday = 0) to row index (Monday = 0).
    static func row(forWireDay day: Int) -> Int {
        SchedulingHoursFormat.displayDay(day)
    }

    /// ⚠️ FORMAT ONLY, AND NOT A CLOCK CHECK. `25:99` passes, exactly as it does in
    /// the browser: the fork is the validator, and a stricter client would refuse
    /// input the server accepts. What this catches is the shape that is refused for
    /// certain — a dropped leading zero.
    static func isWellFormedTime(_ value: String) -> Bool {
        guard value.count == 5 else { return false }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 2, parts[1].count == 2 else { return false }
        return parts.allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    /// The seven rows a stored rule list opens on.
    ///
    /// ⛔ THE GRID IS BUILT BY ``SchedulingHoursFormat/weekFromRules(_:)`` AND ONLY
    /// LIFTED INTO DRAFTS HERE. That function already drops event-type rules, already
    /// range-checks `day_of_week` on the WIRE value before the modulo folds it, and
    /// already sorts each day by start time — and it is what the read screen behind
    /// this editor renders. A second copy of it here would let the grid somebody
    /// edits disagree with the grid they were just looking at.
    static func week(from rules: [SchedulingAvailabilityRule]) -> [[SchedulingHoursDraftRange]] {
        SchedulingHoursFormat.weekFromRules(rules).map { day in
            day.map { SchedulingHoursDraftRange(ruleId: $0.ruleId, start: $0.start, end: $0.end) }
        }
    }

    /// One day's per-range complaints, or nil where a range is fine.
    ///
    /// ⚠️ AN OVERLAP IS REPORTED ON THE LATER RANGE BY CLOCK ORDER, not on the
    /// later one by position in the list. Reporting it on both would double every
    /// message; reporting it on the first would point at the window somebody had
    /// already decided about.
    static func errors(in ranges: [SchedulingHoursDraftRange]) -> [String?] {
        var errors = [String?](repeating: nil, count: ranges.count)
        for (index, range) in ranges.enumerated() {
            if !isWellFormedTime(range.start) || !isWellFormedTime(range.end) {
                errors[index] = SchedulingWriteCopy.timeFormatError
            } else if range.end <= range.start {
                errors[index] = SchedulingWriteCopy.timeOrderError
            }
        }
        let order = ranges.indices.sorted { ranges[$0].start < ranges[$1].start }
        for (position, index) in order.enumerated() where position > 0 && errors[index] == nil {
            let earlier = order[position - 1]
            guard errors[earlier] == nil else { continue }
            if ranges[index].start < ranges[earlier].end {
                errors[index] = SchedulingWriteCopy.timeOverlapError
            }
        }
        return errors
    }

    static func isValid(_ week: [[SchedulingHoursDraftRange]]) -> Bool {
        week.allSatisfy { errors(in: $0).allSatisfy { $0 == nil } }
    }

    /// What the draft week changed about the stored rules.
    ///
    /// ⛔ AN UNCHANGED WINDOW EMITS NOTHING. Re-sending it would spend a write from
    /// the workspace's hourly budget to store the value that is already there, and
    /// on seven days of two windows that is fourteen requests for a save that
    /// changed one of them.
    ///
    /// ⚠️ A ROW WHOSE `ruleId` IS NO LONGER ANYWHERE IN THE WEEK IS A DELETE, which
    /// is how "Remove" and "copy over a longer day" both reach the wire without
    /// either of them having to say so.
    static func diff(
        week: [[SchedulingHoursDraftRange]],
        stored: [SchedulingAvailabilityRule]
    ) -> SchedulingHoursDiff {
        let global = stored.filter { $0.eventTypeId == nil }
        var result = SchedulingHoursDiff()
        var surviving = Set<String>()

        for (row, ranges) in week.enumerated() {
            let day = wireDay(forRow: row)
            for range in ranges {
                guard let ruleId = range.ruleId else {
                    result.creates.append(
                        SchedulingHoursCreate(dayOfWeek: day, start: range.start, end: range.end)
                    )
                    continue
                }
                surviving.insert(ruleId)
                guard let before = global.first(where: { $0.id == ruleId }) else {
                    // ⚠️ A row carrying an id nothing stores is treated as NEW
                    // rather than dropped: the id came from somewhere, and losing
                    // the window would be a silent deletion of what is on screen.
                    result.creates.append(
                        SchedulingHoursCreate(dayOfWeek: day, start: range.start, end: range.end)
                    )
                    continue
                }
                if before.dayOfWeek != day || before.startTime != range.start || before.endTime != range.end {
                    result.patches.append(
                        SchedulingHoursPatch(id: ruleId, dayOfWeek: day, start: range.start, end: range.end)
                    )
                }
            }
        }
        result.deletes = global.map(\.id).filter { !surviving.contains($0) }
        return result
    }

    /// Copy one day's windows onto Monday…Friday.
    ///
    /// ⚠️ THE TARGET'S OWN RULE IDS ARE REUSED POSITIONALLY, which is what turns
    /// this into patches instead of a delete-and-recreate of the whole working
    /// week. A target with more windows than the source loses the extras, and they
    /// leave as deletes.
    static func copyToWeekdays(
        from row: Int,
        in week: [[SchedulingHoursDraftRange]]
    ) -> [[SchedulingHoursDraftRange]] {
        guard week.indices.contains(row) else { return week }
        let source = week[row]
        var copy = week
        for target in weekdayRows where target != row {
            copy[target] = source.enumerated().map { index, range in
                SchedulingHoursDraftRange(
                    ruleId: copy[target].indices.contains(index) ? copy[target][index].ruleId : nil,
                    start: range.start,
                    end: range.end
                )
            }
        }
        return copy
    }
}
