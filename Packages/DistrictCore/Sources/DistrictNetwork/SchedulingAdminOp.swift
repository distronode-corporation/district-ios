import Foundation

/// Every operation the native scheduling admin may ask `POST
/// /api/district/scheduling/admin` to perform, named once.
///
/// ⛔ AN ALLOWLIST, NOT A PROXY, AND THE RAW VALUE IS THE WHOLE ADDRESS. The route
/// takes an `op` NAME and never a path, so a caller cannot reach a scheduler route
/// the server's catalog does not name. The server's op catalog (`admin-ops`)
/// records what that excludes and why — `/v1/settings/{google,email,zoom,livekit,
/// stripe,tracking}` hold INSTANCE credentials shared by every tenancy,
/// `/v1/platform/*` can create and delete any tenancy at all, and
/// `PATCH /v1/users/{id}/role` plus `POST /v1/users/{id}/transfer-ownership` would
/// let a member re-arrange who owns the tenancy behind District's back. This enum
/// is the iOS half of that closure: the same property ``EndpointID`` gives the
/// route surface, one level down.
///
/// ⚠️ THE RAW VALUES ARE THE SERVER'S KEYS VERBATIM, DOTS AND ALL, and the case
/// names are their camelCase transliteration. A key renamed on the server is a
/// **400 `unknown_op`** here, not a compile error, so `SchedulingAdminOpTests`
/// embeds all 75 strings a second time rather than deriving them from
/// `allCases` — a test that re-reads the enum would assert that the code equals
/// itself and would pass through any rename.
///
/// ⚠️ SEVENTY-FIVE, COUNTED FROM `ADMIN_OPS` RATHER THAN ASSUMED. The split is
/// 35 `viewer` / 40 `client` and 29 reads / 46 writes; both are asserted, and
/// neither is derivable from the other (the `me.*` and `calendar.*` namespaces
/// are `viewer` even when they write — see ``minRole``).
///
/// ⛔ THIS IS A NAME, NOT A REQUEST. Nothing here carries the scheduler path, the
/// HTTP verb or the params schema: all three live on the server, which is what
/// makes the catalog a boundary rather than a duplicated client. The one thing
/// this side needs to know locally is who may send an op and whether sending it
/// spends the workspace's write budget, and that is exactly what this type
/// exposes.
public enum SchedulingAdminOp: String, CaseIterable, Sendable {
    // ── Self ────────────────────────────────────────────────────────────────
    case meGet = "me.get"
    case mePatch = "me.patch"
    case meAvatarDelete = "me.avatar.delete"

    // ── Event types ─────────────────────────────────────────────────────────
    case eventTypesList = "eventTypes.list"
    case eventTypesGet = "eventTypes.get"
    case eventTypesCreate = "eventTypes.create"
    case eventTypesPatch = "eventTypes.patch"
    case eventTypesDelete = "eventTypes.delete"
    case eventTypesHostsGet = "eventTypes.hosts.get"
    case eventTypesHostsPut = "eventTypes.hosts.put"
    case eventTypesTestEmail = "eventTypes.testEmail"
    case eventTypesQuestionsList = "eventTypes.questions.list"
    case eventTypesQuestionsCreate = "eventTypes.questions.create"
    case eventTypesQuestionsPatch = "eventTypes.questions.patch"
    case eventTypesQuestionsDelete = "eventTypes.questions.delete"
    case eventTypesSlots = "eventTypes.slots"

    // ── Availability: weekly rules, and dated overrides ──────────────────────
    case availabilityRulesList = "availability.rules.list"
    case availabilityRulesCreate = "availability.rules.create"
    case availabilityRulesPatch = "availability.rules.patch"
    case availabilityRulesDelete = "availability.rules.delete"
    case availabilityOverridesList = "availability.overrides.list"
    case availabilityOverridesCreate = "availability.overrides.create"
    case availabilityOverridesPatch = "availability.overrides.patch"
    case availabilityOverridesDelete = "availability.overrides.delete"
    case availabilityOverridesDeleteGroup = "availability.overrides.deleteGroup"

    // ── Bookings ────────────────────────────────────────────────────────────
    case bookingsList = "bookings.list"
    case bookingsAnswers = "bookings.answers"
    case bookingsCancel = "bookings.cancel"
    case bookingsReschedule = "bookings.reschedule"
    case bookingsReassign = "bookings.reassign"
    case bookingsNotes = "bookings.notes"
    case bookingsNotesRegenerate = "bookings.notes.regenerate"
    case bookingsTranscript = "bookings.transcript"

    // ── The caller's own calendars ──────────────────────────────────────────
    case calendarStatus = "calendar.status"
    case calendarCaldavConnect = "calendar.caldav.connect"
    case calendarConnectionsCalendarsGet = "calendar.connections.calendars.get"
    case calendarConnectionsCalendarsPut = "calendar.connections.calendars.put"
    case calendarConnectionsDestination = "calendar.connections.destination"
    case calendarConnectionsDelete = "calendar.connections.delete"
    case zoomStatus = "zoom.status"

    // ── The tenancy's scheduler users ───────────────────────────────────────
    case usersList = "users.list"
    case usersArchive = "users.archive"
    case usersUpcomingBookings = "users.upcomingBookings"

    // ── Teams ───────────────────────────────────────────────────────────────
    case teamsList = "teams.list"
    case teamsGet = "teams.get"
    case teamsCreate = "teams.create"
    case teamsPatch = "teams.patch"
    case teamsDelete = "teams.delete"
    case teamsMembersAdd = "teams.members.add"
    case teamsMembersPatch = "teams.members.patch"
    case teamsMembersRemove = "teams.members.remove"

    // ── Recordings ──────────────────────────────────────────────────────────
    case recordingsList = "recordings.list"
    case recordingsDelete = "recordings.delete"
    case recordingsDeleteAll = "recordings.deleteAll"
    case recordingsConsent = "recordings.consent"

    // ── Settings ────────────────────────────────────────────────────────────
    case settingsBrandingGet = "settings.branding.get"
    case settingsBrandingPatch = "settings.branding.patch"
    case settingsBrandingLogoDelete = "settings.branding.logo.delete"
    case settingsBrandingBannerDelete = "settings.branding.banner.delete"
    case settingsStorageGet = "settings.storage.get"
    case settingsStoragePatch = "settings.storage.patch"
    case settingsNotetakerGet = "settings.notetaker.get"
    case settingsNotetakerPatch = "settings.notetaker.patch"
    case settingsLlmGet = "settings.llm.get"
    case settingsLlmPatch = "settings.llm.patch"

    // ── Integrations the tenancy owns ───────────────────────────────────────
    case apiKeysList = "apiKeys.list"
    case apiKeysCreate = "apiKeys.create"
    case apiKeysDelete = "apiKeys.delete"
    case oauthConnectionsList = "oauth.connections.list"
    case oauthConnectionsDelete = "oauth.connections.delete"
    case webhooksList = "webhooks.list"
    case webhooksCreate = "webhooks.create"
    case webhooksPatch = "webhooks.patch"
    case webhooksDelete = "webhooks.delete"
    case webhooksDeliveries = "webhooks.deliveries"
}
