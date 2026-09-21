import DistrictModel
@testable import DistrictNetwork
import Foundation
import XCTest

/// Support and the Desk are OPPOSITE surfaces, and nothing may address both.
///
/// ⛔ SPLIT OUT OF `EndpointSurfaceTests` WHEN THAT FILE REACHED SwiftLint's 500-LINE
/// CEILING, and the cut is on a real seam rather than at an arbitrary line: these two
/// tests answer one question — can a descriptor in one family reach the other — while
/// the file they came from answers "what must this client be unable to ask for at all".
///
/// ⛔ THE CONFUSION THEY GUARD IS NOT HYPOTHETICAL. `district/support/*` is this tenant
/// raising something with DISTRONODE; `district/desk/*` is that tenant's own customers
/// raising something with THEM. The two families use the same nouns, are one path
/// segment apart. A third shares the word and is worse:
/// `/api/desk/threads/{handle}` is the page a tenant's CUSTOMER opens from an email,
/// authenticated by a capability token — sending this client's bearer there would send
/// it on behalf of a person who is not our user.
///
/// ⚠️ THE REPLY FIELD IS THE SAME CONFUSION IN A SECOND PLACE and is asserted next door:
/// support replies take `body`, desk replies take `message`, and transposing them is a
/// silent 400 rather than a compile error.
final class EndpointFamilyGuardTests: XCTestCase {
    /// ⛔ SUPPORT AND THE DESK ARE OPPOSITE DIRECTIONS AND NOTHING MAY ADDRESS BOTH.
    /// `district/support/*` is this tenant raising something with US;
    /// `district/desk/*` is their own customers raising something with THEM. The two
    /// families use the same nouns and are one segment apart, so the guard worth
    /// having is the one that walks the whole expressible surface: every support
    /// descriptor must sit under `support`, and none of them may reach `desk`.
    ///
    /// ⚠️ THE REPLY FIELD IS THE OTHER HALF OF THE SAME CONFUSION AND IS ASSERTED IN
    /// `EndpointTableTests`' body comparison: support replies take `body` and desk
    /// replies take `message`, and transposing them is a silent 400.
    func testTheSupportRoutesNeverAddressTheDesk() {
        let support: [ApiRequestDescriptor] = [
            DistrictEndpoints.supportRequests(workspaceId: "ws_1"),
            DistrictEndpoints.createSupportRequest(
                workspaceId: "ws_1",
                kind: .problem,
                subject: "Outbound calls failing",
                message: "Since this morning.",
                idempotencyKey: nil
            ),
            DistrictEndpoints.supportRequest(workspaceId: "ws_1", key: "DA-42"),
            DistrictEndpoints.replyToSupportRequest(workspaceId: "ws_1", key: "DA-42", body: "Thanks."),
            DistrictEndpoints.closeSupportRequest(workspaceId: "ws_1", key: "DA-42"),
        ]
        for descriptor in support {
            XCTAssertTrue(
                descriptor.segments.contains("support"),
                "\(descriptor.id.rawValue) is not under the support family"
            )
            XCTAssertFalse(
                descriptor.segments.contains("desk"),
                "\(descriptor.id.rawValue) addresses the tenant's OWN desk"
            )
        }
    }

    /// ⛔ THE DESK IS NOT THE SUPPORT DESK, AND NOTHING ON THIS SURFACE MAY ADDRESS
    /// THE PUBLIC CUSTOMER THREAD. Three families share the word: this one
    /// (`/api/district/desk/*`, the tenant's own customers' tickets, bearer-authenticated),
    /// `/api/district/support/*` (the mirror image, the tenant's tickets with
    /// Distronode), and `/api/desk/threads/{handle}` — the page a tenant's CUSTOMER
    /// opens from a notification email, which authenticates with a capability token
    /// and an HttpOnly cookie. A descriptor for the third would send this client's
    /// bearer to a route that does not want one, on behalf of a person who is not our
    /// user, and `ApiRequestDescriptor`'s internal initialiser is what makes it
    /// unconstructible rather than merely unwritten.
    func testTheDeskFamilyCannotAddressThePublicThreadOrTheInternalRoutes() {
        for row in EndpointTable.all() {
            let segments = row.descriptor.segments
            XCTAssertFalse(segments.contains("threads"), "\(row.id.rawValue) addresses the public desk thread")
            XCTAssertFalse(segments.contains("desk-lookup"), "\(row.id.rawValue) addresses the agent's lookup")
            XCTAssertFalse(segments.contains("desk-ticket"), "\(row.id.rawValue) addresses the agent's filing route")
            // ⚠️ Every desk route this client has is under `district`, so a bare
            // `/api/desk/...` prefix is the public family by construction.
            if segments.contains("desk") {
                XCTAssertEqual(segments.first, "api", "\(row.id.rawValue) has a malformed prefix")
                XCTAssertEqual(
                    segments.dropFirst().first,
                    "district",
                    "\(row.id.rawValue) is under /api/desk, which is the PUBLIC customer surface"
                )
            }
        }
        XCTAssertNil(EndpointID(rawValue: "deskThread"))
        // The desk paths that DO exist, so the assertions above are not passing
        // merely because the family is empty.
        XCTAssertEqual(DistrictPaths.deskSettings, ["api", "district", "desk", "settings"])
        XCTAssertEqual(DistrictPaths.deskLogo, ["api", "district", "desk", "logo"])
        XCTAssertEqual(
            DistrictPaths.deskTicketReply("tkt_1"),
            ["api", "district", "desk", "tickets", "tkt_1", "reply"]
        )
    }
}
