import DistrictModel
import Foundation

// District Desk, the in-product helpdesk and the two CRM writes, in a file of their own.
//
// ⛔ SPLIT OUT BECAUSE `ImplementedFixtures.swift` IS AT ITS 500-LINE CEILING, the same
// reason `+MessageThread`, `+Persona` and `+SchedulingAdmin` were.

extension ImplementedFixtures {
    // MARK: - District Desk and the helpdesk

    /// ⛔ SIXTEEN FIXTURES THAT ARRIVED AFTER THEIR TYPES, which is the reverse of the
    /// usual order. `DeskResponses.swift`, `DeskTicketResponses.swift`,
    /// `SupportResponses.swift` and both repositories shipped with no fixture behind
    /// them, pinned only by the route source and the repository tests' hand-written
    /// bodies. The server's generator records these from the real handlers, and
    /// every one of them is gated here rather than listed in
    /// ``ContractManifest/unimplemented``.
    ///
    /// ⛔ THE DESK'S WRITES ANSWER A SUMMARY AND ONLY ITS READ ANSWERS A DETAIL. The
    /// create, reply and status echoes carry no `messages` key, so each is gated
    /// against a type built on ``DeskTicketSummary``; decoding one into
    /// ``DeskTicketDetail`` would fail here on the missing key rather than blank a
    /// thread on screen.
    ///
    /// ⚠️ SEVEN OF THE FOURTEEN CARRY EXPLICIT NULLS, sixteen paths in all, and each
    /// has an exact entry in `AllowedExplicitNulls+DeskSupport.swift`.
    static var deskAndSupport: [ImplementedFixture] {
        [
            gate("district-desk-settings.json", DeskSettingsResponse.self),
            gate("district-desk-settings-patch.json", DeskSettingsResponse.self),
            // The upload answers the same two-key settings envelope; only the
            // delete adds `objectRemoved`, and it needs its own type for that.
            gate("district-desk-logo.json", DeskSettingsResponse.self),
            gate("district-desk-logo-delete.json", DeskLogoRemovalResponse.self),
            gate("district-desk-tickets.json", DeskTicketsResponse.self),
            gate("district-desk-ticket-create.json", DeskTicketCreateResponse.self),
            gate("district-desk-ticket.json", DeskTicketResponse.self),
            gate("district-desk-ticket-reply.json", DeskReplyResponse.self),
            gate("district-desk-ticket-status.json", DeskTicketStatusResponse.self),
            gate("district-support-requests.json", SupportRequestListResponse.self),
            gate("district-support-request-create.json", SupportRequestCreateResponse.self),
            gate("district-support-request.json", SupportRequestDetailResponse.self),
            gate("district-support-reply.json", SupportReplyResponse.self),
            gate("district-support-close.json", SupportCloseResponse.self),
        ]
    }

    // MARK: - The two CRM writes

    /// ⚠️ BOTH ARE `{"success": true}` AND BOTH ARE GATED AGAINST ``SuccessResponse``,
    /// which is the type `ContactsRepository` decodes them into. Each fixture is pinned
    /// separately so the day either route grows a field, that one fails on its own.
    /// Neither carries an explicit null.
    static var contactWrites: [ImplementedFixture] {
        [
            gate("district-contact-update.json", SuccessResponse.self),
            gate("district-contact-delete.json", SuccessResponse.self),
        ]
    }
}
