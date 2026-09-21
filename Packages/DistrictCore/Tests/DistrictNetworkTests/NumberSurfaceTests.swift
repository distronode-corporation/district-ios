import DistrictModel
@testable import DistrictNetwork
import Foundation
import XCTest

/// The phone-number family's negative tests: what this client must NOT be able to ask
/// for, and the three places inside the family where a plausible copy-paste is a refusal.
///
/// ⛔ ITS OWN FILE RATHER THAN FIVE MORE TESTS IN `EndpointSurfaceTests.swift`, which is
/// SwiftLint's 500-line `file_length` rather than a taxonomy: that file was at 439 lines
/// and this block took it to 591. The count assertion stays there, because it is the
/// PARTITION test and belongs with the other two counters. Same cut
/// `EndpointClassification+Desk.swift` and `EndpointEnvelopes.swift` made on the source
/// side.
///
/// ⛔ AND THESE ASSERT THE ABSENCE OF A CAPABILITY, WHICH IS THE ONLY KIND OF TEST THAT
/// CAN PIN A GUARD LIKE THIS. A comment asking nobody to add a purchase route is not a
/// control; a test that walks the entire expressible surface and finds it absent is.
final class NumberSurfaceTests: XCTestCase {
    /// ⛔ `workspace/numbers/purchase` MUST NOT BE REACHABLE, AND THE REASON IS NOT THE
    /// ONE THE OTHER NEGATIVE TESTS ON THIS SURFACE HAVE. `calls/outbound` is held out
    /// because a human dialling through it would find the voice agent on their own line;
    /// `scheduling/sso` because a descriptor would spend a one-time credential on a
    /// transport nobody sees. This one is a POLICY boundary: buying a number charges a
    /// setup fee AND opens a recurring monthly charge for a service consumed inside the
    /// app, which is App Store Review Guideline 3.1.1 — an in-app purchase or it is not
    /// offered at all. Same mechanism, different argument.
    ///
    /// ⛔ AND 3.1.1 COVERS STEERING, SO THERE IS NOTHING TO TAP EITHER. That half cannot
    /// be asserted here (a URL in a copy file is not an endpoint), so it is held by
    /// ``MarketplaceCopy`` carrying no `webPath`, `webURL` or open action, and by the ⛔ at
    /// the top of `MarketplaceView.swift` — which records this exact reasoning being got
    /// wrong once under a 3.1.3(b) citation that read as diligence and was what let the
    /// button stand.
    ///
    /// ⚠️ THE SEGMENT CHECK IS THE HALF THAT KEEPS WORKING WHEN SOMEBODY ADDS A CASE. A
    /// new ``EndpointID`` spelled anything at all would still have to name the path, and
    /// the whole table is walked for it.
    func testTheNumberPurchaseRouteIsNotReachable() {
        for row in EndpointTable.all() {
            XCTAssertFalse(
                row.descriptor.segments.contains("purchase"),
                "\(row.id.rawValue) addresses workspace/numbers/purchase"
            )
        }
        XCTAssertNil(
            EndpointID(rawValue: "purchaseNumber"),
            "an EndpointID for the number purchase would make it expressible"
        )
        // The three routes that DO exist under `workspace/numbers/` beside the two reads,
        // so the assertions above are not passing merely because the family is empty.
        XCTAssertEqual(
            DistrictPaths.numbersConfigure,
            ["api", "district", "workspace", "numbers", "configure"]
        )
        XCTAssertEqual(
            DistrictPaths.numbersRelease,
            ["api", "district", "workspace", "numbers", "release"]
        )
        XCTAssertEqual(
            DistrictPaths.numbersRegistrations,
            ["api", "district", "workspace", "numbers", "registrations"]
        )
    }

    /// ⛔ THE OTP FLOW IS ABSENT TOO, AND FOR AN ORDINARY SCOPING REASON RATHER THAN A
    /// POLICY ONE — which is worth pinning precisely so the two absences are not
    /// conflated by the next reader. `workspace/verify/start` and `workspace/verify/check`
    /// are live POSTs (agency/client) that send and check a code; an OTP entry screen owns
    /// its own retry, expiry and attempt-ceiling states, so it is a feature rather than two
    /// descriptors. Nothing about them is forbidden.
    ///
    /// ⚠️ THE ASSERTION IS ON THE SEGMENTS RATHER THAN ON A CASE NAME, because the two
    /// configuration endpoints legitimately address `workspace/verify` — what must not
    /// appear is a `start` or `check` segment under it.
    func testTheOtpStartAndCheckRoutesAreNotReachable() {
        for row in EndpointTable.all() where row.descriptor.segments.contains("verify") {
            XCTAssertFalse(row.descriptor.segments.contains("start"), "\(row.id.rawValue) addresses verify/start")
            XCTAssertFalse(row.descriptor.segments.contains("check"), "\(row.id.rawValue) addresses verify/check")
        }
        XCTAssertNil(EndpointID(rawValue: "startVerification"))
        XCTAssertNil(EndpointID(rawValue: "checkVerification"))
        // The configuration route that DOES exist, which both ported verbs share.
        XCTAssertEqual(DistrictPaths.workspaceVerify, ["api", "district", "workspace", "verify"])
    }

    /// ⛔ THERE ARE **THREE** MULTIPART ROUTES NOW AND ALL THREE CARRY THE WORKSPACE
    /// DIFFERENTLY, WHICH IS WHY `EndpointSurfaceTests`' PAIR TEST IS NOT ENOUGH.
    /// `messages/media` sends `workspaceId` as a form FIELD and nothing else; `desk/logo`
    /// sends NO fields and reads the workspace off the QUERY; the registration document
    /// upload reads the workspace off the QUERY **and** sends two fields that are not the
    /// workspace. So it agrees with each neighbour on exactly one half, and a part list
    /// copied from either one is a 400 from a request whose URL reads perfectly correct.
    ///
    /// ⚠️ THE ABSENCE OF `workspaceId` FROM THE FIELDS IS ASSERTED, not just the presence
    /// of the two that belong there. A builder that sent all three keys would satisfy this
    /// route and would be exactly the copy-paste this test exists to catch.
    func testTheRegistrationUploadCarriesTwoFieldsAndNeitherIsTheWorkspace() {
        let upload = DistrictEndpoints.uploadRegistrationDocument(
            workspaceId: "ws_1",
            document: RegulatoryDocumentUpload(
                bundleId: "bun_1",
                requirementName: "business_registration_number_info",
                fileName: "extract.pdf",
                mimeType: "application/pdf",
                bytes: Data([0x25])
            )
        )
        guard case let .multipart(part) = upload.body else {
            return XCTFail("the registration document upload must be multipart")
        }
        XCTAssertEqual(
            part.fields,
            ["bundleId": "bun_1", "requirementName": "business_registration_number_info"]
        )
        XCTAssertNil(part.fields["workspaceId"], "the workspace travels in the query on this route")
        XCTAssertEqual(upload.query.map(\.name), ["workspaceId"])
    }

    /// ⛔ THE REGISTRATION ROUTES AND THE TWO NUMBER WRITES DISAGREE ABOUT WHERE THE
    /// WORKSPACE GOES, INSIDE ONE FAMILY, AND IT IS THE SERVER'S ASYMMETRY RATHER THAN A
    /// CHOICE AVAILABLE HERE. `numbers/registrations` and its children read `searchParams`
    /// before touching a body, so auth runs before `formData()` or `req.json()` can buffer
    /// anything; `numbers/configure` and `numbers/release` read `req.json()` FIRST and
    /// hand the parsed value to `requireWorkspaceRole`, so a query parameter alone is a
    /// 400 "Missing workspaceId or phoneNumber". Getting either backwards is a refusal
    /// from a request that reads correctly — the same class of mistake the ⛔ on
    /// ``DistrictPaths/deskLogo`` records for the multipart pair.
    func testTheNumberFamilyCarriesTheWorkspaceInTwoPlacesOnPurpose() throws {
        let create = DistrictEndpoints.createNumberRegistration(
            workspaceId: "ws_1",
            isoCountry: "EE",
            numberType: nil,
            endUserType: nil,
            friendlyName: nil
        )
        XCTAssertEqual(create.query.map(\.name), ["workspaceId"])
        // ⚠️ AND THE THREE NIL FIELDS ARE DROPPED RATHER THAN SENT NULL, which is what
        // lets the route's own defaults (`local`, `business`) apply.
        XCTAssertEqual(try encodedBody(create), #"{"isoCountry":"EE"}"#)

        let release = DistrictEndpoints.releaseNumber(workspaceId: "ws_1", phoneNumber: "+14165550100")
        XCTAssertTrue(release.query.isEmpty, "the release carries no query at all")
        XCTAssertEqual(try encodedBody(release), #"{"phoneNumber":"+14165550100","workspaceId":"ws_1"}"#)
    }

    /// ⛔ THE BILLABLE LOOKUP MUST ENCODE ITS `+` AS `%2B`. A literal `+` in a query value
    /// arrives at the server as a SPACE after form decoding, so the lookup would be
    /// performed for ` 14165550100` — a spent carrier call answering `valid: false`, which
    /// reads as a bad number rather than as an encoding bug. This is the exact failure
    /// ``ApiURL`` refuses `URLComponents.queryItems` over, asserted here on the one route
    /// where the wrong answer also costs money.
    func testTheBillableLookupPercentEncodesTheE164Number() throws {
        let base = try XCTUnwrap(URL(string: EndpointTable.host))
        let lookup = DistrictEndpoints.lookupNumber(workspaceId: "ws_1", phoneNumber: "+14165550100")
        XCTAssertEqual(
            ApiURL.build(base: base, segments: lookup.segments, query: lookup.query)?.absoluteString,
            "\(EndpointTable.host)/api/district/workspace/lookup?workspaceId=ws_1&phoneNumber=%2B14165550100"
        )
        XCTAssertEqual(lookup.method, .get, "a GET that costs money, which is the trap")
    }

    /// ⚠️ A SECOND COPY OF `EndpointSurfaceTests`' OWN PRIVATE HELPER, because `private`
    /// is file scope in Swift and it is four lines. Extracting it into a shared helper
    /// would be a third file for a `guard case` and a `XCTUnwrap`.
    private func encodedBody(_ descriptor: ApiRequestDescriptor) throws -> String {
        guard case let .json(value) = descriptor.body else {
            throw XCTSkip("the descriptor carries no JSON body")
        }
        return try XCTUnwrap(String(data: JSONWire.encode(value), encoding: .utf8))
    }
}
