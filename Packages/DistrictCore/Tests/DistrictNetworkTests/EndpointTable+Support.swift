import DistrictModel
@testable import DistrictNetwork
import Foundation

extension EndpointTable {
    /// The tenant's own support requests with Distronode.
    ///
    /// ⛔ WRITTEN OUT BY HAND, AND ON THIS FAMILY THAT IS DOING MORE WORK THAN
    /// USUAL. A table derived from ``DistrictPaths`` would assert only that the
    /// code equals itself, and the two mistakes this surface actually invites are
    /// both invisible that way: addressing `district/desk` (the tenant's OWN
    /// queue, the opposite direction, same nouns) instead of `district/support`,
    /// and spelling the reply field `message` instead of `body`.
    ///
    /// ⛔ THE REPLY BODY IS `{"body":"…"}` AND THE ASSERTION BELOW IS THE PIN. The
    /// desk's reply route one family over takes `message`; the Zod schema on
    /// `support/requests/[key]/reply` is `z.object({ body: … })`, so a transposed
    /// field is a **400** with no other symptom. Verified against the route
    /// source, not inferred from the web component.
    ///
    /// ⚠️ THE CREATE PUTS `workspaceId` IN THE **QUERY** AND ITS PAYLOAD IN THE
    /// BODY, which is the split the whole family uses: every one of these five
    /// routes reads `searchParams.get("workspaceId")` and none of them accepts it
    /// in a body. That is the opposite of `scheduling/enable`, which reads
    /// `req.json()` first.
    ///
    /// ⚠️ THE CREATE ROW OMITS `idempotencyKey` DELIBERATELY, so the encoded body
    /// pins ``JSONValue/object(_:)``'s nil-drop on this route as well: an
    /// `idempotencyKey: null` on the wire would fail the server's
    /// `z.string().uuid().optional()` and 400 the whole request.
    static func support() -> [EndpointExpectation] {
        [
            EndpointExpectation(
                .supportRequests,
                DistrictEndpoints.supportRequests(workspaceId: "ws_1"),
                .get,
                "\(host)/api/district/support/requests?workspaceId=ws_1"
            ),
            EndpointExpectation(
                .createSupportRequest,
                DistrictEndpoints.createSupportRequest(
                    workspaceId: "ws_1",
                    kind: .problem,
                    subject: "Outbound calls failing for one number",
                    message: "Since this morning.",
                    idempotencyKey: nil
                ),
                .post,
                "\(host)/api/district/support/requests?workspaceId=ws_1",
                .json(
                    #"{"kind":"problem","message":"Since this morning.","#
                        + #""subject":"Outbound calls failing for one number"}"#
                )
            ),
            EndpointExpectation(
                .supportRequest,
                DistrictEndpoints.supportRequest(workspaceId: "ws_1", key: "DA-42"),
                .get,
                "\(host)/api/district/support/requests/DA-42?workspaceId=ws_1"
            ),
            // ⛔ `body`, NEVER `message`. See the ⛔ on this function.
            EndpointExpectation(
                .replyToSupportRequest,
                DistrictEndpoints.replyToSupportRequest(
                    workspaceId: "ws_1",
                    key: "DA-42",
                    body: "It is still happening."
                ),
                .post,
                "\(host)/api/district/support/requests/DA-42/reply?workspaceId=ws_1",
                .json(#"{"body":"It is still happening."}"#)
            ),
            // ⛔ A POST WITH NO BODY AT ALL. The handler never calls `req.json()`,
            // so a body would be ignored and sending one would be this client
            // inventing a contract.
            EndpointExpectation(
                .closeSupportRequest,
                DistrictEndpoints.closeSupportRequest(workspaceId: "ws_1", key: "DA-42"),
                .post,
                "\(host)/api/district/support/requests/DA-42/close?workspaceId=ws_1"
            ),
        ]
    }
}
