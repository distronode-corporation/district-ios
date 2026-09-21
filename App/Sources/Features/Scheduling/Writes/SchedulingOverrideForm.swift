import DistrictData
import Foundation

/// The "add an override" form.
///
/// ⛔ TWO KINDS, AND THE KIND DECIDES WHICH FIELDS EXIST AT ALL. `day_off` may
/// span a RANGE and carries no times; `custom_hours` is one day and carries both.
/// The fork refuses a range of custom hours, which is why the last-day field is
/// not merely ignored for that kind but not offered — and why ``params()`` drops a
/// leftover `endDate` rather than sending one the far end will refuse.
///
/// ⛔ AND THE RANGE CHANGES WHAT COMES BACK. With `end_date` the op answers a
/// ``SchedulingOverrideGroup`` summary and no row at all; without it, one row.
/// That is ``SchedulingOverrideCreated``, and a caller has to branch — which is
/// why this form, not the response, is documented as the thing that decides.
struct SchedulingOverrideForm: Equatable {
    /// `day_off` or `custom_hours`. ⚠️ `out_of_office` is read-only on both
    /// clients — see ``SchedulingWriteCopy/overrideKinds``.
    var reason = "day_off"
    /// `YYYY-MM-DD`.
    var date = ""
    /// `YYYY-MM-DD`, and only for `day_off`.
    var endDate = ""
    var start = SchedulingWorkingHours.defaultStart
    var end = SchedulingWorkingHours.defaultEnd

    var isCustomHours: Bool {
        reason == "custom_hours"
    }

    /// ⚠️ FORMAT ONLY. The fork decides whether the date is real; what this catches
    /// is an empty field and a shape that is refused for certain.
    static func isWellFormedDate(_ value: String) -> Bool {
        guard value.count == 10 else { return false }
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2 else {
            return false
        }
        return parts.allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    var error: String? {
        guard Self.isWellFormedDate(date) else { return SchedulingWriteCopy.overrideDateMissing }
        if isCustomHours {
            guard SchedulingWorkingHours.isWellFormedTime(start),
                  SchedulingWorkingHours.isWellFormedTime(end)
            else {
                return SchedulingWriteCopy.timeFormatError
            }
            return end <= start ? SchedulingWriteCopy.timeOrderError : nil
        }
        if !endDate.isEmpty {
            guard Self.isWellFormedDate(endDate) else { return SchedulingWriteCopy.overrideDateMissing }
            if endDate < date {
                return SchedulingWriteCopy.overrideEndBeforeStart
            }
        }
        return nil
    }

    /// The draft the create op takes, or nil when the form is refused.
    ///
    /// ⚠️ `end_date` IS DROPPED WHEN IT EQUALS THE START, as on the web: a one-day
    /// "range" is a single override, and sending it as a range would answer a group
    /// summary of one day and give that day a `group_id` for no reason.
    func draft() -> SchedulingOverrideDraft? {
        guard error == nil else { return nil }
        var draft = SchedulingOverrideDraft(date: date, reason: reason)
        if isCustomHours {
            draft.startTime = start
            draft.endTime = end
            return draft
        }
        if !endDate.isEmpty, endDate != date {
            draft.endDate = endDate
        }
        return draft
    }
}
