import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// The fourth workspace-settings write: replacing the call transfer directory.
///
/// ⛔ ITS OWN FILE BECAUSE `WorkspaceWriteRepositoryTests` IS AT 298 LINES AGAINST
/// SwiftLint's 500 AND THIS SURFACE DESERVES MORE THAN THE REMAINDER. It is the most
/// destructive call in this client and its failure mode is a **200**: the handler
/// writes `callDirectory: (callDirectory || [])`, so an empty array — or a body that
/// omits the key — wipes every human the voice agent can put a live caller through
/// to, and answers `{success:true}`. There is no undo.
///
/// ⛔ SO THE ASSERTIONS HERE ARE ABOUT THE BYTES THAT WENT OUT, not about the reply.
/// Two things must survive a round trip through a form: a row's UNMODELLED keys, and
/// the difference between an ABSENT `type` and an explicit `"pstn"`. Both are silent
/// when they break.
///
/// ⚠️ `district-directory-patch.json` IS GATED AGAINST ``SuccessResponse``, which is
/// why this endpoint needs only a repository method to be typed, not a new type. The fixture pins the wire shape;
/// this pins the request.
final class WorkspaceDirectoryRepositoryTests: XCTestCase {
    private func repository(_ transport: RepositoryTransport) -> WorkspaceRepository {
        WorkspaceRepository(client: .repositoryTest(transport))
    }

    /// ⛔ THE ROWS GO OUT WHOLE, UNMODELLED KEYS INCLUDED. The route's per-entry zod
    /// schema is `.passthrough()` and the column is `Json`, so a row can carry
    /// anything anyone ever wrote — and a request rebuilt from a typed model would
    /// strip the rest and answer 200. That is a silent deletion INSIDE a row rather
    /// than of one, which is why the parameter is `[JSONValue]`.
    func testARowsUnmodelledKeysSurviveTheSave() async {
        let transport = RepositoryTransport(json: #"{"success":true}"#)

        let result = await repository(transport).saveDirectory(
            workspaceId: "ws_1",
            callDirectory: [
                .object([
                    "name": .string("Front desk"),
                    "phoneNumber": .string("+14165550101"),
                    "extension": .string("204"),
                ]),
            ]
        )

        XCTAssertNil(result.failureOnly, "a bare success is the whole answer this route gives")
        XCTAssertEqual(transport.requests.first?.method, .patch)
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/workspace/directory"
        )
        XCTAssertEqual(
            transport.bodies.first,
            #"{"callDirectory":[{"extension":"204","name":"Front desk","#
                + #""phoneNumber":"+14165550101"}],"workspaceId":"ws_1"}"#,
            "a key this client does not model must reach the wire unchanged"
        )
    }

    /// ⛔ `type: "app"` IS WHAT MAKES A TRANSFER RING THE PHONE INSTEAD OF DIALLING A
    /// PSTN NUMBER, and the route validates it as `"pstn" | "app"` — anything else is
    /// a 400. It had never been settable from any UI before the directory editor, so
    /// this is the assertion that says the value reaches the column at all.
    func testTheAppTypeReachesTheWire() async {
        let transport = RepositoryTransport(json: #"{"success":true}"#)

        _ = await repository(transport).saveDirectory(
            workspaceId: "ws_1",
            callDirectory: [
                .object([
                    "name": .string("On call"),
                    "phoneNumber": .string("+14165550102"),
                    "type": .string("app"),
                ]),
            ]
        )

        XCTAssertEqual(
            transport.bodies.first,
            #"{"callDirectory":[{"name":"On call","phoneNumber":"+14165550102","#
                + #""type":"app"}],"workspaceId":"ws_1"}"#
        )
    }

    /// ⛔ AN ABSENT `type` MUST STAY ABSENT AND MUST NOT BE NORMALISED TO `"pstn"` ON
    /// THE WAY OUT. Every entry stored today has no `type` key, every reader (the
    /// voice agent's `tools.py` included) already treats an entry as a phone number,
    /// and the route deliberately does not default it on write. Writing it in would
    /// rewrite every tenant's stored config on the next save to say what it already
    /// meant, and would make "did an operator CHOOSE pstn?" permanently unanswerable.
    func testALegacyRowWithNoTypeIsSentWithNoTypeKey() async {
        let transport = RepositoryTransport(json: #"{"success":true}"#)

        _ = await repository(transport).saveDirectory(
            workspaceId: "ws_1",
            callDirectory: [.object(["name": .string("Front desk"), "phoneNumber": .string("+14165550101")])]
        )

        XCTAssertEqual(
            transport.bodies.first,
            #"{"callDirectory":[{"name":"Front desk","phoneNumber":"+14165550101"}],"workspaceId":"ws_1"}"#
        )
    }

    /// ⛔ AN EMPTY LIST IS A LEGITIMATE SAVE AND IS NOT SECOND-GUESSED HERE. An
    /// operator who wants no transfer targets must be able to say so; the guard
    /// against an ACCIDENTAL empty save is that the form can only be built on a
    /// successful config read (`SettingsConfigState` has no case for "we could not
    /// load, here is an empty form anyway"), not a repository refusing a request it
    /// was given. ⚠️ The key is still SENT rather than dropped — an omitted key wipes
    /// the directory just as an empty array does, but only one of the two is what the
    /// caller asked for.
    func testAnEmptyListIsSentAsAnEmptyArrayRatherThanRefusedOrDropped() async {
        let transport = RepositoryTransport(json: #"{"success":true}"#)

        let result = await repository(transport).saveDirectory(workspaceId: "ws_1", callDirectory: [])

        XCTAssertNil(result.failureOnly)
        XCTAssertEqual(transport.bodies.first, #"{"callDirectory":[],"workspaceId":"ws_1"}"#)
    }

    /// ⛔ A WELL-FORMED `success:false` ON A **200** IS THE ROUTE'S OWN CATCH BRANCH
    /// once the headers are written, and ``SuccessResponse`` does not reject it. The
    /// envelope check is the only thing that does — and on this route the cost of
    /// getting it wrong is telling an operator their directory saved when it did not,
    /// after which they will not look at it again.
    func testASaveThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(json: #"{"success":false}"#)

        let result = await repository(transport).saveDirectory(workspaceId: "ws_1", callDirectory: [])

        XCTAssertEqual(result.failureOnly, .decoding("DirectoryPatchResponse did not affirm success=true"))
    }

    /// ⚠️ THE THREE FAILURES A SCREEN HAS TO TELL APART: the viewer exclusion, an
    /// ended session, and a transient outage. ⛔ The 404 is the fourth and it is the
    /// route's own — a workspace deleted between the role check and the write lands
    /// there, from the P2025 branch rather than the unreachable guard above it.
    func testTheRefusalsArriveWithTheirStatus() async {
        let viewer = RepositoryTransport(json: #"{"error":"Forbidden"}"#, status: 403)
        let refused = await repository(viewer).saveDirectory(workspaceId: "ws_1", callDirectory: [])
        XCTAssertEqual(refused.failureOnly, .http(status: 403, message: "Forbidden"))
        XCTAssertEqual(refused.failureOnly?.isUnauthorized, false, "403 is not a token problem")

        let expired = RepositoryTransport(json: #"{"error":"Unauthorized"}"#, status: 401)
        let unauthorized = await repository(expired).saveDirectory(workspaceId: "ws_1", callDirectory: [])
        XCTAssertEqual(unauthorized.failureOnly?.isUnauthorized, true)

        let gone = RepositoryTransport(json: #"{"success":false,"error":"Workspace not found"}"#, status: 404)
        let missing = await repository(gone).saveDirectory(workspaceId: "ws_1", callDirectory: [])
        XCTAssertEqual(missing.failureOnly?.httpStatus, 404)

        let degraded = RepositoryTransport(json: #"{"success":false,"error":"Internal Server Error"}"#, status: 503)
        let transient = await repository(degraded).saveDirectory(workspaceId: "ws_1", callDirectory: [])
        XCTAssertEqual(transient.failureOnly?.httpStatus, 503)
    }
}
