import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// The carrier-account surfaces: SIP trunking, the Verify (OTP) service, A2P 10DLC,
/// toll-free verification, and the billable lookup.
///
/// ⛔ TWO OF THESE FLOWS HAVE **NO STATUS READ ANYWHERE**, which is what these tests are
/// really about. A2P and toll-free verification answer the only report either will ever
/// produce, so the assertions below are that every field of that answer survives — there
/// is no second request that could recover a dropped one.
///
/// ⛔ AND FOUR OF THE FIVE WRITES SPEND MONEY NO RETRY UNDOES: a carrier brand fee, a
/// monthly campaign fee, a $25/month SIP billing item with no route to cancel it, and a
/// billable OTP sender that outlives our pointer to it. The lookup is the fifth and is the
/// easiest to spend by accident, being a cheap GET that admits `viewer`.
final class CarrierAccountRepositoryTests: XCTestCase {
    // MARK: - SIP trunking

    /// ⛔ A LEGACY ROW WITH BOTH SIDS NULL DESCRIBES A BILLING ITEM WITH NO TWILIO
    /// RESOURCES BEHIND IT, and that is worth surfacing rather than hiding. The list parses
    /// its rows out of a packed `productRef` string, so a row written before real
    /// provisioning was wired up carries neither sid — which is why both are Optional.
    func testTheTrunkListDecodesBothProvisionedAndLegacyRows() async throws {
        let transport = RepositoryTransport(json: NumberProvisioningBodies.sipTrunksMixed)

        let result = await NumbersRepository(client: .repositoryTest(transport)).sipTrunks(workspaceId: "ws_1")

        let trunks = try XCTUnwrap(result.successOnly).trunks
        XCTAssertEqual(trunks.count, 2)
        XCTAssertEqual(trunks.first?.domainSid, "SD1")
        XCTAssertEqual(trunks.first?.ipAccessControlList, ["203.0.113.7"])
        XCTAssertNil(trunks.last?.domainSid, "⛔ a billing item with no Twilio resource behind it")
        XCTAssertNil(trunks.last?.ipAclSid)
        XCTAssertEqual(trunks.last?.ipAccessControlList, [], "present and empty, not absent")
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/workspace/sip?workspaceId=ws_1"
        )
    }

    /// ⛔ AN EMPTY LIST IS A REAL ANSWER AND A FAILED READ IS NOT ONE. Most workspaces have
    /// no SIP trunk at all, so "we could not look" drawn as "you have none" would invite a
    /// duplicate provision — and a duplicate is a second $25/month with no route to cancel
    /// either of them.
    func testAnEmptyTrunkListStaysDistinctFromAFailedRead() async throws {
        let empty = RepositoryTransport(json: NumberProvisioningBodies.sipTrunksEmpty)
        let broken = RepositoryTransport(json: #"{"error":"Internal error"}"#, status: 500)

        let none = await NumbersRepository(client: .repositoryTest(empty)).sipTrunks(workspaceId: "ws_1")
        let failed = await NumbersRepository(client: .repositoryTest(broken)).sipTrunks(workspaceId: "ws_1")

        XCTAssertTrue(try XCTUnwrap(none.successOnly).trunks.isEmpty)
        XCTAssertEqual(failed.failureOnly?.httpStatus, 500)
        XCTAssertNil(failed.successOnly)
    }

    func testATrunkListThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(json: #"{"success":false,"trunks":[]}"#)

        let result = await NumbersRepository(client: .repositoryTest(transport)).sipTrunks(workspaceId: "ws_1")

        XCTAssertEqual(result.failureOnly, .decoding("SipTrunksResponse did not affirm success=true"))
    }

    /// ⚠️ `domain` IS THE LABEL ONLY — the route appends `.sip.twilio.com` — and the echoed
    /// trunk carries the fully-qualified name plus real sids, so it can be adopted without
    /// a re-read.
    func testCreatingATrunkSendsTheLabelAndAdoptsTheQualifiedDomainBack() async throws {
        let transport = RepositoryTransport(json: NumberProvisioningBodies.sipTrunkCreated)

        let result = await NumbersRepository(client: .repositoryTest(transport)).createSipTrunk(
            workspaceId: "ws_1",
            name: "Front desk",
            domain: "contoso",
            ipAccessControlList: ["203.0.113.7", "198.51.100.0/24"]
        )

        let trunk = try XCTUnwrap(result.successOnly).trunk
        XCTAssertEqual(trunk.domain, "contoso.sip.twilio.com", "qualified by the server, not by us")
        XCTAssertEqual(trunk.domainSid, "SD2")
        XCTAssertEqual(trunk.ipAclSid, "AL2")
        // ⚠️ NORMALISED: the CIDR carries a `/`, which `JSONEncoder` escapes on Linux and
        // not on Darwin. See ``unescapeSlashes(_:)``.
        XCTAssertEqual(
            transport.bodies.first.map(Self.unescapeSlashes),
            #"{"domain":"contoso","ipAccessControlList":["203.0.113.7","198.51.100.0/24"],"#
                + #""name":"Front desk","workspaceId":"ws_1"}"#
        )
    }

    /// ⚠️ IT REQUIRES TWILIO SPECIFICALLY, and that **400** is an account state rather than
    /// a fault: no retry fixes it, so it must not be drawn with a retry button.
    func testAnUnsupportedCarrierRefusesTheTrunkCreateWithA400() async {
        let transport = RepositoryTransport(json: NumberProvisioningBodies.sipRequiresTwilio, status: 400)

        let result = await NumbersRepository(client: .repositoryTest(transport)).createSipTrunk(
            workspaceId: "ws_1",
            name: "Front desk",
            domain: "contoso",
            ipAccessControlList: ["203.0.113.7"]
        )

        XCTAssertEqual(result.failureOnly?.httpStatus, 400)
        XCTAssertNil(result.successOnly)
    }

    // MARK: - The Verify (OTP) service

    /// ⛔ THE OFF STATE ARRIVES TWO DIFFERENT WAYS AND BOTH MUST DECODE. The GET sends
    /// `verifyServiceSid: null`; the DISABLE reply omits the key entirely. Both mean the
    /// same thing to this client, and the pair is the reason the field is Optional rather
    /// than merely nullable.
    func testTheServiceReadsOffAsAnExplicitNullAndDisablesWithTheKeyAbsent() async throws {
        let onRead = RepositoryTransport(json: NumberProvisioningBodies.verifyOffOnRead)
        let onDisable = RepositoryTransport(json: NumberProvisioningBodies.verifyDisabled)

        let read = await NumbersRepository(client: .repositoryTest(onRead)).verifyService(workspaceId: "ws_1")
        let disabled = await NumbersRepository(client: .repositoryTest(onDisable))
            .setVerifyServiceEnabled(workspaceId: "ws_1", enabled: false)

        XCTAssertFalse(try XCTUnwrap(read.successOnly).enabled)
        XCTAssertNil(try XCTUnwrap(read.successOnly).verifyServiceSid, "explicit null on the read")
        XCTAssertFalse(try XCTUnwrap(disabled.successOnly).enabled)
        XCTAssertNil(try XCTUnwrap(disabled.successOnly).verifyServiceSid, "absent on the disable reply")
        XCTAssertEqual(
            onRead.requestedURLs.first,
            "https://www.distronode.com/api/district/workspace/verify?workspaceId=ws_1"
        )
        XCTAssertEqual(onDisable.bodies.first, #"{"enabled":false,"workspaceId":"ws_1"}"#)
    }

    /// ⚠️ A REAL BOOLEAN, NOT A STRING. The route checks `typeof enabled !== "boolean"` and
    /// answers 400 "Missing required fields" for anything else, which reads as a missing key
    /// rather than a wrong type. ⚠️ And the enable reply is adoptable, which is why this
    /// write needs no re-read.
    func testEnablingTheServiceSendsARealBooleanAndAdoptsTheSidBack() async throws {
        let transport = RepositoryTransport(json: NumberProvisioningBodies.verifyEnabled)

        let result = await NumbersRepository(client: .repositoryTest(transport))
            .setVerifyServiceEnabled(workspaceId: "ws_1", enabled: true)

        let response = try XCTUnwrap(result.successOnly)
        XCTAssertTrue(response.enabled)
        XCTAssertEqual(response.verifyServiceSid, "VA1")
        XCTAssertEqual(transport.bodies.first, #"{"enabled":true,"workspaceId":"ws_1"}"#)
        XCTAssertEqual(transport.requests.first?.method, .post, "a POST, not a PATCH")
    }

    func testAVerifyBodyThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let read = RepositoryTransport(json: NumberProvisioningBodies.verifyRefused)
        let write = RepositoryTransport(json: NumberProvisioningBodies.verifyRefused)

        let onRead = await NumbersRepository(client: .repositoryTest(read)).verifyService(workspaceId: "ws_1")
        let onWrite = await NumbersRepository(client: .repositoryTest(write))
            .setVerifyServiceEnabled(workspaceId: "ws_1", enabled: true)

        XCTAssertEqual(onRead.failureOnly, .decoding("VerifyServiceResponse did not affirm success=true"))
        XCTAssertEqual(onWrite.failureOnly, .decoding("VerifyServiceResponse did not affirm success=true"))
    }

    // MARK: - A2P 10DLC

    /// ⛔ EVERY FIELD OF THIS ANSWER MUST SURVIVE, BECAUSE THERE IS NO STATUS READ TO
    /// RECOVER A DROPPED ONE. `brandSid` names an object a one-time carrier fee was paid
    /// for and `campaignSid` names one a monthly fee hangs off, so losing either leaves an
    /// operator unable to say what they now own.
    ///
    /// ⚠️ THE THREE OPTIONAL BUSINESS FIELDS ARE DROPPED WHEN ABSENT rather than sent null,
    /// because the route STORES what it is given into the TrustHub profile.
    func testAnAcceptedA2PSubmissionKeepsAllFourReportedValues() async throws {
        let transport = RepositoryTransport(json: NumberProvisioningBodies.a2pAccepted)

        let result = await NumbersRepository(client: .repositoryTest(transport)).submitA2PRegistration(
            workspaceId: "ws_1",
            registration: A2PRegistrationDraft(
                businessName: "Contoso",
                campaignType: "CUSTOMER_CARE",
                campaignDescription: "Order updates and support replies.",
                sampleMessage1: "Your order is on its way.",
                sampleMessage2: "Reply STOP to opt out."
            )
        )

        let response = try XCTUnwrap(result.successOnly)
        XCTAssertEqual(response.status, "IN_PROGRESS")
        XCTAssertEqual(response.brandSid, "BN1")
        XCTAssertEqual(response.messagingServiceSid, "MG1")
        XCTAssertEqual(response.campaignSid, "QE1")
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/workspace/a2p"
        )
        XCTAssertEqual(
            transport.bodies.first,
            #"{"businessName":"Contoso","campaignDescription":"Order updates and support replies.","#
                + #""campaignType":"CUSTOMER_CARE","sampleMessage1":"Your order is on its way.","#
                + #""sampleMessage2":"Reply STOP to opt out.","workspaceId":"ws_1"}"#
        )
    }

    /// ⛔ THE ORDINARY FIRST ANSWER IS A **400 CARRYING `TRUST_BUNDLES_NOT_APPROVED`**, AND
    /// IT IS AN ACCOUNT STATE RATHER THAN A FAULT. The TrustHub Customer Profile and A2P
    /// Trust Bundle are a manual, multi-day, once-per-account Console step that no retry
    /// moves, so it must render as an explanatory state with no retry button. ⚠️ And the
    /// typing is not lost on that path: the route persists the business-identity fields
    /// anyway, deliberately, because that is exactly when whoever builds the profile needs
    /// them.
    func testTheTrustBundleRefusalIsA400AccountStateRatherThanAFault() async throws {
        let transport = RepositoryTransport(json: NumberProvisioningBodies.a2pTrustBundlesMissing, status: 400)

        let result = await NumbersRepository(client: .repositoryTest(transport)).submitA2PRegistration(
            workspaceId: "ws_1",
            registration: A2PRegistrationDraft(
                businessName: "Contoso",
                campaignType: "CUSTOMER_CARE",
                campaignDescription: "Order updates.",
                sampleMessage1: "One.",
                sampleMessage2: "Two."
            )
        )

        XCTAssertEqual(result.failureOnly?.httpStatus, 400)
        let message = try XCTUnwrap(result.failureOnly?.message)
        XCTAssertTrue(message.contains("TrustHub"), "the server's own explanation reaches the screen")
    }

    func testAnA2PBodyThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(json: NumberProvisioningBodies.a2pRefusedEnvelope)

        let result = await NumbersRepository(client: .repositoryTest(transport)).submitA2PRegistration(
            workspaceId: "ws_1",
            registration: A2PRegistrationDraft(
                businessName: "Contoso",
                campaignType: "CUSTOMER_CARE",
                campaignDescription: "Order updates.",
                sampleMessage1: "One.",
                sampleMessage2: "Two."
            )
        )

        XCTAssertEqual(result.failureOnly, .decoding("A2PRegistrationResponse did not affirm success=true"))
    }

    // MARK: - Toll-free verification

    /// ⚠️ THE SUBMISSION CHANGED A LIVE NUMBER'S ROUTING STATE (the hub row moves to
    /// `pending_verification`), and `tfvSid` is the handle an operator quotes to support —
    /// so both reported values have to survive, there being no status read to re-ask.
    ///
    /// ⛔ `optInImageUrls` IS ALWAYS SENT, EVEN EMPTY, so the refusal is the route's own
    /// sentence about opt-in evidence rather than a generic missing-field 400.
    func testAnAcceptedTollFreeSubmissionKeepsItsStatusAndSid() async throws {
        let transport = RepositoryTransport(json: NumberProvisioningBodies.tfvAccepted)

        let result = await NumbersRepository(client: .repositoryTest(transport)).submitTollFreeVerification(
            workspaceId: "ws_1",
            verification: TollFreeVerificationDraft(
                phoneNumber: "+18005550100",
                businessName: "Contoso",
                useCase: "Customer Support",
                optInImageUrls: ["https://contoso.example/opt-in.png"]
            )
        )

        let response = try XCTUnwrap(result.successOnly)
        XCTAssertEqual(response.status, "PENDING_REVIEW")
        XCTAssertEqual(response.tfvSid, "HH1")
        // ⚠️ NORMALISED, BECAUSE `JSONEncoder` ESCAPES `/` AS `\/` ON LINUX AND NOT ON
        // DARWIN. Both are valid JSON that decodes identically, so a byte-exact assertion
        // on a body containing a URL passes on the Linux runner and fails the day it runs
        // on the Mac. `EndpointTableTests` normalises the same way and for the same reason.
        XCTAssertEqual(
            transport.bodies.first.map(Self.unescapeSlashes),
            #"{"businessName":"Contoso","optInImageUrls":["https://contoso.example/opt-in.png"],"#
                + #""phoneNumber":"+18005550100","useCase":"Customer Support","workspaceId":"ws_1"}"#
        )
    }

    /// ⛔ AN EMPTY OPT-IN LIST IS STILL SENT, AND THE **400** THAT COMES BACK IS THE ROUTE'S
    /// OWN ACTIONABLE SENTENCE. Twilio's reviewers open every URL by hand and reject the
    /// filing days later with error 30509 if one does not load, so refusing up front beats
    /// losing days — and a client that pre-empted the refusal with its own wording would
    /// replace the remedy with a shrug.
    func testAnEmptyOptInListIsStillSentSoTheRoutesOwnRefusalIsShown() async {
        let transport = RepositoryTransport(json: NumberProvisioningBodies.tfvOptInMissing, status: 400)

        let result = await NumbersRepository(client: .repositoryTest(transport)).submitTollFreeVerification(
            workspaceId: "ws_1",
            verification: TollFreeVerificationDraft(
                phoneNumber: "+18005550100",
                businessName: "Contoso",
                useCase: "Customer Support",
                optInImageUrls: []
            )
        )

        XCTAssertEqual(result.failureOnly?.httpStatus, 400)
        XCTAssertEqual(result.failureOnly?.message, NumberProvisioningBodies.optInRequiredMessage)
        XCTAssertEqual(
            transport.bodies.first,
            #"{"businessName":"Contoso","optInImageUrls":[],"phoneNumber":"+18005550100","#
                + #""useCase":"Customer Support","workspaceId":"ws_1"}"#
        )
    }

    func testATollFreeBodyThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(json: NumberProvisioningBodies.tfvRefusedEnvelope)

        let result = await NumbersRepository(client: .repositoryTest(transport)).submitTollFreeVerification(
            workspaceId: "ws_1",
            verification: TollFreeVerificationDraft(
                phoneNumber: "+18005550100",
                businessName: "Contoso",
                useCase: "Customer Support",
                optInImageUrls: ["https://contoso.example/opt-in.png"]
            )
        )

        XCTAssertEqual(result.failureOnly, .decoding("TollFreeVerificationResponse did not affirm success=true"))
    }

    // MARK: - The billable lookup

    /// ⛔ ONE CALL, ONE REQUEST, AND THE `+` IS PERCENT-ENCODED. A literal `+` in a query
    /// value arrives at the server as a SPACE after form decoding, so the lookup would be
    /// performed for a different number — a spent carrier call answering `valid: false`,
    /// which reads as a bad number rather than as an encoding bug.
    func testALookupSpendsExactlyOneRequestAndEncodesTheE164Number() async throws {
        let transport = RepositoryTransport(json: NumberProvisioningBodies.lookupValid)

        let result = await NumbersRepository(client: .repositoryTest(transport)).lookupNumber(
            workspaceId: "ws_1",
            phoneNumber: "+14165550100"
        )

        let info = try XCTUnwrap(result.successOnly).info
        XCTAssertTrue(info.valid)
        XCTAssertEqual(info.country, "CA")
        XCTAssertEqual(info.type, "mobile")
        XCTAssertEqual(info.carrier, "Rogers")
        XCTAssertEqual(transport.requests.count, 1, "⛔ one tap, one lookup")
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/workspace/lookup"
                + "?workspaceId=ws_1&phoneNumber=%2B14165550100"
        )
    }

    /// ⛔ AN INVALID NUMBER IS A **200** AND IT STILL COST A CARRIER CALL. The route
    /// translates Twilio's own 404 itself, so `valid: false` is not a cheap answer and must
    /// never be probed for. ⚠️ Its three detail fields are explicit nulls rather than
    /// absent, so a screen says "not reported" rather than treating nil as a missing
    /// response.
    func testAnInvalidNumberIsASuccessfulAnswerThatStillSpentACarrierCall() async throws {
        let transport = RepositoryTransport(json: NumberProvisioningBodies.lookupInvalid)

        let result = await NumbersRepository(client: .repositoryTest(transport)).lookupNumber(
            workspaceId: "ws_1",
            phoneNumber: "+1416"
        )

        XCTAssertNil(result.failureOnly, "⛔ a 200 is not an error, however unhelpful the answer")
        let info = try XCTUnwrap(result.successOnly).info
        XCTAssertFalse(info.valid)
        XCTAssertNil(info.country)
        XCTAssertNil(info.type)
        XCTAssertNil(info.carrier)
        XCTAssertEqual(transport.requests.count, 1, "the money is spent either way")
    }

    func testALookupBodyThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(json: NumberProvisioningBodies.lookupRefused)

        let result = await NumbersRepository(client: .repositoryTest(transport)).lookupNumber(
            workspaceId: "ws_1",
            phoneNumber: "+14165550100"
        )

        XCTAssertEqual(result.failureOnly, .decoding("NumberLookupResponse did not affirm success=true"))
    }

    /// ⚠️ `JSONEncoder` ESCAPES `/` AS `\/` ON LINUX AND NOT ON DARWIN, and both are valid
    /// JSON that decodes identically — so a byte-exact assertion on a body containing a URL
    /// passes on this runner and fails the day anything runs on a Mac. The escape is
    /// normalised away rather than the URL removed, because the opt-in evidence URL is
    /// precisely the field worth pinning. `EndpointTableTests` carries the same helper.
    private static func unescapeSlashes(_ text: String) -> String {
        text.replacingOccurrences(of: "\\/", with: "/")
    }
}
