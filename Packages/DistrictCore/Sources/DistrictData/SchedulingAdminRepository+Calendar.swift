import DistrictModel
import DistrictNetwork
import Foundation

/// The `calendar.*` namespace plus `zoom.status`, typed.
///
/// ⚠️ EVERY OP HERE IS `viewer`, INCLUDING THE FOUR WRITES, and that is the
/// catalog's decision rather than a gap in it: these are the CALLER'S OWN calendar
/// connections, so a viewer linking their own Google account changes nothing about
/// the tenancy. Four of the seven are `NO_CONTENT` ops, which answer
/// `{"ok":true,"data":{"ok":true}}` rather than an empty body — see
/// ``SchedulingNoContent``.
///
/// ⛔ `provider` IS REQUIRED BY EVERY CONNECTION OP AND THE `{id}` IN THE PATH IS
/// DECORATIVE. The fork recreates a connection id on every token refresh, so
/// identity is `provider` + `account`, and a client that sent only the id would
/// address a connection that no longer answers to it. The id is still sent, and is
/// still in the body — see the path-keys note on `+Bookings.swift`.
///
/// ⚠️ THE SAME VALUE HAS TWO SPELLINGS ACROSS ONE ENDPOINT PAIR: the GET and the
/// DELETE take it as `account`, the PUT and the destination write take it as
/// `account_email`. That is the server's schema, not a typo to tidy — the
/// parameter is named `accountEmail` on both sides here so the caller does not
/// have to know, and the wire key is what differs.
public extension SchedulingAdminRepository {
    /// `calendar.status` — what the instance offers and what this caller has
    /// connected.
    func calendarStatus(workspaceId: String) async throws -> SchedulingCalendarStatus {
        try await perform(
            .calendarStatus,
            workspaceId: workspaceId,
            params: .object([]),
            as: SchedulingCalendarStatus.self
        )
    }

    /// `calendar.caldav.connect` — link a CalDAV account.
    ///
    /// ⛔ THE WIRE FIELD IS `app_password`, NOT `password`, and the distinction is
    /// the point: Fastmail, iCloud and Zimbra all require an application-specific
    /// credential here rather than the account password.
    /// ⚠️ `serverUrl` IS REFUSED BY THE CATALOG unless it is an `https://` address
    /// with a hostname — an SSRF guard shared with the browser form — so a
    /// malformed one is an `invalidParams` naming the field rather than a request
    /// the scheduler ever sees.
    func connectCaldav(
        workspaceId: String,
        username: String,
        appPassword: String,
        preset: String? = nil,
        serverUrl: String? = nil
    ) async throws -> SchedulingCaldavConnection {
        try await perform(
            .calendarCaldavConnect,
            workspaceId: workspaceId,
            params: .object([
                ("username", .string(username)),
                ("app_password", .string(appPassword)),
                ("preset", .optional(preset)),
                ("server_url", .optional(serverUrl)),
            ]),
            as: SchedulingCaldavConnection.self
        )
    }

    /// `calendar.connections.calendars.get` — the calendars inside one connected
    /// account.
    ///
    /// ⚠️ THE CONTAINER KEY IS `calendars`, NOT `items`. Unwrapped here so callers
    /// do not have to care, but the shape is pinned by
    /// ``SchedulingCalendarSelections`` because the gate compares key sets.
    func connectionCalendars(
        workspaceId: String,
        connectionId: String,
        provider: String,
        accountEmail: String? = nil
    ) async throws -> [SchedulingCalendarSelection] {
        try await perform(
            .calendarConnectionsCalendarsGet,
            workspaceId: workspaceId,
            params: .object([
                ("id", .string(connectionId)),
                ("provider", .string(provider)),
                ("account", .optional(accountEmail)),
            ]),
            as: SchedulingCalendarSelections.self
        ).calendars
    }

    /// `calendar.connections.calendars.put` — replace the whole selection for one
    /// account.
    ///
    /// ⛔ A REPLACE, NOT A PATCH, AND A CALENDAR LEFT OUT IS A CALENDAR TURNED
    /// OFF. Send back the rows ``connectionCalendars(workspaceId:connectionId:provider:accountEmail:)``
    /// answered with the flags the user changed, rather than an array built from
    /// the one row they touched.
    func setConnectionCalendars(
        workspaceId: String,
        connectionId: String,
        provider: String,
        calendars: [SchedulingCalendarSelection],
        accountEmail: String? = nil
    ) async throws -> SchedulingNoContent {
        try await perform(
            .calendarConnectionsCalendarsPut,
            workspaceId: workspaceId,
            params: .object([
                ("id", .string(connectionId)),
                ("provider", .string(provider)),
                ("account_email", .optional(accountEmail)),
                ("calendars", .array(calendars.map(calendarParams))),
            ]),
            as: SchedulingNoContent.self
        )
    }

    /// `calendar.connections.destination` — make this connection the one new
    /// bookings are written to.
    ///
    /// ⚠️ EXACTLY ONE CONNECTION HOLDS IT, so this is a move rather than a toggle:
    /// there is no call that clears the destination, and the previous holder loses
    /// it as a side effect. Re-read ``calendarStatus(workspaceId:)`` afterwards
    /// rather than flipping the flag on two local rows.
    func setDestinationConnection(
        workspaceId: String,
        connectionId: String,
        provider: String,
        accountEmail: String? = nil
    ) async throws -> SchedulingNoContent {
        try await perform(
            .calendarConnectionsDestination,
            workspaceId: workspaceId,
            params: .object([
                ("id", .string(connectionId)),
                ("provider", .string(provider)),
                ("account_email", .optional(accountEmail)),
            ]),
            as: SchedulingNoContent.self
        )
    }

    /// `calendar.connections.delete` — unlink an account.
    ///
    /// ⛔ THIS CAN REMOVE THE DESTINATION CONNECTION, and the catalog does not
    /// refuse it. A tenancy left with no destination writes new bookings nowhere,
    /// so a screen offering this has to re-read the status and say so.
    func deleteCalendarConnection(
        workspaceId: String,
        connectionId: String,
        provider: String,
        accountEmail: String? = nil
    ) async throws -> SchedulingNoContent {
        try await perform(
            .calendarConnectionsDelete,
            workspaceId: workspaceId,
            params: .object([
                ("id", .string(connectionId)),
                ("provider", .string(provider)),
                ("account", .optional(accountEmail)),
            ]),
            as: SchedulingNoContent.self
        )
    }

    /// `zoom.status` — whether the instance has Zoom credentials, and whether this
    /// caller has linked an account.
    ///
    /// ⛔ THE ONLY ZOOM OP THERE IS. `GET|PATCH /v1/settings/zoom` hold the
    /// INSTANCE's credentials, shared by every tenancy on the deployment, and are
    /// deliberately absent from the catalog — so nothing on this client can change
    /// Zoom's configuration even in principle.
    func zoomStatus(workspaceId: String) async throws -> SchedulingZoomStatus {
        try await perform(
            .zoomStatus,
            workspaceId: workspaceId,
            params: .object([]),
            as: SchedulingZoomStatus.self
        )
    }
}

/// One calendar selection as the PUT's body wants it.
///
/// ⛔ THE FOUR FLAGS ARE DROPPED WHEN NIL RATHER THAN SENT AS `false`, which
/// matters because absent and `false` are not the same statement to the fork: a
/// holiday calendar the GET reported with neither `writable` nor `primary` must
/// go back the way it came. `JSONValue.object(_:)` does the dropping; this
/// function only has to avoid inventing a value.
private func calendarParams(_ selection: SchedulingCalendarSelection) -> JSONValue {
    .object([
        ("id", .string(selection.id)),
        ("name", .string(selection.name)),
        ("primary", selection.primary.map(JSONValue.bool)),
        ("writable", selection.writable.map(JSONValue.bool)),
        ("check_conflicts", selection.checkConflicts.map(JSONValue.bool)),
        ("is_destination", selection.isDestination.map(JSONValue.bool)),
    ])
}
