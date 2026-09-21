import DistrictModel
import Foundation

/// One bookable window on one day of the week.
///
/// ⚠️ IT CARRIES THE RULE'S ID EVEN THOUGH NOTHING READ-ONLY NEEDS ONE. The row's
/// identity is part of what was read, not part of what a form does with it, and the
/// write stage diffs the edited week against the loaded rules BY ID
/// (`working-hours.ts`'s `diffWeek`). Dropping it here would mean re-reading the rules
/// to save them. ⛔ What is deliberately NOT here is the source's `key` field: that is a
/// React list key minted from a module-global counter, which is draft state and belongs
/// with the editor.
public struct SchedulingHoursRange: Equatable, Sendable {
    /// Zero-padded `HH:MM`, as stored. ⛔ Render it through
    /// ``SchedulingOverviewSummary/displayTime(_:)``; never save that result.
    public let start: String
    public let end: String
    public let ruleId: String

    public init(start: String, end: String, ruleId: String) {
        self.start = start
        self.end = end
        self.ruleId = ruleId
    }
}

/// One row of the date-overrides table: a single day, or a whole span folded into one.
///
/// ⛔ A SPAN IS ONE ROW AND ITS `days` IS A COUNT OF ROWS, NOT A CALENDAR LENGTH. The
/// fork stores a multi-day absence as one override row PER DAY sharing a `group_id`, so
/// a fortnight off is fourteen rows; folding them is what stops the table being unusable.
/// ⚠️ `days` therefore counts what came back — a group with a gap in it reports the
/// number of stored days and not the distance between its ends, which is the truth about
/// the data and is what the source computes.
public struct SchedulingOverrideRow: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case single
        case group
    }

    /// ⚠️ `id:<row id>` or `group:<group id>`. Prefixed because the two namespaces are
    /// the fork's and nothing promises they cannot collide.
    public let key: String
    public let kind: Kind
    /// The id a delete would name: the row's for a single, the group's for a span.
    public let target: String
    public let start: String
    public let end: String
    public let days: Int
    public let isAvailable: Bool
    public let reason: String
    public let startTime: String?
    public let endTime: String?

    /// ⚠️ PUBLIC SO A TEST CAN DRIVE ``SchedulingHoursFormat/overrideHours(_:)`` DIRECTLY,
    /// which is the only way to reach its four branches without inventing four different
    /// override payloads to fold first. Production builds these through
    /// ``SchedulingHoursFormat/upcomingOverrides(_:today:)`` and nowhere else.
    public init(
        key: String,
        kind: Kind,
        target: String,
        start: String,
        end: String,
        days: Int,
        isAvailable: Bool,
        reason: String,
        startTime: String?,
        endTime: String?
    ) {
        self.key = key
        self.kind = kind
        self.target = target
        self.start = start
        self.end = end
        self.days = days
        self.isAvailable = isAvailable
        self.reason = reason
        self.startTime = startTime
        self.endTime = endTime
    }
}

/// The working-hours screen's read half, ported from `working-hours.ts`.
///
/// ⚠️ ONLY THE READ HALF IS HERE, DELIBERATELY. The source also carries `dayErrors`,
/// `diffWeek`, `copyToWeekdays`, `overrideDraftError` and `overrideCreateParams`, every
/// one of which exists to validate or encode an EDIT. Porting them now would be
/// uncallable code on a screen with no form, and this package's coverage gate would then
/// demand tests for behaviour the app cannot reach. They are the write stage's, and the
/// seam is named on ``SchedulingHoursModel``.
public enum SchedulingHoursFormat {
    /// ⚠️ Monday first, matching the grid the web draws. The wire is Sunday-first; see
    /// ``wireDay(_:)``.
    public static let weekDayNames = [
        "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday",
    ]

    /// Display index (0 = Monday) to wire `day_of_week` (0 = Sunday).
    ///
    /// ⚠️ THE DOUBLE MODULO IS FOR NEGATIVES, WHICH SWIFT AND JAVASCRIPT DISAGREE ABOUT.
    /// Both languages' `%` returns a negative result for a negative left operand, and the
    /// source never sees one because its only caller is a `forEach` index; writing it
    /// total here costs one operation and means a caller cannot produce an array index of
    /// `-1`, which in Swift is a crash rather than `undefined`.
    public static func wireDay(_ displayIndex: Int) -> Int {
        ((displayIndex + 1) % 7 + 7) % 7
    }

    /// Wire `day_of_week` (0 = Sunday) to display index (0 = Monday).
    public static func displayDay(_ dayOfWeek: Int) -> Int {
        ((dayOfWeek % 7) + 6 + 7) % 7
    }

    /// The seven days, Monday first, each sorted by start time.
    ///
    /// ⛔ WORKSPACE-WIDE RULES ONLY, the same exclusion
    /// ``SchedulingOverviewSummary/summarizeWorkingHours(_:)`` makes and for the same
    /// reason: a rule carrying an `eventTypeId` is that event type's override, not the
    /// operator's working week, and drawing it in this grid would invite an edit that
    /// silently rewrote one event type's availability.
    ///
    /// ⚠️ THE RANGE CHECK IS ON THE **WIRE** VALUE, BEFORE THE MODULO. A guard placed
    /// after ``displayDay(_:)`` could never fire, because the modulo has already folded
    /// every integer into 0...6 — so a corrupt `day_of_week` of `9` would silently land
    /// on a real day. The source checks in the same place, and the comment is here
    /// because the dead-guard version looks more careful and is not.
    public static func weekFromRules(_ rules: [SchedulingAvailabilityRule]) -> [[SchedulingHoursRange]] {
        var week: [[SchedulingHoursRange]] = Array(repeating: [], count: 7)
        for rule in rules where rule.eventTypeId == nil {
            guard rule.dayOfWeek >= 0, rule.dayOfWeek <= 6 else { continue }
            week[displayDay(rule.dayOfWeek)].append(
                SchedulingHoursRange(start: rule.startTime, end: rule.endTime, ruleId: rule.id)
            )
        }
        return week.map { $0.sorted { $0.start < $1.start } }
    }

    /// `2026-09-12` → `Sep 12, 2026`.
    ///
    /// ⛔ FORMATTED FROM THE STRING AND NEVER THROUGH A `Date`. A bare `YYYY-MM-DD` has
    /// no zone, so parsing it into an instant and formatting it back lands a day early
    /// for anybody west of UTC — which is the single most common date bug on a surface
    /// like this one. ⚠️ Anything that is not three dash-separated numeric groups, or
    /// whose month is outside 1...12, comes back UNCHANGED: it is still the truth, and
    /// rewriting it would hide a corrupt row.
    public static func formatOverrideDate(_ value: String) -> String {
        let pieces = value.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces[0].count == 4, pieces[1].count == 2, pieces[2].count == 2,
              let year = Int(pieces[0]), year >= 0,
              let month = Int(pieces[1]), let day = Int(pieces[2]),
              let name = SchedulingClock.monthName(month)
        else { return value }
        return "\(name) \(day), \(year)"
    }

    /// `Sep 12, 2026`, `Sep 12 to Sep 14, 2026`, or both years when they differ.
    ///
    /// ⚠️ THE FIRST YEAR IS DROPPED ONLY WHEN BOTH ENDS SHARE ONE, which is the source's
    /// behaviour and reads correctly: a span inside one year says the year once, at the
    /// end, and a span across New Year says it twice because it has to.
    public static func formatOverrideDates(start: String, end: String) -> String {
        if start == end {
            return formatOverrideDate(start)
        }
        guard start.prefix(4) == end.prefix(4) else {
            return "\(formatOverrideDate(start)) to \(formatOverrideDate(end))"
        }
        let from = formatOverrideDate(start)
        // ⚠️ THE YEAR IS STRIPPED ONLY IF IT IS THERE. `formatOverrideDate` returns the
        // input unchanged for a malformed date, and that value has no `, YYYY` tail to
        // remove — so this must not assume the shape it just asked for.
        let trimmed = from.hasSuffix(", \(start.prefix(4))")
            ? String(from.dropLast(6))
            : from
        return "\(trimmed) to \(formatOverrideDate(end))"
    }

    /// `9:00 to 12:00`, `Out of office`, or `Unavailable`.
    ///
    /// ⚠️ THE TWO UNAVAILABLE WORDINGS ARE CHOSEN BY THE STORED `reason` AND NOT BY THE
    /// OPERATOR. `out_of_office` is a value the fork writes; any other reason on an
    /// unavailable row reads "Unavailable", including the empty string.
    public static func overrideHours(_ row: SchedulingOverrideRow) -> String {
        // ⚠️ THE TWO OPTIONALS ARE COALESCED BEFORE THE TEST rather than unwrapped inside
        // it. An absent time and an empty one mean the same thing here, and the combined
        // condition is what keeps this a single-line `if` — `swiftformat` wraps a
        // multi-line one's brace onto its own line and `swiftlint` then rejects that, so
        // the two tools can only both pass if the condition stays short.
        let start = row.startTime ?? ""
        let end = row.endTime ?? ""
        if row.isAvailable, !start.isEmpty, !end.isEmpty {
            let show = SchedulingOverviewSummary.displayTime
            return "\(show(start)) to \(show(end))"
        }
        return row.reason == "out_of_office" ? "Out of office" : "Unavailable"
    }

    /// `2026-09-12` for today, in the operator's own zone.
    ///
    /// ⚠️ THE YEAR IS NOT ZERO-PADDED AND THE MONTH AND DAY ARE, matching the source. It
    /// only ever feeds the string comparison in ``upcomingOverrides(_:today:)``, where
    /// both sides are built the same way.
    public static func todayInZone(_ zone: String, now: Date = Date()) -> String {
        let parts = SchedulingClock.parts(of: now, timezone: zone)
        let pad = SchedulingClock.paddedTwo
        return "\(parts.year)-\(pad(parts.month))-\(pad(parts.day))"
    }

    /// Every override that has not finished, oldest start first, with spans folded.
    ///
    /// ⛔ A SPAN TAKES ITS REASON AND HOURS FROM THE **FIRST** ROW SEEN FOR ITS GROUP,
    /// and later rows only widen the ends and increment the count. That is the source's
    /// behaviour rather than a chosen one, and it matters because the fork does not
    /// promise the rows arrive in date order — so the reason shown is the reason of
    /// whichever day came back first, which for a group the fork wrote in one statement
    /// is the same on every row anyway.
    ///
    /// ⚠️ A SPAN THAT STARTED IN THE PAST AND ENDS LATER IS KEPT. The filter is on `end`,
    /// not on `start`: somebody four days into a fortnight off still needs to see it.
    ///
    /// ⚠️ STRING COMPARISON, NOT DATE COMPARISON, AND IT IS CORRECT BECAUSE THE FORMAT
    /// IS FIXED-WIDTH ISO. `2026-09-12` sorts identically as text and as a date, which is
    /// the whole reason the fork stores it that way; a `Date` round trip here would
    /// reintroduce the zone bug ``formatOverrideDate(_:)`` avoids.
    public static func upcomingOverrides(
        _ overrides: [SchedulingAvailabilityOverride],
        today: String
    ) -> [SchedulingOverrideRow] {
        var rows: [SchedulingOverrideRow] = []
        var groupIndex: [String: Int] = [:]

        for item in overrides {
            guard let groupId = item.groupId, !groupId.isEmpty else {
                rows.append(SchedulingOverrideRow(
                    key: "id:\(item.id)",
                    kind: .single,
                    target: item.id,
                    start: item.date,
                    end: item.date,
                    days: 1,
                    isAvailable: item.isAvailable,
                    reason: item.reason,
                    startTime: item.startTime,
                    endTime: item.endTime
                ))
                continue
            }
            guard let existing = groupIndex[groupId] else {
                groupIndex[groupId] = rows.count
                rows.append(SchedulingOverrideRow(
                    key: "group:\(groupId)",
                    kind: .group,
                    target: groupId,
                    start: item.date,
                    end: item.date,
                    days: 1,
                    isAvailable: item.isAvailable,
                    reason: item.reason,
                    startTime: item.startTime,
                    endTime: item.endTime
                ))
                continue
            }
            let row = rows[existing]
            rows[existing] = SchedulingOverrideRow(
                key: row.key,
                kind: row.kind,
                target: row.target,
                start: min(row.start, item.date),
                end: max(row.end, item.date),
                days: row.days + 1,
                isAvailable: row.isAvailable,
                reason: row.reason,
                startTime: row.startTime,
                endTime: row.endTime
            )
        }

        // ⛔ DECORATED WITH ITS POSITION BECAUSE `sorted(by:)` IS NOT STABLE AND
        // `Array.prototype.sort` IS. Two overrides starting on the same date are ordered
        // by the fork's own row order on the web, and Swift's introsort is free to swap
        // them — so a screen and a browser side by side would list the same two days in
        // different orders, intermittently, which is the worst kind of difference to be
        // asked about. The index tiebreak makes the port match by construction.
        return rows
            .filter { $0.end >= today }
            .enumerated()
            .sorted { left, right in
                left.element.start == right.element.start
                    ? left.offset < right.offset
                    : left.element.start < right.element.start
            }
            .map(\.element)
    }
}
