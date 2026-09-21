import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// District Desk: the settings that decide which screen to draw, and the logo.
///
/// ⛔ THE ASSERTIONS HERE ARE ABOUT OUTCOMES THAT LOOK ALIKE ON A SCREEN AND ARE NOT
/// THE SAME VALUE. A desk that is switched OFF and a settings read that FAILED are
/// the same picture and must never be the same value; and a logo takedown that
/// cleared the column without deleting the stored object is a 200 that must not be
/// reported as "the bytes are gone".
///
/// ⚠️ THE QUEUE, THE WRITES AND THE MERGE HELPERS ARE IN
/// `DeskTicketRepositoryTests`. Split for SwiftLint's file and type-body ceilings,
/// which is also the honest seam: this file is about the surface that decides WHICH
/// screen to draw, and that one is about the tickets on it.
///
/// ⚠️ THE BODIES IN `DeskTestBodies` ARE NOT CONTRACT FIXTURES. They are written from
/// the ROUTE SOURCE to drive the repository's branches. The generated
/// `district-desk-*.json` fixtures pin the real shapes, gated in
/// `ImplementedFixtures+DeskSupport.swift`; re-check these bodies against those files
/// if either side changes.
final class DeskRepositoryTests: XCTestCase {
    private func repository(_ transport: RepositoryTransport) -> DeskRepository {
        DeskRepository(client: .repositoryTest(transport))
    }

    // MARK: - Settings

    func testReadingSettingsGetsTheSettingsRouteWithTheWorkspaceInTheQuery() async {
        let transport = RepositoryTransport(json: DeskBodies.settings(enabled: true))

        let result = await repository(transport).settings(workspaceId: "ws_1")

        XCTAssertEqual(result.successOnly?.enabled, true)
        XCTAssertEqual(result.successOnly?.publicBrandName, "Contoso")
        XCTAssertEqual(transport.requests.first?.method, .get)
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/desk/settings?workspaceId=ws_1"
        )
        XCTAssertTrue(transport.bodies.isEmpty, "a GET carries no body")
    }

    /// ⛔ A DESK THAT IS OFF IS A SUCCESSFUL READ. It is the state every workspace
    /// starts in, and the screen it produces says "nothing is being recorded until you
    /// turn this on" rather than "you have no tickets".
    func testASwitchedOffDeskIsASuccessfulReadRatherThanAnAbsence() async {
        let transport = RepositoryTransport(json: DeskBodies.settings(enabled: false))

        let result = await repository(transport).settings(workspaceId: "ws_1")

        XCTAssertEqual(result.successOnly?.enabled, false)
        XCTAssertNil(result.failureOnly)
    }

    /// ⛔ THE ENVELOPE CHECK IS NOT REDUNDANT WITH THE DTO'S REQUIRED FIELDS. A
    /// required field rejects `{}`; it does not reject a well-formed body saying
    /// `success: false`, which is what a handler falling into its own error branch
    /// after the headers are written produces on a 200. Without it "we could not ask"
    /// would render as "the desk is off" and an operator would go looking for a switch
    /// that is already on.
    func testASettingsReadThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(json: DeskBodies.settings(enabled: true, success: false))

        let result = await repository(transport).settings(workspaceId: "ws_1")

        XCTAssertEqual(result.failureOnly, .decoding("DeskSettingsResponse did not affirm success=true"))
    }

    /// ⚠️ A workspace that never set a brand name gets an explicit null, and it has to
    /// survive as nil: nil means "fall back to the workspace's own name", which the
    /// server resolves, and an empty string would render as a blank heading on a page
    /// a stranger opens.
    func testAnUnsetBrandNameAndLogoSurviveAsNil() async {
        let transport = RepositoryTransport(json: DeskBodies.settingsWithoutBranding())

        let result = await repository(transport).settings(workspaceId: "ws_1")

        XCTAssertNil(result.successOnly?.publicBrandName)
        XCTAssertNil(result.successOnly?.publicLogoUrl)
        XCTAssertEqual(result.successOnly?.notifyCustomersByEmail, true)
    }

    /// ⛔ ONLY WHAT CHANGED REACHES THE WIRE. The route merges per field, so an
    /// omitted key is preserved; a body carrying every switch would make this screen
    /// the writer of values it may have read before another tab changed them.
    func testPatchingSendsOnlyTheFieldsThatWereGiven() async {
        let transport = RepositoryTransport(json: DeskBodies.settings(enabled: true))

        _ = await repository(transport).updateSettings(workspaceId: "ws_1", enabled: true)

        XCTAssertEqual(transport.requests.first?.method, .patch)
        XCTAssertEqual(transport.bodies, [#"{"enabled":true}"#])
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/desk/settings?workspaceId=ws_1"
        )
    }

    /// ⛔ CLEARING THE BRAND NAME IS AN EXPLICIT NULL, NOT AN OMITTED KEY, and this is
    /// the one place in the client that uses `JSONValue`'s escape hatch. Omitting it
    /// would mean "leave it alone", so the two instructions would be the same bytes.
    func testClearingTheBrandNameSendsAnExplicitNull() async {
        let transport = RepositoryTransport(json: DeskBodies.settingsWithoutBranding())

        _ = await repository(transport).updateSettings(workspaceId: "ws_1", publicBrandName: .clear)

        XCTAssertEqual(transport.bodies, [#"{"publicBrandName":null}"#])
    }

    func testSettingTheBrandNameSendsTheString() async {
        let transport = RepositoryTransport(json: DeskBodies.settings(enabled: true))

        _ = await repository(transport).updateSettings(
            workspaceId: "ws_1",
            notifyCustomersByEmail: false,
            publicBrandName: .set("Contoso")
        )

        XCTAssertEqual(transport.bodies, [#"{"notifyCustomersByEmail":false,"publicBrandName":"Contoso"}"#])
    }

    /// ⛔ AN EMPTY PATCH IS REFUSED BEFORE A ROUND TRIP IS SPENT LEARNING IT. The route
    /// answers 400 rather than a no-op 200 because an empty body is always a client
    /// bug; sending one anyway would burn a request to be told so.
    func testAPatchWithNothingToChangeIsRefusedWithoutSendingAnything() async {
        let transport = RepositoryTransport(json: DeskBodies.settings(enabled: true))

        let result = await repository(transport).updateSettings(workspaceId: "ws_1")

        XCTAssertEqual(
            result.failureOnly,
            .http(status: 400, message: "At least one setting must be provided.")
        )
        XCTAssertTrue(transport.requests.isEmpty, "nothing may be sent for an empty patch")
    }

    func testAPatchThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(json: DeskBodies.settings(enabled: true, success: false))

        let result = await repository(transport).updateSettings(workspaceId: "ws_1", enabled: true)

        XCTAssertEqual(result.failureOnly, .decoding("DeskSettingsResponse did not affirm success=true"))
    }

    // MARK: - The logo

    /// ⛔ THE WORKSPACE TRAVELS IN THE QUERY AND THE MULTIPART BODY CARRIES NO FIELDS,
    /// which is the single way this differs from `messages/media`. Asserted on the URL
    /// because the mistake is invisible in a request that otherwise looks right.
    func testUploadingALogoPutsTheWorkspaceInTheQueryAndSendsMultipart() async {
        let transport = RepositoryTransport(json: DeskBodies.settings(enabled: true))

        let result = await repository(transport).uploadLogo(
            workspaceId: "ws_1",
            fileName: "logo.png",
            mimeType: "image/png",
            // ⚠️ UTF-8-SAFE STAND-IN BYTES RATHER THAN A REAL PNG HEADER.
            // `RepositoryTransport.bodies` decodes each body as UTF-8 and DROPS one
            // that is not valid, so `Data([0x89, 0x50, 0x4E, 0x47])` makes the whole
            // multipart body vanish from that array and the framing assertions below
            // pass vacuously against an empty string. Nothing in this client parses
            // image bytes, so the payload only has to be bytes.
            bytes: Data("fake-png-bytes".utf8)
        )

        XCTAssertEqual(result.successOnly?.enabled, true)
        XCTAssertEqual(transport.requests.first?.method, .post)
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/desk/logo?workspaceId=ws_1"
        )
        let contentType = transport.requests.first?.headers["Content-Type"] ?? ""
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data;"), "got \(contentType)")
        let body = transport.bodies.first ?? ""
        XCTAssertTrue(body.contains(#"name="file"; filename="logo.png""#), "got \(body)")
        XCTAssertFalse(body.contains("workspaceId"), "the workspace must not be a form field")
    }

    /// ⚠️ THE COURTESY CHECKS RUN BEFORE ANYTHING IS SENT, and they carry the route's
    /// own statuses so the sentence a caller shows is the one a real refusal would
    /// produce. ⛔ They are not a control: the server sniffs magic numbers, so an SVG
    /// renamed `logo.png` passes here and is refused there.
    func testAnUnsupportedLogoTypeIsRefusedLocallyAsA415() async {
        let transport = RepositoryTransport(json: DeskBodies.settings(enabled: true))

        let result = await repository(transport).uploadLogo(
            workspaceId: "ws_1",
            fileName: "logo.svg",
            mimeType: "image/svg+xml",
            bytes: Data([0x3C])
        )

        XCTAssertEqual(
            result.failureOnly,
            .http(status: 415, message: "Logos must be a PNG, JPEG or WebP image.")
        )
        XCTAssertTrue(transport.requests.isEmpty, "nothing may be uploaded after a local refusal")
    }

    func testAnEmptyLogoIsRefusedLocally() async {
        let transport = RepositoryTransport(json: DeskBodies.settings(enabled: true))

        let result = await repository(transport).uploadLogo(
            workspaceId: "ws_1",
            fileName: "logo.png",
            mimeType: "image/png",
            bytes: Data()
        )

        XCTAssertEqual(result.failureOnly, .http(status: 400, message: "That file is empty."))
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testAnOversizedLogoIsRefusedLocallyAsA413() async {
        let transport = RepositoryTransport(json: DeskBodies.settings(enabled: true))

        let result = await repository(transport).uploadLogo(
            workspaceId: "ws_1",
            fileName: "logo.png",
            mimeType: "image/png",
            bytes: Data(repeating: 0x89, count: DeskLogoLimits.maximumByteCount + 1)
        )

        XCTAssertEqual(result.failureOnly, .http(status: 413, message: "Logos must be 512 KB or smaller."))
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testAnUploadThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(json: DeskBodies.settings(enabled: true, success: false))

        let result = await repository(transport).uploadLogo(
            workspaceId: "ws_1",
            fileName: "logo.png",
            mimeType: "image/png",
            bytes: Data([0x89])
        )

        XCTAssertEqual(result.failureOnly, .decoding("DeskSettingsResponse did not affirm success=true"))
    }

    /// ⛔ THE TWO HALVES OF A TAKEDOWN ARE REPORTED SEPARATELY. `objectRemoved: false`
    /// on a 200 means the image is off the tenant's customer-facing page and the bytes
    /// may still be downloadable, which is the one answer this call must never round
    /// up to "removed".
    func testRemovingALogoReportsWhetherTheStoredObjectWentToo() async {
        let transport = RepositoryTransport(json: DeskBodies.logoRemoval(objectRemoved: false))

        let result = await repository(transport).removeLogo(workspaceId: "ws_1")

        XCTAssertEqual(result.successOnly?.objectRemoved, false)
        XCTAssertNil(result.successOnly?.settings.publicLogoUrl)
        XCTAssertEqual(transport.requests.first?.method, .delete)
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/desk/logo?workspaceId=ws_1"
        )
        XCTAssertTrue(transport.bodies.isEmpty, "a DELETE on this API carries no body")
    }

    func testASuccessfulTakedownReportsTheObjectRemoved() async {
        let transport = RepositoryTransport(json: DeskBodies.logoRemoval(objectRemoved: true))

        let result = await repository(transport).removeLogo(workspaceId: "ws_1")

        XCTAssertEqual(result.successOnly?.objectRemoved, true)
    }

    func testALogoRemovalThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(json: DeskBodies.logoRemoval(objectRemoved: true, success: false))

        let result = await repository(transport).removeLogo(workspaceId: "ws_1")

        XCTAssertEqual(result.failureOnly, .decoding("DeskLogoRemovalResponse did not affirm success=true"))
    }
}
