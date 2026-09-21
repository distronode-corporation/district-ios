import DistrictModel
import DistrictNetwork
import Foundation

// The nine `availability.*` ops, typed.
//
// ⛔ TWO SHAPES OF AVAILABILITY AND THEY ARE NOT LAYERS OF ONE THING. A RULE is a
// weekly window that repeats forever; an OVERRIDE is a dated exception to it.
// Reading one to answer a question about the other gives a plausible wrong answer —
// "is this member free on the 24th" is both, and neither op answers it alone.
// `eventTypes.slots` is the op that composes them, which is why it lives with the
// event types and not here.
//
// ⛔ THE PATH KEYS STAY IN THE BODY, for the reason
// `SchedulingAdminRepository+EventTypes.swift` states at length: the route
// validates the whole params object against a schema that REQUIRES them and strips
// them afterwards.

public extension SchedulingAdminRepository {
    // MARK: - Weekly rules

    /// `availability.rules.list` — the weekly windows.
    ///
    /// ⛔ AN `eventTypeId` FILTERS TO THAT EVENT TYPE'S OWN RULES AND DOES **NOT**
    /// INCLUDE THE GLOBAL ONES. A nil `event_type_id` on a row means "every event
    /// type" (see ``SchedulingAvailabilityRule``), so the rules that actually govern
    /// one event type are the filtered list UNIONED with the global ones — which is
    /// two calls, and is why this argument is not defaulted to a value that looks
    /// like it answers the question.
    func availabilityRules(
        workspaceId: String,
        eventTypeId: String? = nil
    ) async throws -> [SchedulingAvailabilityRule] {
        try await perform(
            .availabilityRulesList,
            workspaceId: workspaceId,
            params: .object([("event_type_id", .optional(eventTypeId))]),
            as: SchedulingItems<SchedulingAvailabilityRule>.self
        ).items
    }

    /// `availability.rules.create` — one new weekly window.
    ///
    /// ⚠️ A nil `eventTypeId` DROPS THE KEY, which the fork reads as the global
    /// rule. The schema is `.nullable().optional()`, so an explicit null and an
    /// absent key are the same instruction there; ``JSONValue/object(_:)`` drops
    /// nils, so this sends the absent spelling.
    ///
    /// - Parameters:
    ///   - dayOfWeek: 0...6, **Sunday first** — not `Calendar`'s 1...7 `weekday`.
    ///   - startTime: zero-padded `HH:MM`. The fork refuses `9:00`.
    ///   - endTime: zero-padded `HH:MM`.
    func createAvailabilityRule(
        workspaceId: String,
        eventTypeId: String?,
        dayOfWeek: Int,
        startTime: String,
        endTime: String
    ) async throws -> SchedulingAvailabilityRule {
        try await perform(
            .availabilityRulesCreate,
            workspaceId: workspaceId,
            params: .object([
                ("event_type_id", .optional(eventTypeId)),
                ("day_of_week", .integer(dayOfWeek)),
                ("start_time", .string(startTime)),
                ("end_time", .string(endTime)),
            ]),
            as: SchedulingAvailabilityRule.self
        )
    }

    /// `availability.rules.patch` — a sparse update of one weekly window.
    ///
    /// ⛔ `event_type_id` IS NOT PATCHABLE. The schema takes only the day and the
    /// two times, so moving a rule between event types means delete and create —
    /// and a UI that offered the move as an edit would be offering a 400 on a field
    /// the server never reads.
    func patchAvailabilityRule(
        workspaceId: String,
        id: String,
        dayOfWeek: Int? = nil,
        startTime: String? = nil,
        endTime: String? = nil
    ) async throws -> SchedulingAvailabilityRule {
        try await perform(
            .availabilityRulesPatch,
            workspaceId: workspaceId,
            params: .object([
                ("id", .string(id)),
                ("day_of_week", dayOfWeek.map(JSONValue.integer)),
                ("start_time", .optional(startTime)),
                ("end_time", .optional(endTime)),
            ]),
            as: SchedulingAvailabilityRule.self
        )
    }

    /// `availability.rules.delete` — removes one weekly window.
    func deleteAvailabilityRule(workspaceId: String, id: String) async throws {
        _ = try await perform(
            .availabilityRulesDelete,
            workspaceId: workspaceId,
            params: .object([("id", .string(id))]),
            as: SchedulingNoContent.self
        )
    }

    // MARK: - Dated overrides

    /// `availability.overrides.list` — every dated exception.
    ///
    /// ⚠️ IT TAKES NO PARAMS AT ALL: no date window, no event type. The whole list
    /// comes back and any narrowing is this side's job.
    func availabilityOverrides(workspaceId: String) async throws -> [SchedulingAvailabilityOverride] {
        try await perform(
            .availabilityOverridesList,
            workspaceId: workspaceId,
            params: .object([]),
            as: SchedulingItems<SchedulingAvailabilityOverride>.self
        ).items
    }

    /// `availability.overrides.create` — one dated exception, or a whole range.
    ///
    /// ⛔ THE ANSWER HAS TWO STRUCTURALLY DIFFERENT SHAPES AND THE DRAFT IS WHAT
    /// DECIDES WHICH. With ``SchedulingOverrideDraft/endDate`` set, the op answers a
    /// ``SchedulingOverrideGroup`` summary and no row; without it, a single row.
    /// That is what ``SchedulingOverrideCreated`` is, and a caller has to branch.
    func createAvailabilityOverride(
        workspaceId: String,
        draft: SchedulingOverrideDraft
    ) async throws -> SchedulingOverrideCreated {
        try await perform(
            .availabilityOverridesCreate,
            workspaceId: workspaceId,
            params: .object([
                ("date", .string(draft.date)),
                ("reason", .string(draft.reason)),
                ("end_date", .optional(draft.endDate)),
                ("start_time", .optional(draft.startTime)),
                ("end_time", .optional(draft.endTime)),
            ]),
            as: SchedulingOverrideCreated.self
        )
    }

    /// `availability.overrides.patch` — a sparse update of one dated exception.
    ///
    /// ⛔ THE DATE IS NOT PATCHABLE, and neither is the group. Moving an override to
    /// another day means delete and create; changing one day of a RANGE leaves the
    /// row's `group_id` in place, so the day is still deleted by
    /// ``deleteAvailabilityOverrideGroup(workspaceId:groupId:)``.
    ///
    /// - Parameter reason: `day_off`, `out_of_office` or `custom_hours`.
    func patchAvailabilityOverride(
        workspaceId: String,
        id: String,
        reason: String? = nil,
        startTime: String? = nil,
        endTime: String? = nil
    ) async throws -> SchedulingAvailabilityOverride {
        try await perform(
            .availabilityOverridesPatch,
            workspaceId: workspaceId,
            params: .object([
                ("id", .string(id)),
                ("reason", .optional(reason)),
                ("start_time", .optional(startTime)),
                ("end_time", .optional(endTime)),
            ]),
            as: SchedulingAvailabilityOverride.self
        )
    }

    /// `availability.overrides.delete` — removes ONE day.
    ///
    /// ⚠️ ON A ROW THAT CAME FROM A RANGE THIS LEAVES THE REST OF THE RANGE IN
    /// PLACE, which is usually not what "delete this holiday" means. Check
    /// ``SchedulingAvailabilityOverride/groupId`` first and offer the group delete
    /// when there is one.
    func deleteAvailabilityOverride(workspaceId: String, id: String) async throws {
        _ = try await perform(
            .availabilityOverridesDelete,
            workspaceId: workspaceId,
            params: .object([("id", .string(id))]),
            as: SchedulingNoContent.self
        )
    }

    /// `availability.overrides.deleteGroup` — removes every day of a range.
    ///
    /// ⛔ THE PARAM IS `groupId`, camelCase, ALONE IN THIS FAMILY. Every other key
    /// the scheduler ops take is snake_case; this one is spelled `groupId` in the
    /// catalog's schema and sending `group_id` is a 400. Copied from
    /// `admin-ops.ts`, not normalised.
    func deleteAvailabilityOverrideGroup(workspaceId: String, groupId: String) async throws {
        _ = try await perform(
            .availabilityOverridesDeleteGroup,
            workspaceId: workspaceId,
            params: .object([("groupId", .string(groupId))]),
            as: SchedulingNoContent.self
        )
    }
}
