import Foundation

// The desk, helpdesk and CRM-write half of the manifest, in a file of its own to keep
// `ContractManifest.swift` under SwiftLint's `file_length` ceiling, which `--strict`
// promotes to an error in the lint job rather than in this suite.

extension ContractManifest {
    /// The desk and helpdesk fixtures that carry explicit nulls, unioned into
    /// ``fixturesWithAllowedNulls``.
    ///
    /// The family is sixteen fixtures: nine `district-desk-*` bodies (settings read and
    /// patch, the logo upload and its delete, the queue, the create echo, one ticket with
    /// its thread, a reply and a status change), five `district-support-*` bodies (the
    /// list, the filed create, one request with its conversation, a reply and a close),
    /// and `district-contact-update.json` / `district-contact-delete.json`. All sixteen are
    /// gated in `ImplementedFixtures+DeskSupport.swift`.
    ///
    /// ⚠️ Only the seven names below carry a null, each path named with its column in
    /// `AllowedExplicitNulls+DeskSupport.swift`. The other nine carry none, both contact
    /// writes included.
    static let deskAndSupportFixturesWithAllowedNulls: Set<String> = [
        "district-desk-logo-delete.json",
        "district-desk-settings-patch.json",
        "district-desk-ticket-create.json",
        "district-desk-ticket-reply.json",
        "district-desk-ticket.json",
        "district-desk-tickets.json",
        "district-support-requests.json",
    ]
}
