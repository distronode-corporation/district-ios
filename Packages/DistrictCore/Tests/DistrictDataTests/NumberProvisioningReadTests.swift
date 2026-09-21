import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// Carrier connectivity and the regulatory reads.
///
/// ⛔ NOTHING HERE BUYS A NUMBER, AND THERE IS NO METHOD TO TEST. App Store Review
/// Guideline 3.1.1: a setup fee plus a recurring monthly charge for a service consumed
/// inside the app is an in-app purchase or it is not offered at all. Its absence is
/// asserted in `NumberSurfaceTests`, against the whole expressible surface, rather than
/// here.
///
/// ⛔ AND THE ASSERTIONS BELOW ARE ABOUT WHICH OUTCOMES STAY DISTINCT, because this half
/// of the family has three pairs that look alike and mean different things: a
/// disconnected workspace against a healthy one (two key sets, one letter apart); "no
/// registration is required" against "we could not ask"; and an empty filing list against
/// a failed read. Flattening any of them produces a screen that is confidently wrong about
/// a customer's phone lines.
final class NumberProvisioningReadTests: XCTestCase {
    // MARK: - Which carriers are connected

    /// ⛔ THE DISCONNECTED BRANCH IS AN ORDINARY ANSWER AND MUST DECODE. It sends
    /// `{connected:false, provider:null}` — SINGULAR `provider`, always null, and no
    /// `providers` map at all. A decoder modelling only the plural would read every fresh
    /// workspace as contract drift.
    func testADisconnectedWorkspaceDecodesTheSingularNullProviderBranch() async throws {
        let transport = RepositoryTransport(json: NumberProvisioningBodies.providerStatusDisconnected)

        let result = await NumbersRepository(client: .repositoryTest(transport)).providerStatus(workspaceId: "ws_1")

        let response = try XCTUnwrap(result.successOnly)
        XCTAssertFalse(response.connected)
        XCTAssertNil(response.providers, "the plural key is absent on this branch")
        XCTAssertNil(response.provider, "and the singular one is an explicit null")
        XCTAssertEqual(response.connectedProviders, [])
        XCTAssertEqual(response.refusedProviders, [])
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/workspace/provider/status?workspaceId=ws_1"
        )
    }

    /// ⛔ A CARRIER THAT REFUSED ITS CREDENTIALS IS CONTENT, NOT A FAILURE, and the
    /// top-level `connected` can be true beside it. So the two derived lists are separate
    /// rather than complements: "use this one" and "this one's keys stopped working" are
    /// different sentences, and collapsing them turns a fixable configuration problem into
    /// an absence.
    ///
    /// ⚠️ BOTH LISTS ARE SORTED, because a JSON object has no order and rows drawn from one
    /// would otherwise reshuffle between reads.
    func testAPartlyRefusedAccountKeepsTheWorkingCarrierAndNamesTheRefusedOne() async throws {
        let transport = RepositoryTransport(json: NumberProvisioningBodies.providerStatusMixed)

        let result = await NumbersRepository(client: .repositoryTest(transport)).providerStatus(workspaceId: "ws_1")

        let response = try XCTUnwrap(result.successOnly)
        XCTAssertTrue(response.connected, "one carrier answered")
        XCTAssertEqual(response.connectedProviders, ["twilio"])
        XCTAssertEqual(response.refusedProviders, ["telnyx"])
        XCTAssertEqual(response.providers?["twilio"]?.balance, "12.34", "a STRING on the wire")
        XCTAssertEqual(response.providers?["twilio"]?.numberCount, 3)
        XCTAssertEqual(response.providers?["telnyx"]?.error, "Invalid credentials")
    }

    /// ⛔ A MANAGED ENTRY REPORTS CONNECTIVITY AND NOTHING ELSE, AND THAT IS A PRIVACY
    /// PROPERTY RATHER THAN A GAP. `getAccountInfo` describes the AUTHENTICATING account,
    /// which for a managed provider is the platform's own — so a name, a balance or a
    /// number count here would be Distronode's figures plus every other managed tenant's.
    /// This route had no managed short-circuit at all once, which is what made the
    /// platform's balance readable by any member of any workspace flagged managed.
    func testAManagedCarrierReportsConnectivityWithNoAccountFigures() async throws {
        let transport = RepositoryTransport(json: NumberProvisioningBodies.providerStatusManaged)

        let result = await NumbersRepository(client: .repositoryTest(transport)).providerStatus(workspaceId: "ws_1")

        let entry = try XCTUnwrap(result.successOnly?.providers?["twilio"])
        XCTAssertEqual(entry.managed, true)
        XCTAssertNil(entry.accountName)
        XCTAssertNil(entry.balance, "⛔ the platform's balance is not this caller's")
        XCTAssertNil(entry.numberCount)
        XCTAssertNil(entry.status)
    }

    /// ⛔ NO ENVELOPE TO AFFIRM ON THIS ROUTE — it sends no `success` flag at all — so the
    /// guard against a thin body is the required `connected`. A `{}` must be a decode
    /// failure rather than a confident "no carrier connected".
    func testAnEmptyProviderStatusBodyIsADecodeFailureRatherThanADisconnectedAnswer() async throws {
        let transport = RepositoryTransport(json: "{}")

        let result = await NumbersRepository(client: .repositoryTest(transport)).providerStatus(workspaceId: "ws_1")

        XCTAssertNil(result.successOnly, "⛔ never a confident 'no carrier connected'")
        let failure = try XCTUnwrap(result.failureOnly)
        XCTAssertTrue(failure.isShapeMismatch)
    }

    // MARK: - What the regulator asks for

    /// ⛔ A NULL `requirements` MEANS NO REGISTRATION IS REQUIRED, NOT THAT THE LOOKUP
    /// FAILED. It is a real and common answer and it arrives on a 200; a failed lookup
    /// throws server-side and arrives as a 500. Collapsing them tells a customer to file
    /// paperwork that does not exist, or that none is needed when nobody could ask.
    ///
    /// ⛔ AND `purchasable` IS INDEPENDENT: here it is FALSE while the requirements are
    /// null, the combination a reader would least expect and exactly why neither may be
    /// inferred from the other.
    func testACountryWithNoPublishedRegulationIsASuccessCarryingANullRequirements() async throws {
        let transport = RepositoryTransport(json: NumberProvisioningBodies.requirementsNone)

        let result = await NumbersRepository(client: .repositoryTest(transport)).numberRequirements(
            workspaceId: "ws_1",
            country: "US",
            numberType: "local",
            endUserType: "business"
        )

        let response = try XCTUnwrap(result.successOnly)
        XCTAssertNil(response.requirements, "no regulation is published for this pair")
        XCTAssertFalse(response.purchasable, "⛔ and it is still not purchasable, independently")
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/workspace/numbers/requirements"
                + "?workspaceId=ws_1&country=US&type=local&endUserType=business"
        )
    }

    /// ⚠️ THE QUERY PARAMETER IS `type`, NOT `numberType`, AND THE TWO OPTIONAL FILTERS
    /// ARE DROPPED WHEN ABSENT so the route's own defaults apply. Asserted on the URL,
    /// since the whole difference is there.
    func testTheOptionalRequirementFiltersAreDroppedRatherThanSentEmpty() async {
        let transport = RepositoryTransport(json: NumberProvisioningBodies.requirementsNone)

        _ = await NumbersRepository(client: .repositoryTest(transport)).numberRequirements(
            workspaceId: "ws_1",
            country: "EE"
        )

        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/workspace/numbers/requirements?workspaceId=ws_1&country=EE"
        )
    }

    /// ⛔ THE TWO KINDS OF REQUIREMENT ARE SATISFIED BY DIFFERENT ACTIONS, so a screen has
    /// to tell them apart: `end_user` entries are FIELDS sent in the submit,
    /// `supporting_document` entries are FILES uploaded one at a time against
    /// `requirementName`. Treating one as the other builds a bundle the carrier refuses
    /// for a reason the customer cannot see in their own form.
    func testARegulationKeepsFieldRequirementsAndDocumentRequirementsDistinct() async throws {
        let transport = RepositoryTransport(json: NumberProvisioningBodies.requirementsEstonia)

        let result = await NumbersRepository(client: .repositoryTest(transport)).numberRequirements(
            workspaceId: "ws_1",
            country: "EE"
        )

        let regulation = try XCTUnwrap(result.successOnly?.requirements)
        XCTAssertEqual(regulation.regulationSid, "RN1")
        XCTAssertEqual(regulation.requirements.count, 2)
        XCTAssertEqual(regulation.requirements.first?.kind, "end_user")
        XCTAssertEqual(regulation.requirements.first?.fields, ["business_name"])
        XCTAssertNil(regulation.requirements.first?.acceptedDocuments, "a field requirement accepts no file")
        XCTAssertEqual(regulation.requirements.last?.kind, "supporting_document")
        XCTAssertEqual(
            regulation.requirements.last?.requirementName,
            "business_registration_number_info",
            "⛔ the machine name, which is what an upload must send"
        )
        XCTAssertEqual(regulation.requirements.last?.acceptedDocuments?.count, 1)
    }

    func testARequirementsBodyThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(json: NumberProvisioningBodies.requirementsRefused)

        let result = await NumbersRepository(client: .repositoryTest(transport)).numberRequirements(
            workspaceId: "ws_1",
            country: "EE"
        )

        XCTAssertEqual(result.failureOnly, .decoding("NumberRequirementsResponse did not affirm success=true"))
    }

    // MARK: - The workspace's own filings

    /// ⛔ THE TWO COUNTRY LISTS ARE NOT THE SAME THING AND A GATE NEEDS BOTH.
    /// `approvedCountries` is where THIS workspace's filings were approved;
    /// `platformCountries` is where a number sells against Distronode's own registration
    /// with no filing by the tenant at all. The body they are read from deliberately
    /// disagrees, so a test cannot pass by reading either for the other.
    func testTheRegistrationListCarriesBothCountryGatesSeparately() async throws {
        let transport = RepositoryTransport(json: NumberProvisioningBodies.registrationsOneDraft)

        let result = await NumbersRepository(client: .repositoryTest(transport))
            .numberRegistrations(workspaceId: "ws_1")

        let response = try XCTUnwrap(result.successOnly)
        XCTAssertEqual(response.approvedCountries, ["DE"])
        XCTAssertEqual(response.platformCountries, ["EE"])
        XCTAssertEqual(response.registrations.count, 1)
        XCTAssertEqual(response.registrations.first?.status, "draft")
        XCTAssertEqual(response.registrations.first?.documents.count, 0)
        XCTAssertNil(response.registrations.first?.friendlyName, "an explicit null on the wire")
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/workspace/numbers/registrations?workspaceId=ws_1"
        )
    }

    /// ⛔ A REFUSED FILING'S REASONS ARE THE ONLY PLACE THE SUBMIT'S 422 DETAIL SURVIVES,
    /// which is why this list is what a screen re-reads after a refusal: `ApiError` keeps
    /// the sentence and drops `failures` and `reasons`, and the route stores the carrier's
    /// structured failures verbatim on the row.
    ///
    /// ⚠️ AND `reviewedAt` IS STAMPED ONLY ON A TERMINAL VERDICT, so a non-null value here
    /// always means approved or rejected rather than "the review started".
    func testARejectedFilingCarriesReadableReasonsAndATerminalReviewedAt() async throws {
        let transport = RepositoryTransport(json: NumberProvisioningBodies.registrationsRejected)

        let result = await NumbersRepository(client: .repositoryTest(transport))
            .numberRegistrations(workspaceId: "ws_1")

        let row = try XCTUnwrap(result.successOnly?.registrations.first)
        XCTAssertEqual(row.status, "twilio-rejected")
        XCTAssertEqual(row.rejectionReasons, ["The registry extract is unreadable."])
        XCTAssertNotNil(row.reviewedAt, "a terminal verdict is dated")
        XCTAssertNotNil(row.submittedAt)
        let document = try XCTUnwrap(row.documents.first)
        XCTAssertTrue(document.stored)
        XCTAssertTrue(document.submitted, "the carrier holds a copy of this one")
        XCTAssertEqual(document.sizeBytes, 2048)
    }

    /// ⛔ AN EMPTY LIST IS A REAL ANSWER AND A FAILED READ IS NOT ONE. "Nothing filed yet"
    /// is where every workspace starts and is the screen a customer is told to start from,
    /// so rendering "we could not look" as that would invite a duplicate filing.
    func testAnEmptyFilingListStaysDistinctFromAFailedRead() async throws {
        let empty = RepositoryTransport(json: NumberProvisioningBodies.registrationsEmpty)
        let broken = RepositoryTransport(json: #"{"error":"Internal error"}"#, status: 500)

        let none = await NumbersRepository(client: .repositoryTest(empty)).numberRegistrations(workspaceId: "ws_1")
        let failed = await NumbersRepository(client: .repositoryTest(broken)).numberRegistrations(workspaceId: "ws_1")

        XCTAssertTrue(try XCTUnwrap(none.successOnly).registrations.isEmpty, "nothing filed is an answer")
        XCTAssertEqual(failed.failureOnly?.httpStatus, 500)
        XCTAssertNil(failed.successOnly)
    }

    func testARegistrationListThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(json: NumberProvisioningBodies.registrationsRefused)

        let result = await NumbersRepository(client: .repositoryTest(transport))
            .numberRegistrations(workspaceId: "ws_1")

        XCTAssertEqual(result.failureOnly, .decoding("NumberRegistrationsResponse did not affirm success=true"))
    }

    /// ⛔ THE WORKSPACE IS IN THE QUERY ON A POST, and the four filing fields are the whole
    /// body. Asserted on the bytes, because the difference between the two conventions in
    /// this family is entirely in where one key sits.
    func testCreatingADraftPutsTheWorkspaceInTheQueryAndTheFilingInTheBody() async throws {
        let transport = RepositoryTransport(json: NumberProvisioningBodies.registrationCreated)

        let result = await NumbersRepository(client: .repositoryTest(transport)).createRegistration(
            workspaceId: "ws_1",
            isoCountry: "EE",
            numberType: "local",
            endUserType: "business",
            friendlyName: "Contoso Baltics"
        )

        XCTAssertEqual(try XCTUnwrap(result.successOnly).registration.status, "draft")
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/workspace/numbers/registrations?workspaceId=ws_1"
        )
        XCTAssertEqual(
            transport.bodies.first,
            #"{"endUserType":"business","friendlyName":"Contoso Baltics","isoCountry":"EE","numberType":"local"}"#
        )
    }

    /// ⚠️ THE OPTIONAL FILING FIELDS ARE DROPPED RATHER THAN SENT NULL, which is what lets
    /// the route's own defaults (`local`, `business`) apply and what keeps a blank friendly
    /// name out of a customer's Twilio console.
    func testTheOptionalDraftFieldsAreDroppedSoTheServersDefaultsApply() async {
        let transport = RepositoryTransport(json: NumberProvisioningBodies.registrationCreated)

        _ = await NumbersRepository(client: .repositoryTest(transport)).createRegistration(
            workspaceId: "ws_1",
            isoCountry: "EE"
        )

        XCTAssertEqual(transport.bodies.first, #"{"isoCountry":"EE"}"#)
    }

    /// ⚠️ BOTH 409s ARE ORDINARY ANSWERS RATHER THAN FAULTS AND THE SERVER'S SENTENCE IS
    /// WHAT DISTINGUISHES THEM: "you already have one for this pair", and "this pair
    /// publishes no regulation, so there is nothing to file". The second is a success in
    /// disguise, and this layer deliberately does not try to tell them apart.
    func testADuplicateDraftPassesTheServersOwn409SentenceThrough() async {
        let transport = RepositoryTransport(json: NumberProvisioningBodies.registrationDuplicate, status: 409)

        let result = await NumbersRepository(client: .repositoryTest(transport)).createRegistration(
            workspaceId: "ws_1",
            isoCountry: "EE"
        )

        XCTAssertEqual(result.failureOnly?.httpStatus, 409)
        XCTAssertEqual(result.failureOnly?.message, NumberProvisioningBodies.duplicateRegistrationMessage)
    }

    func testACreatedDraftBodyThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(json: NumberProvisioningBodies.registrationCreatedRefused)

        let result = await NumbersRepository(client: .repositoryTest(transport)).createRegistration(
            workspaceId: "ws_1",
            isoCountry: "EE"
        )

        XCTAssertEqual(result.failureOnly, .decoding("NumberRegistrationCreatedResponse did not affirm success=true"))
    }
}
