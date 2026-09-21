import Foundation

// The desk and helpdesk allowlist entries, in a file of their own.
//
// ⛔ A SEPARATE GROUP FOR THE 500-LINE `file_length` CEILING, like `+Inbox` and
// `+Meetings`. It is chained into `allowedExplicitNulls` in
// `AllowedExplicitNulls+Union.swift`, whose union traps on a fixture named twice.
//
// ⚠️ EVERY PATH WAS ENUMERATED FROM THE FIXTURE BYTES, not inferred from the DTOs. Seven
// of the fourteen desk and support fixtures carry a null; the other seven (the settings
// read, the logo upload, the ticket status echo, and four support bodies) carry none,
// and must not be given an entry: a permission for a null nobody has checked would
// silence one a regeneration adds.

extension StrictDecodeVerifier {
    static let deskAndSupport: [String: Set<String>] = [
        // ⛔ THE ONE COLUMN A TAKEDOWN CLEARS. `DeskSettings.publicLogoUrl` is null when
        // the workspace has no logo, which is exactly what the delete leaves behind.
        "district-desk-logo-delete.json": [
            "$.settings.publicLogoUrl",
        ],
        // ⛔ BOTH NULLABLE SETTINGS AT ONCE. A blank brand name is stored as NULL, which
        // means "fall back to the workspace name"; the logo column is null because no
        // logo was ever uploaded. The settings READ populates both, so the pair covers
        // both sides of each Optional.
        "district-desk-settings-patch.json": [
            "$.settings.publicBrandName",
            "$.settings.publicLogoUrl",
        ],
        // ⚠️ `DeskTicket.resolvedAt`, stamped only when a ticket is resolved. The
        // create, the read and the reply echo are all of an OPEN ticket; the status
        // echo is of the resolved one and so has no entry.
        "district-desk-ticket-create.json": [
            "$.ticket.resolvedAt",
        ],
        "district-desk-ticket-reply.json": [
            "$.ticket.resolvedAt",
        ],
        "district-desk-ticket.json": [
            "$.ticket.resolvedAt",
        ],
        // ⛔ NINE PATHS OVER THREE ROWS, AND ROW 1 IS THE REASON THE FIXTURE EXISTS. A
        // ticket the voice agent raised from a withheld number has no contact, name,
        // email or phone, which is the commonest row on a voice workspace. Row 2 has an
        // email and nothing else. Only row 2 is resolved, so rows 0 and 1 null
        // `resolvedAt`.
        "district-desk-tickets.json": [
            "$.tickets[0].resolvedAt",
            "$.tickets[1].contactId",
            "$.tickets[1].requesterEmail",
            "$.tickets[1].requesterName",
            "$.tickets[1].requesterPhone",
            "$.tickets[1].resolvedAt",
            "$.tickets[2].contactId",
            "$.tickets[2].requesterName",
            "$.tickets[2].requesterPhone",
        ],
        // ⛔ THE UNFILED REQUEST. `issueKey` is null until Atlassian has accepted the
        // request; the local claim row is written first so an outage cannot lose it,
        // which makes this the ordinary state of anything raised seconds ago.
        "district-support-requests.json": [
            "$.requests[1].issueKey",
        ],
    ]
}
