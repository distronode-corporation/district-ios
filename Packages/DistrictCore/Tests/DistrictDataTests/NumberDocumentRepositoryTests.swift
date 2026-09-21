import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// The documents on a filing, and the one moment a filing leaves the platform.
///
/// ⛔ THE TWO IRREVERSIBLE-ISH THINGS IN THIS FILE ARE NOT THE SAME KIND. A document
/// upload is idempotent (one document per requirement; a re-upload REPLACES it), while a
/// submit files a regulated application in the customer's name and is
/// ``NumberWriteRepeat/once``. Nothing here retries anything automatically.
final class NumberDocumentRepositoryTests: XCTestCase {
    // MARK: - Uploading

    /// ⛔ THE UPLOAD'S REPLY IS NOT A LIST ROW, WHICH IS WHY IT HAS ITS OWN TYPE. It
    /// answers `createdAt` rather than `updatedAt` and carries neither `stored` nor
    /// `submitted`, so a caller cannot splice it into a registration's documents array —
    /// and inventing the two booleans would claim the carrier holds a copy it does not.
    func testAnUploadAnswersItsOwnNarrowRowRatherThanAListRow() async throws {
        let transport = RepositoryTransport(json: NumberProvisioningBodies.documentUploaded)

        let result = await NumbersRepository(client: .repositoryTest(transport)).uploadRegistrationDocument(
            workspaceId: "ws_1",
            document: RegulatoryDocumentUpload(
                bundleId: "bun_1",
                requirementName: "business_registration_number_info",
                fileName: "extract.pdf",
                mimeType: "application/pdf",
                bytes: Data([0x25, 0x50, 0x44, 0x46])
            )
        )

        let document = try XCTUnwrap(result.successOnly).document
        XCTAssertEqual(document.id, "doc_1")
        XCTAssertEqual(document.mimeType, "application/pdf", "the SNIFFED type, not the declared one")
        XCTAssertEqual(document.sizeBytes, 1024)
        XCTAssertEqual(document.createdAt, "2026-09-07T09:41:00.000Z")
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/workspace/numbers/registrations/documents?workspaceId=ws_1"
        )
        XCTAssertEqual(transport.requests.first?.method, .post)
        XCTAssertNotNil(transport.requests.first?.body, "the parts are sent")
    }

    /// ⚠️ THE ROUTE'S REFUSALS ARE NOT ALL 400 AND THIS LAYER TRANSLATES NONE OF THEM. A
    /// **415** for bytes that disagree with the declared type names both, which is the one
    /// sentence a customer can act on ("re-export it"); re-authoring it here would replace
    /// a remedy with a shrug.
    func testAMimeTypeMismatchArrivesAsA415CarryingTheServersOwnSentence() async {
        let transport = RepositoryTransport(json: NumberProvisioningBodies.documentSniffMismatch, status: 415)

        let result = await NumbersRepository(client: .repositoryTest(transport)).uploadRegistrationDocument(
            workspaceId: "ws_1",
            document: RegulatoryDocumentUpload(
                bundleId: "bun_1",
                requirementName: "business_registration_number_info",
                fileName: "extract.pdf",
                mimeType: "application/pdf",
                bytes: Data([0x89, 0x50, 0x4E, 0x47])
            )
        )

        XCTAssertEqual(result.failureOnly?.httpStatus, 415)
        XCTAssertEqual(result.failureOnly?.message, NumberProvisioningBodies.sniffMismatchMessage)
    }

    /// ⚠️ A SUBMITTED FILING IS A **409**, NOT A 403, and the distinction matters to the
    /// wording: the request is well-formed and will be valid again if the review comes back
    /// rejected. A 403 would read as "you are not allowed to do this", which is false.
    func testAddingADocumentToASubmittedFilingIsA409RatherThanA403() async {
        let transport = RepositoryTransport(json: NumberProvisioningBodies.documentNotDraft, status: 409)

        let result = await NumbersRepository(client: .repositoryTest(transport)).uploadRegistrationDocument(
            workspaceId: "ws_1",
            document: RegulatoryDocumentUpload(
                bundleId: "bun_1",
                requirementName: "business_registration_number_info",
                fileName: "extract.pdf",
                mimeType: "application/pdf",
                bytes: Data([0x25])
            )
        )

        XCTAssertEqual(result.failureOnly?.httpStatus, 409)
        XCTAssertNil(result.successOnly)
    }

    func testAnUploadBodyThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(json: NumberProvisioningBodies.documentUploadRefused)

        let result = await NumbersRepository(client: .repositoryTest(transport)).uploadRegistrationDocument(
            workspaceId: "ws_1",
            document: RegulatoryDocumentUpload(
                bundleId: "bun_1",
                requirementName: "business_registration_number_info",
                fileName: "extract.pdf",
                mimeType: "application/pdf",
                bytes: Data([0x25])
            )
        )

        XCTAssertEqual(result.failureOnly, .decoding("RegistrationDocumentResponse did not affirm success=true"))
    }

    // MARK: - Removing

    /// ⛔ THE ONLY DELETE ON THIS API THAT CARRIES A BODY, and both ids are in it while the
    /// workspace is in the query. A client that sent the ids as query parameters gets a
    /// 400 from a URL that looks entirely reasonable.
    ///
    /// ⚠️ THE ECHOED ID IS WHAT A CALLER SHOULD DROP, rather than the one it sent: the two
    /// agreeing is the server's confirmation rather than this client's assumption.
    func testRemovingADocumentSendsBothIdsInTheBodyAndTheWorkspaceInTheQuery() async throws {
        let transport = RepositoryTransport(json: NumberProvisioningBodies.documentRemoved)

        let result = await NumbersRepository(client: .repositoryTest(transport)).deleteRegistrationDocument(
            workspaceId: "ws_1",
            bundleId: "bun_1",
            documentId: "doc_1"
        )

        XCTAssertEqual(try XCTUnwrap(result.successOnly).documentId, "doc_1", "echoed, not assumed")
        XCTAssertEqual(transport.requests.first?.method, .delete)
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/workspace/numbers/registrations/documents?workspaceId=ws_1"
        )
        XCTAssertEqual(transport.bodies.first, #"{"bundleId":"bun_1","documentId":"doc_1"}"#)
    }

    /// ⛔ A **502 CHANGED NOTHING AND THE ROW IS STILL THERE.** This route deletes the
    /// object first and the row second — the opposite of the desk logo's order — because
    /// `storageKey` is the only pointer to the bytes and dropping the row first would
    /// abandon an identity document in a bucket under a name nobody can reconstruct. So a
    /// failed removal is retryable and must not be drawn as done.
    func testAFailedObjectDeleteIsA502ThatLeavesTheRowInPlace() async {
        let transport = RepositoryTransport(json: NumberProvisioningBodies.documentRemovalRefused, status: 502)

        let result = await NumbersRepository(client: .repositoryTest(transport)).deleteRegistrationDocument(
            workspaceId: "ws_1",
            bundleId: "bun_1",
            documentId: "doc_1"
        )

        XCTAssertEqual(result.failureOnly?.httpStatus, 502)
        XCTAssertNil(result.successOnly)
    }

    func testADocumentRemovalBodyThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(json: #"{"success":false,"documentId":"doc_1"}"#)

        let result = await NumbersRepository(client: .repositoryTest(transport)).deleteRegistrationDocument(
            workspaceId: "ws_1",
            bundleId: "bun_1",
            documentId: "doc_1"
        )

        XCTAssertEqual(
            result.failureOnly,
            .decoding("RegistrationDocumentRemovalResponse did not affirm success=true")
        )
    }

    // MARK: - Submitting

    /// ⚠️ THE REPLY IS THREE FIELDS, NOT A WHOLE ROW, so a screen has to merge it into the
    /// registration it already holds rather than replacing it.
    func testASubmitAnswersThreeFieldsToBeMergedIntoTheRowInHand() async throws {
        let transport = RepositoryTransport(json: NumberProvisioningBodies.submitAccepted)

        let result = await NumbersRepository(client: .repositoryTest(transport)).submitRegistration(
            workspaceId: "ws_1",
            bundleId: "bun_1",
            endUserAttributes: ["business_name": .string("Contoso Baltics")]
        )

        let registration = try XCTUnwrap(result.successOnly).registration
        XCTAssertEqual(registration.id, "bun_1")
        XCTAssertEqual(registration.status, "pending-review")
        XCTAssertEqual(registration.submittedAt, "2026-09-07T09:41:00.000Z")
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/workspace/numbers/registrations/submit?workspaceId=ws_1"
        )
        XCTAssertEqual(
            transport.bodies.first,
            #"{"bundleId":"bun_1","endUserAttributes":{"business_name":"Contoso Baltics"}}"#
        )
    }

    /// ⚠️ `endUserAttributes` IS SENT EVEN WHEN EMPTY, so a captured request says "no
    /// attributes were supplied" rather than "this client forgot the key". The route reads
    /// `?? {}` so both work; the explicit one is the honest one.
    func testAnEmptyAttributeSetIsSentAsAnExplicitEmptyObject() async {
        let transport = RepositoryTransport(json: NumberProvisioningBodies.submitAccepted)

        _ = await NumbersRepository(client: .repositoryTest(transport)).submitRegistration(
            workspaceId: "ws_1",
            bundleId: "bun_1",
            endUserAttributes: [:]
        )

        XCTAssertEqual(transport.bodies.first, #"{"bundleId":"bun_1","endUserAttributes":{}}"#)
    }

    /// ⛔ A **422 IS "YOUR PAPERWORK IS WRONG"** AND A **502 IS "WE COULD NOT REACH THE
    /// CARRIER"**, AND BOTH ARRIVE AS PLAIN FAILURES CARRYING ONLY THEIR SENTENCE. The
    /// 422's `failures` and `reasons` do NOT survive ``ApiError`` — the fixture carries
    /// both so the loss is exercised rather than assumed — which is why the screen's
    /// obligation after a refusal is to re-read the filing list, where the route stored
    /// them verbatim.
    func testTheTwoSubmitRefusalsStayDistinctAndCarryOnlyTheirSentence() async {
        let refused = RepositoryTransport(json: NumberProvisioningBodies.submitEvaluationFailed, status: 422)
        let unreachable = RepositoryTransport(json: NumberProvisioningBodies.submitCarrierUnreachable, status: 502)

        let paperwork = await NumbersRepository(client: .repositoryTest(refused)).submitRegistration(
            workspaceId: "ws_1",
            bundleId: "bun_1",
            endUserAttributes: [:]
        )
        let carrier = await NumbersRepository(client: .repositoryTest(unreachable)).submitRegistration(
            workspaceId: "ws_1",
            bundleId: "bun_1",
            endUserAttributes: [:]
        )

        XCTAssertEqual(paperwork.failureOnly?.httpStatus, 422)
        XCTAssertEqual(paperwork.failureOnly?.message, NumberProvisioningBodies.evaluationFailedMessage)
        XCTAssertEqual(carrier.failureOnly?.httpStatus, 502)
    }

    func testASubmitBodyThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(json: NumberProvisioningBodies.submitRefused)

        let result = await NumbersRepository(client: .repositoryTest(transport)).submitRegistration(
            workspaceId: "ws_1",
            bundleId: "bun_1",
            endUserAttributes: [:]
        )

        XCTAssertEqual(result.failureOnly, .decoding("NumberRegistrationSubmitResponse did not affirm success=true"))
    }
}
