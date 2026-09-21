@testable import DistrictNetwork
import Foundation

extension EndpointTable {
    /// The scheduling admin surface: one RPC, one upload, one download.
    ///
    /// ⛔ THREE ROWS FOR SEVENTY-FIVE OPERATIONS, AND THE TABLE IS RIGHT TO COUNT
    /// IT THAT WAY. This file asserts what this client can ADDRESS, and the op
    /// travels in the body rather than the path, so 74 more rows would all carry
    /// the same URL. What pins the op names is `SchedulingAdminOpTests`, which
    /// holds all 75 strings a second time.
    ///
    /// ⛔ THE RPC ROW PINS `params` AS AN EMPTY OBJECT RATHER THAN A DROPPED KEY,
    /// which is the opposite decision from the `scheduling/handoff` row three
    /// functions up and is deliberate. `JSONValue.object(_:)` drops nil pairs, and
    /// `next` relies on that so the route's own default fires; `params` must
    /// SURVIVE as `{}` — the route defaults an absent one to `{}` as well, so the
    /// two agree today, and sending it makes the agreement a contract instead of a
    /// coincidence.
    ///
    /// ⛔ THE UPLOAD IS THE THIRD MULTIPART SHAPE IN THIS TABLE AND SHARES NEITHER
    /// OF THE OTHER TWO. `messages/media` carries the workspace as a FORM FIELD;
    /// `desk/logo` carries it in the QUERY and sends no fields at all; this one
    /// carries it in the query AND sends a field, because `target` is not knowable
    /// until the multipart body is parsed while the workspace has to be readable
    /// before it. A row copied from either sibling is wrong in a different way.
    static func schedulingAdmin() -> [EndpointExpectation] {
        [
            EndpointExpectation(
                .schedulingAdmin,
                DistrictEndpoints.schedulingAdmin(
                    workspaceId: "ws_1",
                    op: .eventTypesGet,
                    params: .object([("slug", .string("intro-call"))])
                ),
                .post,
                "\(host)/api/district/scheduling/admin",
                // ⛔ `slug` IS STILL HERE. It is a path key at the far end and the
                // server strips it; a client that stripped it first would fail the
                // catalog's own params schema for a missing required field.
                .json(#"{"op":"eventTypes.get","params":{"slug":"intro-call"},"workspaceId":"ws_1"}"#)
            ),
            EndpointExpectation(
                .schedulingAdminUpload,
                DistrictEndpoints.schedulingAdminUpload(
                    workspaceId: "ws_1",
                    target: .logo,
                    fileName: "logo.png",
                    mimeType: "image/png",
                    bytes: Data([0x89])
                ),
                .post,
                "\(host)/api/district/scheduling/admin/upload?workspaceId=ws_1",
                .multipart(fields: ["target": "logo"], fileName: "logo.png")
            ),
            // ⛔ A 302 TO A PRESIGNED OBJECT, like `calls/{id}/recording`. The row
            // says nothing about that — it is a URL assertion — but the endpoint is
            // on `RedirectEndpoints.all` and `EndpointSurfaceTests` is where that
            // is pinned.
            EndpointExpectation(
                .schedulingAdminDownload,
                DistrictEndpoints.schedulingAdminDownload(workspaceId: "ws_1", recordingId: "rec_1"),
                .get,
                "\(host)/api/district/scheduling/admin/download/rec_1?workspaceId=ws_1"
            ),
        ]
    }
}
