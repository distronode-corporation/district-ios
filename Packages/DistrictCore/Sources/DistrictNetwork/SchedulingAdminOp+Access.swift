import Foundation

/// The two District roles that can appear as a bar on a scheduling admin op.
///
/// ⚠️ `agency` IS ABSENT AND THAT IS NOT AN OMISSION. It clears both bars, so it
/// is never the MINIMUM for anything; the server's `roleClears` says the same in
/// the other direction. A third case here would be a value no op could hold.
public enum SchedulingAdminRole: String, Sendable, CaseIterable {
    case viewer
    case client
}

public extension SchedulingAdminOp {
    /// The lowest District role the server will accept this op from.
    ///
    /// ⛔ THE RULE IS "READS ARE `viewer`, WRITES ARE `client`" WITH EXACTLY ONE
    /// EXCEPTION, AND THE EXCEPTION IS NOT A RELAXATION. The `me.*` and
    /// `calendar.*` namespaces are `viewer` even when they WRITE, because they
    /// touch only the caller's own scheduler user: their display name, timezone,
    /// notification preferences, avatar and calendar connections. A viewer who
    /// cannot set their own timezone is offered every booking window in the wrong
    /// hours, and a viewer who cannot connect their own calendar cannot be booked
    /// at all — so the narrow rule would break the product for exactly the role it
    /// was meant to protect. Four viewer-level WRITES come out of that:
    /// ``meAvatarDelete``, ``mePatch``, ``calendarCaldavConnect`` and the three
    /// `calendar.connections.*` mutations.
    ///
    /// ⛔ THIS IS THE WEAKER HALF OF THE GATE AND MUST NOT BE READ AS THE ANSWER.
    /// The scheduler enforces its own `requireAdmin` on the settings, recordings,
    /// notes, transcript and reassign routes, and its own host-ownership checks on
    /// the booking routes — against the MEMBER's key, carrying the member's
    /// scheduler role. A District `viewer` calling a read this property allows can
    /// still come back **403**. What it is for is deciding whether to draw a
    /// control and whether to spend a request, not whether the answer will be yes.
    ///
    /// ⚠️ TWO EXHAUSTIVE ARMS, NO `default`. A case added without being classified
    /// fails to compile here, which is the only thing that keeps this in step with
    /// `ADMIN_OPS`; a `default` would silently hand a new op the wrong bar.
    var minRole: SchedulingAdminRole {
        switch self {
        case .meGet, .mePatch, .meAvatarDelete,
             .eventTypesList, .eventTypesGet, .eventTypesHostsGet,
             .eventTypesQuestionsList, .eventTypesSlots,
             .availabilityRulesList, .availabilityOverridesList,
             .bookingsList, .bookingsAnswers, .bookingsNotes, .bookingsTranscript,
             .calendarStatus, .calendarCaldavConnect,
             .calendarConnectionsCalendarsGet, .calendarConnectionsCalendarsPut,
             .calendarConnectionsDestination, .calendarConnectionsDelete, .zoomStatus,
             .usersList, .usersUpcomingBookings,
             .teamsList, .teamsGet,
             .recordingsList, .recordingsConsent,
             .settingsBrandingGet, .settingsStorageGet,
             .settingsNotetakerGet, .settingsLlmGet,
             .apiKeysList, .oauthConnectionsList,
             .webhooksList, .webhooksDeliveries:
            .viewer
        case .eventTypesCreate, .eventTypesPatch, .eventTypesDelete,
             .eventTypesHostsPut, .eventTypesTestEmail,
             .eventTypesQuestionsCreate, .eventTypesQuestionsPatch, .eventTypesQuestionsDelete,
             .availabilityRulesCreate, .availabilityRulesPatch, .availabilityRulesDelete,
             .availabilityOverridesCreate, .availabilityOverridesPatch,
             .availabilityOverridesDelete, .availabilityOverridesDeleteGroup,
             .bookingsCancel, .bookingsReschedule, .bookingsReassign, .bookingsNotesRegenerate,
             .usersArchive,
             .teamsCreate, .teamsPatch, .teamsDelete,
             .teamsMembersAdd, .teamsMembersPatch, .teamsMembersRemove,
             .recordingsDelete, .recordingsDeleteAll,
             .settingsBrandingPatch, .settingsBrandingLogoDelete, .settingsBrandingBannerDelete,
             .settingsStoragePatch, .settingsNotetakerPatch, .settingsLlmPatch,
             .apiKeysCreate, .apiKeysDelete, .oauthConnectionsDelete,
             .webhooksCreate, .webhooksPatch, .webhooksDelete:
            .client
        }
    }

    /// Whether sending this op spends a write from the workspace's hourly budget.
    ///
    /// ⛔ "NOT A GET", WHICH IS THE SERVER'S OWN TEST AND NOT A SEPARATE OPINION.
    /// The server route budgets `opSendsBody(op) || op.method === "DELETE"`, and
    /// `opSendsBody` is `method !== "GET" && method !== "DELETE"` — so the union is
    /// exactly "the method is not GET". Twenty-nine reads, forty-six writes.
    ///
    /// ⚠️ IT IS NOT `minRole == .client`, AND THE TWO DISAGREE ON SIX OPS. The four
    /// viewer-level writes described on ``minRole`` are writes billed to a
    /// SEPARATE 30-per-member-per-hour bucket rather than the workspace's 120,
    /// precisely so one viewer changing their avatar in a loop cannot lock every
    /// administrator out of writes for an hour. Reading this property off the role
    /// would put them back in the shared pool on the client's side of the wire.
    ///
    /// ⚠️ WHAT IT IS FOR HERE IS RESTRAINT, NOT PERMISSION. A budget exhausted
    /// answers **429**, which arrives as ``SchedulingAdminError/unavailable`` and
    /// says nothing about which bucket ran out. A caller that batches, retries or
    /// polls checks this before deciding to.
    var isWrite: Bool {
        switch self {
        case .meGet,
             .eventTypesList, .eventTypesGet, .eventTypesHostsGet,
             .eventTypesQuestionsList, .eventTypesSlots,
             .availabilityRulesList, .availabilityOverridesList,
             .bookingsList, .bookingsAnswers, .bookingsNotes, .bookingsTranscript,
             .calendarStatus, .calendarConnectionsCalendarsGet, .zoomStatus,
             .usersList, .usersUpcomingBookings,
             .teamsList, .teamsGet,
             .recordingsList, .recordingsConsent,
             .settingsBrandingGet, .settingsStorageGet,
             .settingsNotetakerGet, .settingsLlmGet,
             .apiKeysList, .oauthConnectionsList,
             .webhooksList, .webhooksDeliveries:
            false
        case .mePatch, .meAvatarDelete,
             .eventTypesCreate, .eventTypesPatch, .eventTypesDelete,
             .eventTypesHostsPut, .eventTypesTestEmail,
             .eventTypesQuestionsCreate, .eventTypesQuestionsPatch, .eventTypesQuestionsDelete,
             .availabilityRulesCreate, .availabilityRulesPatch, .availabilityRulesDelete,
             .availabilityOverridesCreate, .availabilityOverridesPatch,
             .availabilityOverridesDelete, .availabilityOverridesDeleteGroup,
             .bookingsCancel, .bookingsReschedule, .bookingsReassign, .bookingsNotesRegenerate,
             .calendarCaldavConnect, .calendarConnectionsCalendarsPut,
             .calendarConnectionsDestination, .calendarConnectionsDelete,
             .usersArchive,
             .teamsCreate, .teamsPatch, .teamsDelete,
             .teamsMembersAdd, .teamsMembersPatch, .teamsMembersRemove,
             .recordingsDelete, .recordingsDeleteAll,
             .settingsBrandingPatch, .settingsBrandingLogoDelete, .settingsBrandingBannerDelete,
             .settingsStoragePatch, .settingsNotetakerPatch, .settingsLlmPatch,
             .apiKeysCreate, .apiKeysDelete, .oauthConnectionsDelete,
             .webhooksCreate, .webhooksPatch, .webhooksDelete:
            true
        }
    }
}
