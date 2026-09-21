import Foundation

public extension TypedEndpoints {
    /// District Desk — the tenant's OWN customers' tickets.
    ///
    /// ⛔ NOT THE SUPPORT DESK, WHICH IS THE MIRROR IMAGE AND A SEPARATE FAMILY. These
    /// are the tickets a tenant's customers raised with the TENANT;
    /// `/api/district/support/*` is the tenant raising something with DISTRONODE. And
    /// neither is `/api/desk/threads/{handle}`, the PUBLIC page a tenant's customer
    /// opens from a notification email, which has no ``EndpointID`` at all.
    ///
    /// ⛔ NEVER UNTYPED: the descriptors, the DTOs and ``DistrictData``'s
    /// `DeskRepository` belong together, so no screen can reach one of these routes
    /// and get bytes back.
    ///
    /// ✅ ALL NINE HAVE GENERATED CONTRACT FIXTURES. The server's contract generator
    /// writes nine `district-desk-*.json` files from the real handlers and
    /// `ImplementedFixtures+DeskSupport.swift` gates them against these types.
    /// `ContractManifest.expectedFixtureCount` is asserted exactly against the files
    /// on disk, so it moves only when files do.
    ///
    /// ⚠️ NINE ENTRIES FOR SEVEN PATHS. `desk/settings` is GET + PATCH and `desk/logo`
    /// is POST + DELETE — the same "a path is not an endpoint" arithmetic the messaging
    /// family made, running in the other direction.
    ///
    /// ⚠️ ITS OWN FILE RATHER THAN NINE MORE LINES IN `EndpointClassification.swift`,
    /// which is a lint ceiling and not a taxonomy: that file is at SwiftLint's 500-line
    /// limit and the commentary on those lists is the point of them. See the ⚠️ on
    /// ``TypedEndpoints/all``.
    static let desk: Set<EndpointID> = [
        .deskSettings,
        .saveDeskSettings,
        .uploadDeskLogo,
        .deleteDeskLogo,
        .deskTickets,
        .createDeskTicket,
        .deskTicket,
        .replyToDeskTicket,
        .setDeskTicketStatus,
    ]
}
