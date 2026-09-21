import DistrictModel
import DistrictNetwork
import Foundation

// The thirteen `eventTypes.*` ops, typed.
//
// ⛔ THESE ARE SPELLINGS OF ``SchedulingAdminRepository/perform(_:workspaceId:params:as:)``
// AND NOT A SECOND CATALOG. The server owns the scheduler path, the HTTP verb and
// the params schema; what these methods add is the one thing `perform` cannot know
// and every caller would otherwise guess — WHICH RESPONSE TYPE GOES WITH WHICH OP.
// Naming the wrong type at a call site is a runtime
// ``SchedulingAdminError/decoding(_:)``, which is the cost `perform` pays for not
// duplicating 75 schemas; these close that gap for the two namespaces S1b ports
// without reopening the one `perform` avoids.
//
// ⛔ THE PATH KEYS STAY IN THE BODY. `slug` and `id` are BOTH the address and a
// required member of the op's params schema: the route validates the whole object
// and strips the path keys afterwards, so a client that removed one first gets a
// 400 naming the field it was being tidy about. Every method below puts them back.
// ⚠️ That is also why `slug` is a separate argument rather than a field on
// ``SchedulingEventTypeChanges`` — it addresses the row, it is not a change to it.
//
// ⚠️ A PATCH DROPS ITS nil PAIRS, WHICH IS "LEAVE ALONE" AND NOT "CLEAR".
// ``JSONValue/object(_:)`` drops a nil by design; none of these schemas is
// `.nullable()`, so there is no clear to express and the drop is the whole
// vocabulary.

public extension SchedulingAdminRepository {
    // MARK: - The event types themselves

    /// `eventTypes.list` — every event type in the tenancy, archived ones included.
    ///
    /// ⚠️ NOT FILTERED BY OWNER AND NOT FILTERED BY `is_active`. A member with the
    /// role for it sees the whole tenancy's list; ``SchedulingEventType/owned`` is
    /// what separates theirs from a colleague's, and it can be ABSENT.
    func listEventTypes(workspaceId: String) async throws -> [SchedulingEventType] {
        try await perform(
            .eventTypesList,
            workspaceId: workspaceId,
            params: .object([]),
            as: SchedulingItems<SchedulingEventType>.self
        ).items
    }

    /// `eventTypes.get` — one event type by its public slug.
    func eventType(workspaceId: String, slug: String) async throws -> SchedulingEventType {
        try await perform(
            .eventTypesGet,
            workspaceId: workspaceId,
            params: .object([("slug", .string(slug))]),
            as: SchedulingEventType.self
        )
    }

    /// `eventTypes.create` — a new event type, which answers the created row.
    func createEventType(
        workspaceId: String,
        draft: SchedulingEventTypeDraft
    ) async throws -> SchedulingEventType {
        try await perform(
            .eventTypesCreate,
            workspaceId: workspaceId,
            params: .object([
                ("slug", .string(draft.slug)),
                ("name", .string(draft.name)),
                ("duration_minutes", .integer(draft.durationMinutes)),
                ("description", .optional(draft.description)),
                ("slot_interval_minutes", draft.slotIntervalMinutes.map(JSONValue.integer)),
                ("location_type", .optional(draft.locationType)),
                ("location_value", .optional(draft.locationValue)),
                ("routing_mode", .optional(draft.routingMode)),
                ("buffer_before_minutes", draft.bufferBeforeMinutes.map(JSONValue.integer)),
                ("buffer_after_minutes", draft.bufferAfterMinutes.map(JSONValue.integer)),
                ("min_notice_minutes", draft.minNoticeMinutes.map(JSONValue.integer)),
                ("max_future_days", draft.maxFutureDays.map(JSONValue.integer)),
                ("max_active_bookings", draft.maxActiveBookings.map(JSONValue.integer)),
                ("show_taken_slots", draft.showTakenSlots.map(JSONValue.bool)),
            ]),
            as: SchedulingEventType.self
        )
    }

    /// `eventTypes.patch` — a sparse update, which answers the whole updated row.
    ///
    /// ⚠️ ARCHIVING IS HERE (`changes.archived`), NOT IN ``deleteEventType(workspaceId:slug:)``.
    func patchEventType(
        workspaceId: String,
        slug: String,
        changes: SchedulingEventTypeChanges
    ) async throws -> SchedulingEventType {
        try await perform(
            .eventTypesPatch,
            workspaceId: workspaceId,
            params: .object(Self.pairs(forSlug: slug, changes: changes)),
            as: SchedulingEventType.self
        )
    }

    /// `eventTypes.delete` — removes the row.
    ///
    /// ⛔ NOT THE SAME AS ARCHIVING, and the difference is the bookings. Patch
    /// `archived: true` to hide an event type while its history stays addressable.
    func deleteEventType(workspaceId: String, slug: String) async throws {
        _ = try await perform(
            .eventTypesDelete,
            workspaceId: workspaceId,
            params: .object([("slug", .string(slug))]),
            as: SchedulingNoContent.self
        )
    }

    // MARK: - Hosts

    /// `eventTypes.hosts.get` — who can be booked on this event type.
    func eventTypeHosts(workspaceId: String, slug: String) async throws -> [SchedulingHost] {
        try await perform(
            .eventTypesHostsGet,
            workspaceId: workspaceId,
            params: .object([("slug", .string(slug))]),
            as: SchedulingItems<SchedulingHost>.self
        ).items
    }

    /// `eventTypes.hosts.put` — REPLACES the host list, and answers the new one.
    ///
    /// ⛔ A FULL REPLACEMENT. Sending one host removes the others, and the schema
    /// refuses an empty array — see ``SchedulingHostAssignment``.
    ///
    /// ⚠️ THE ANSWER IS THE LIST, NOT AN ECHO AND NOT A 204: the handler
    /// re-dispatches into the read, so the rows come back with the `name`, `email`
    /// and `avatar_url` the request never carried.
    func putEventTypeHosts(
        workspaceId: String,
        slug: String,
        hosts: [SchedulingHostAssignment]
    ) async throws -> [SchedulingHost] {
        try await perform(
            .eventTypesHostsPut,
            workspaceId: workspaceId,
            params: .object([
                ("slug", .string(slug)),
                ("hosts", .array(hosts.map { host in
                    .object([
                        ("user_id", .string(host.userId)),
                        ("role", .string(host.role)),
                        ("priority", .integer(host.priority)),
                    ])
                })),
            ]),
            as: SchedulingItems<SchedulingHost>.self
        ).items
    }

    /// `eventTypes.testEmail` — sends one of the four templates to the CALLER.
    ///
    /// ⛔ THERE IS NO RECIPIENT ARGUMENT AND THAT IS THE DESIGN. The fork addresses
    /// the calling member's own scheduler address; a recipient parameter would make
    /// this op a mail relay addressable by anyone holding a key for it.
    ///
    /// - Parameter type: `confirmation`, `cancellation`, `reschedule` or `reminder`.
    func sendEventTypeTestEmail(
        workspaceId: String,
        slug: String,
        type: String
    ) async throws -> SchedulingTestEmailResult {
        try await perform(
            .eventTypesTestEmail,
            workspaceId: workspaceId,
            params: .object([("slug", .string(slug)), ("type", .string(type))]),
            as: SchedulingTestEmailResult.self
        )
    }

    // MARK: - Booking questions

    /// `eventTypes.questions.list` — the ADMIN list.
    ///
    /// ⚠️ IT HITS THE `/admin` SIBLING, which skips the `is_active` / `is_public`
    /// filters the public endpoint applies — an event type being edited is usually
    /// neither, so the public list would answer empty for exactly the row on screen.
    func eventTypeQuestions(workspaceId: String, slug: String) async throws -> [SchedulingQuestion] {
        try await perform(
            .eventTypesQuestionsList,
            workspaceId: workspaceId,
            params: .object([("slug", .string(slug))]),
            as: SchedulingItems<SchedulingQuestion>.self
        ).items
    }

    /// `eventTypes.questions.create` — one new question on the booking form.
    func createEventTypeQuestion(
        workspaceId: String,
        slug: String,
        draft: SchedulingQuestionDraft
    ) async throws -> SchedulingQuestion {
        try await perform(
            .eventTypesQuestionsCreate,
            workspaceId: workspaceId,
            params: .object([
                ("slug", .string(slug)),
                ("label", .string(draft.label)),
                ("type", .string(draft.type)),
                ("required", .bool(draft.required)),
                ("options", draft.options.map { .array($0.map(JSONValue.string)) }),
                ("position", draft.position.map(JSONValue.integer)),
            ]),
            as: SchedulingQuestion.self
        )
    }

    /// `eventTypes.questions.patch` — a sparse update of one question.
    ///
    /// ⚠️ TWO PATH KEYS, AND BOTH STAY IN THE BODY. The question is addressed by the
    /// event type's `slug` AND its own `id`.
    func patchEventTypeQuestion(
        workspaceId: String,
        slug: String,
        id: String,
        changes: SchedulingQuestionChanges
    ) async throws -> SchedulingQuestion {
        try await perform(
            .eventTypesQuestionsPatch,
            workspaceId: workspaceId,
            params: .object([
                ("slug", .string(slug)),
                ("id", .string(id)),
                ("label", .optional(changes.label)),
                ("type", .optional(changes.type)),
                ("options", changes.options.map { .array($0.map(JSONValue.string)) }),
                ("required", changes.required.map(JSONValue.bool)),
                ("position", changes.position.map(JSONValue.integer)),
            ]),
            as: SchedulingQuestion.self
        )
    }

    /// `eventTypes.questions.delete` — removes one question.
    func deleteEventTypeQuestion(workspaceId: String, slug: String, id: String) async throws {
        _ = try await perform(
            .eventTypesQuestionsDelete,
            workspaceId: workspaceId,
            params: .object([("slug", .string(slug)), ("id", .string(id))]),
            as: SchedulingNoContent.self
        )
    }

    // MARK: - Slots

    /// `eventTypes.slots` — the bookable windows, as the booking page computes them.
    ///
    /// ⚠️ EVERY ARGUMENT AFTER THE SLUG IS OPTIONAL AND THE FORK PICKS ITS OWN
    /// DEFAULTS when they are dropped. ⛔ `tz` is the zone the windows are RETURNED
    /// in; leaving it nil does not mean "the device's zone", it means whatever the
    /// scheduler decides, so a screen that renders the result as local time without
    /// having asked for it is guessing.
    ///
    /// - Parameters:
    ///   - from: `YYYY-MM-DD`. The fork refuses any other spelling.
    ///   - to: `YYYY-MM-DD`.
    func eventTypeSlots(
        workspaceId: String,
        slug: String,
        from: String? = nil,
        to: String? = nil,
        tz: String? = nil
    ) async throws -> SchedulingSlots {
        try await perform(
            .eventTypesSlots,
            workspaceId: workspaceId,
            params: .object([
                ("slug", .string(slug)),
                ("from", .optional(from)),
                ("to", .optional(to)),
                ("tz", .optional(tz)),
            ]),
            as: SchedulingSlots.self
        )
    }

    // MARK: - The patch body, which is too wide to read inline

    /// ⚠️ A `static` HELPER RATHER THAN AN EXTRA METHOD ON THE CHANGES TYPE,
    /// because building a body is this layer's job: ``SchedulingEventTypeChanges``
    /// belongs to the caller and knows nothing about `JSONValue` or about the path
    /// key it is being merged with.
    private static func pairs(
        forSlug slug: String,
        changes: SchedulingEventTypeChanges
    ) -> [(String, JSONValue?)] {
        [
            ("slug", .string(slug)),
            ("name", .optional(changes.name)),
            ("description", .optional(changes.description)),
            ("duration_minutes", changes.durationMinutes.map(JSONValue.integer)),
            ("slot_interval_minutes", changes.slotIntervalMinutes.map(JSONValue.integer)),
            ("location_type", .optional(changes.locationType)),
            ("location_value", .optional(changes.locationValue)),
            ("routing_mode", .optional(changes.routingMode)),
            ("rr_strategy", .optional(changes.rrStrategy)),
            ("buffer_before_minutes", changes.bufferBeforeMinutes.map(JSONValue.integer)),
            ("buffer_after_minutes", changes.bufferAfterMinutes.map(JSONValue.integer)),
            ("min_notice_minutes", changes.minNoticeMinutes.map(JSONValue.integer)),
            ("max_future_days", changes.maxFutureDays.map(JSONValue.integer)),
            ("max_active_bookings", changes.maxActiveBookings.map(JSONValue.integer)),
            ("is_active", changes.isActive.map(JSONValue.bool)),
            ("is_public", changes.isPublic.map(JSONValue.bool)),
            ("show_taken_slots", changes.showTakenSlots.map(JSONValue.bool)),
            ("archived", changes.archived.map(JSONValue.bool)),
            ("msg_confirmation", .optional(changes.msgConfirmation)),
            ("msg_cancellation", .optional(changes.msgCancellation)),
            ("msg_reschedule", .optional(changes.msgReschedule)),
            ("msg_reminder", .optional(changes.msgReminder)),
            ("msg_greeting", .optional(changes.msgGreeting)),
            ("subj_confirmation", .optional(changes.subjConfirmation)),
            ("subj_cancellation", .optional(changes.subjCancellation)),
            ("subj_reschedule", .optional(changes.subjReschedule)),
            ("subj_reminder", .optional(changes.subjReminder)),
            ("reminders", changes.reminders.map { .array($0.map(JSONValue.integer)) }),
        ]
    }
}
