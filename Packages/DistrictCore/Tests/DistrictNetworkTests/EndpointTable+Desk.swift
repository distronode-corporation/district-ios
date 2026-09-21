@testable import DistrictNetwork
import Foundation

/// District Desk — the tenant's OWN customers' tickets.
///
/// ⛔ THE URLs ARE WRITTEN OUT RATHER THAN BUILT FROM ``DistrictPaths``, like every
/// other row in this table, and this family earns it twice over. Three unrelated
/// route families share the word `desk` — this one, `/api/district/support/*` (the
/// mirror image, the tenant's tickets with DISTRONODE) and `/api/desk/threads/*` (the
/// PUBLIC customer page, capability-token authenticated) — so a table derived from
/// the same constants the endpoints are built from would assert only that the code
/// equals itself, on the one surface where naming the wrong family is easiest.
extension EndpointTable {
    /// The queue's configuration and the logo it publishes.
    ///
    /// ⛔ EVERY ROW BELOW CARRIES `workspaceId` IN THE **QUERY**, INCLUDING THE
    /// MULTIPART UPLOAD. That is the one place the desk logo differs from
    /// `messages/media`, which reads the workspace off `req.formData()` — and the
    /// difference is invisible in a request that otherwise looks correct, so it is
    /// asserted here as a URL rather than trusted to a comment.
    static func deskSettings() -> [EndpointExpectation] {
        [
            EndpointExpectation(
                .deskSettings,
                DistrictEndpoints.deskSettings(workspaceId: "ws_1"),
                .get,
                "\(host)/api/district/desk/settings?workspaceId=ws_1"
            ),
            // ⛔ THE PATCH SENDS ONLY WHAT CHANGED. `notifyCustomersByEmail` is nil
            // here and is therefore ABSENT from the bytes below, which is the merge
            // semantics the route depends on: an omitted key is preserved.
            EndpointExpectation(
                .saveDeskSettings,
                DistrictEndpoints.saveDeskSettings(
                    workspaceId: "ws_1",
                    enabled: true,
                    notifyCustomersByEmail: nil,
                    publicBrandName: .set("Contoso Retail")
                ),
                .patch,
                "\(host)/api/district/desk/settings?workspaceId=ws_1",
                .json(#"{"enabled":true,"publicBrandName":"Contoso Retail"}"#)
            ),
            EndpointExpectation(
                .uploadDeskLogo,
                DistrictEndpoints.uploadDeskLogo(
                    workspaceId: "ws_1",
                    fileName: "logo.png",
                    mimeType: "image/png",
                    bytes: Data([0x89, 0x50])
                ),
                .post,
                "\(host)/api/district/desk/logo?workspaceId=ws_1",
                // ⛔ NO FORM FIELDS AT ALL. See the ⛔ on this function.
                .multipart(fields: [:], fileName: "logo.png")
            ),
            EndpointExpectation(
                .deleteDeskLogo,
                DistrictEndpoints.deleteDeskLogo(workspaceId: "ws_1"),
                .delete,
                "\(host)/api/district/desk/logo?workspaceId=ws_1"
            ),
        ]
    }

    /// The queue itself.
    static func deskTickets() -> [EndpointExpectation] {
        [
            // ⚠️ THE UNFILTERED READ, which is what a screen showing per-status counts
            // must send. `status` is nil and is DROPPED rather than sent empty; the
            // filtered form is pinned separately in `EndpointSurfaceTests`.
            EndpointExpectation(
                .deskTickets,
                DistrictEndpoints.deskTickets(workspaceId: "ws_1", status: nil),
                .get,
                "\(host)/api/district/desk/tickets?workspaceId=ws_1"
            ),
            // ⛔ THE OPENING MESSAGE IS `message`, AND THE THREE BLANK REQUESTER FIELDS
            // ARE ABSENT RATHER THAN `""`. An empty `requesterEmail` fails `.email()`
            // and takes the whole object down, which the route then reports as a
            // missing subject and description.
            EndpointExpectation(
                .createDeskTicket,
                DistrictEndpoints.createDeskTicket(
                    workspaceId: "ws_1",
                    draft: DeskTicketDraft(
                        subject: "Refund not received",
                        message: "Ordered on the 3rd, nothing since.",
                        requesterName: "Ada Lovelace"
                    ),
                    idempotencyKey: "6f1c3f2e-6c4a-4a2f-9b1e-2c9d0f5a7b31"
                ),
                .post,
                "\(host)/api/district/desk/tickets?workspaceId=ws_1",
                .json(
                    #"{"idempotencyKey":"6f1c3f2e-6c4a-4a2f-9b1e-2c9d0f5a7b31",""#
                        + #"message":"Ordered on the 3rd, nothing since.",""#
                        + #"requesterName":"Ada Lovelace","subject":"Refund not received"}"#
                )
            ),
            EndpointExpectation(
                .deskTicket,
                DistrictEndpoints.deskTicket(workspaceId: "ws_1", ticketId: "tkt_1"),
                .get,
                "\(host)/api/district/desk/tickets/tkt_1?workspaceId=ws_1"
            ),
            // ⛔ `message`, NOT `body`. The SUPPORT desk's reply takes `body`, and
            // transposing them is a silent 400 from a request that reads correctly.
            // This is the assertion that pins the difference.
            EndpointExpectation(
                .replyToDeskTicket,
                DistrictEndpoints.replyToDeskTicket(
                    workspaceId: "ws_1",
                    ticketId: "tkt_1",
                    message: "Refunded this morning.",
                    idempotencyKey: nil
                ),
                .post,
                "\(host)/api/district/desk/tickets/tkt_1/reply?workspaceId=ws_1",
                .json(#"{"message":"Refunded this morning."}"#)
            ),
            EndpointExpectation(
                .setDeskTicketStatus,
                DistrictEndpoints.setDeskTicketStatus(
                    workspaceId: "ws_1",
                    ticketId: "tkt_1",
                    status: "resolved"
                ),
                .post,
                "\(host)/api/district/desk/tickets/tkt_1/status?workspaceId=ws_1",
                .json(#"{"status":"resolved"}"#)
            ),
        ]
    }
}
