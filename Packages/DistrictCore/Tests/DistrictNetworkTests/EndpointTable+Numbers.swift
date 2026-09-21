@testable import DistrictNetwork
import Foundation

// The sixteen provisioning rows, written out by hand like every other row in this
// table.
//
// ⛔ NO `workspace/numbers/purchase` ROW, AND ITS ABSENCE IS ASSERTED RATHER THAN
// ASSUMED. `EndpointSurfaceTests.testTheNumberPurchaseRouteIsNotReachable` walks this
// whole table for a `purchase` segment and checks that no ``EndpointID`` can be spelled
// for it. App Store Review Guideline 3.1.1: a setup fee plus a recurring monthly charge
// for a service consumed inside the app is an in-app purchase or it is not offered.
//
// ⛔ ITS OWN FILE RATHER THAN SIXTEEN ROWS IN `EndpointTable.swift`, which registers the
// groups and is where parallel changes collide. One line there instead of sixteen here
// is the difference between a merge and a manual reconciliation. Same
// shape `EndpointTable+Settings.swift` and `+Desk.swift` already have.
//
// ⚠️ A `//` HEADER RATHER THAN A `///` ONE: SwiftFormat's `docComments` rule rejects a
// doc comment attached to no declaration.

extension EndpointTable {
    /// The regulatory paperwork and the two number writes.
    ///
    /// ⛔ THE PATHS ARE WRITTEN OUT RATHER THAN BUILT FROM `DistrictPaths`, like every
    /// other row here, and for this family it earns its keep twice over:
    /// `workspace/numbers/purchase` is one segment away from
    /// `workspace/numbers/configure` and `workspace/numbers/release`, and a table
    /// derived from the same constants would assert only that the code equals itself.
    static func numberRegistrations() -> [EndpointExpectation] {
        [
            EndpointExpectation(
                .providerStatus,
                DistrictEndpoints.providerStatus(workspaceId: "ws_1"),
                .get,
                "\(host)/api/district/workspace/provider/status?workspaceId=ws_1"
            ),
            // ⚠️ THE QUERY PARAMETER IS `type`, NOT `numberType`, AND ITS VOCABULARY IS
            // TWILIO'S — `local`, `mobile`, `national`, `toll free` WITH A SPACE. That is
            // a different vocabulary from `numbers/search`'s `type`, which takes
            // `tollFree`. Two routes, one parameter name, two spellings.
            EndpointExpectation(
                .numberRequirements,
                DistrictEndpoints.numberRequirements(
                    workspaceId: "ws_1",
                    country: "EE",
                    numberType: "local",
                    endUserType: "business"
                ),
                .get,
                "\(host)/api/district/workspace/numbers/requirements"
                    + "?workspaceId=ws_1&country=EE&type=local&endUserType=business"
            ),
            EndpointExpectation(
                .numberRegistrations,
                DistrictEndpoints.numberRegistrations(workspaceId: "ws_1"),
                .get,
                "\(host)/api/district/workspace/numbers/registrations?workspaceId=ws_1"
            ),
            // ⛔ THE WORKSPACE IS IN THE QUERY AND NOT THE BODY, ON A POST. The route
            // runs auth, the limiter and the billing check before it reads a body at
            // all, so an id in the JSON leaves `requireWorkspaceRole` with null while
            // the body reads perfectly correct. The body carries the four filing fields
            // and nothing else.
            EndpointExpectation(
                .createNumberRegistration,
                DistrictEndpoints.createNumberRegistration(
                    workspaceId: "ws_1",
                    isoCountry: "EE",
                    numberType: "local",
                    endUserType: "business",
                    friendlyName: "Contoso Baltics"
                ),
                .post,
                "\(host)/api/district/workspace/numbers/registrations?workspaceId=ws_1",
                .json(
                    #"{"endUserType":"business","friendlyName":"Contoso Baltics","#
                        + #""isoCountry":"EE","numberType":"local"}"#
                )
            ),
        ]
    }

    /// The document pair and the submit.
    static func numberDocuments() -> [EndpointExpectation] {
        [
            // ⛔ TWO FORM FIELDS AND NEITHER IS THE WORKSPACE, which makes this row the
            // reason `ExpectedBody.multipart` carries its fields per row at all.
            // `messages/media` sends `workspaceId` as a field and nothing else;
            // `desk/logo` sends no fields and reads the workspace off the query; this
            // one does BOTH halves differently again. A part list copied from either
            // neighbour is a 400 from a request whose URL reads correctly.
            EndpointExpectation(
                .uploadRegistrationDocument,
                DistrictEndpoints.uploadRegistrationDocument(
                    workspaceId: "ws_1",
                    document: RegulatoryDocumentUpload(
                        bundleId: "bun_1",
                        requirementName: "business_registration_number_info",
                        fileName: "extract.pdf",
                        mimeType: "application/pdf",
                        bytes: Data([0x25, 0x50, 0x44, 0x46])
                    )
                ),
                .post,
                "\(host)/api/district/workspace/numbers/registrations/documents?workspaceId=ws_1",
                .multipart(
                    fields: [
                        "bundleId": "bun_1",
                        "requirementName": "business_registration_number_info",
                    ],
                    fileName: "extract.pdf"
                )
            ),
            // ⛔ THE ONE DELETE ON THIS API THAT CARRIES A BODY. Every other one reads
            // query parameters and would ignore one; this route reads `bundleId` and
            // `documentId` off `req.json()`. `EndpointTableTests`'
            // `testNoDeleteCarriesABodyExceptTheOneThatMust` names this row explicitly
            // rather than dropping the convention for all of them.
            EndpointExpectation(
                .deleteRegistrationDocument,
                DistrictEndpoints.deleteRegistrationDocument(
                    workspaceId: "ws_1",
                    bundleId: "bun_1",
                    documentId: "doc_1"
                ),
                .delete,
                "\(host)/api/district/workspace/numbers/registrations/documents?workspaceId=ws_1",
                .json(#"{"bundleId":"bun_1","documentId":"doc_1"}"#)
            ),
            // ⚠️ `endUserAttributes` IS SENT EVEN WHEN THE CALLER HAS NOTHING TO PUT IN
            // IT (the route reads `?? {}`), so a captured request says "no attributes
            // were supplied" rather than "this client forgot the key". Here it carries
            // one, because a nested-object test would be asserting the 400 rather than
            // the request.
            EndpointExpectation(
                .submitNumberRegistration,
                DistrictEndpoints.submitNumberRegistration(
                    workspaceId: "ws_1",
                    bundleId: "bun_1",
                    endUserAttributes: ["business_name": .string("Contoso Baltics")]
                ),
                .post,
                "\(host)/api/district/workspace/numbers/registrations/submit?workspaceId=ws_1",
                .json(#"{"bundleId":"bun_1","endUserAttributes":{"business_name":"Contoso Baltics"}}"#)
            ),
        ]
    }

    /// The two writes against a number the workspace already holds.
    ///
    /// ⛔ BOTH CARRY THE WORKSPACE IN THE **BODY**, which is the opposite of the
    /// registration routes one group up and is the server's own asymmetry rather than a
    /// choice available here: these two read `req.json()` first and hand the parsed value
    /// to `requireWorkspaceRole`, so a query parameter alone is a 400 "Missing
    /// workspaceId or phoneNumber". One family, two conventions.
    static func numberWrites() -> [EndpointExpectation] {
        [
            EndpointExpectation(
                .configureNumber,
                DistrictEndpoints.configureNumber(workspaceId: "ws_1", phoneNumber: "+14165550100"),
                .post,
                "\(host)/api/district/workspace/numbers/configure",
                .json(#"{"phoneNumber":"+14165550100","workspaceId":"ws_1"}"#)
            ),
            // ⛔ ONE SEGMENT FROM `numbers/purchase` AND IRREVERSIBLE. The path is spelled
            // out here rather than built, so a constant that ever pointed elsewhere would
            // fail this row rather than silently release through a different route.
            EndpointExpectation(
                .releaseNumber,
                DistrictEndpoints.releaseNumber(workspaceId: "ws_1", phoneNumber: "+14165550100"),
                .post,
                "\(host)/api/district/workspace/numbers/release",
                .json(#"{"phoneNumber":"+14165550100","workspaceId":"ws_1"}"#)
            ),
        ]
    }

    /// The two compliance submissions.
    ///
    /// ⛔ NEITHER HAS A STATUS READ ANYWHERE ON THE SERVER, so these two rows pin the only
    /// request either flow will ever make. A wrong field here is not something a later read
    /// could catch.
    static func carrierCompliance() -> [EndpointExpectation] {
        [
            // ⚠️ THE THREE NIL FIELDS ARE DROPPED RATHER THAN SENT NULL. `ein`, `website` and
            // `vertical` are persisted into the TrustHub Customer Profile when present, so an
            // explicit null would be a value the route would store.
            EndpointExpectation(
                .submitA2PRegistration,
                DistrictEndpoints.submitA2PRegistration(
                    workspaceId: "ws_1",
                    registration: A2PRegistrationDraft(
                        businessName: "Contoso",
                        campaignType: "CUSTOMER_CARE",
                        campaignDescription: "Order updates and support replies.",
                        sampleMessage1: "Your order is on its way.",
                        sampleMessage2: "Reply STOP to opt out."
                    )
                ),
                .post,
                "\(host)/api/district/workspace/a2p",
                .json(
                    #"{"businessName":"Contoso","campaignDescription":"Order updates and support replies.","#
                        + #""campaignType":"CUSTOMER_CARE","sampleMessage1":"Your order is on its way.","#
                        + #""sampleMessage2":"Reply STOP to opt out.","workspaceId":"ws_1"}"#
                )
            ),
            // ⛔ `optInImageUrls` IS ALWAYS SENT, EVEN EMPTY, so the refusal is the route's own
            // sentence about opt-in evidence rather than a generic missing-field 400. ⚠️ The URL
            // in it is why `EndpointTableTests` normalises `\/` away: `JSONEncoder` escapes a
            // slash on Linux and not on Darwin.
            EndpointExpectation(
                .submitTollFreeVerification,
                DistrictEndpoints.submitTollFreeVerification(
                    workspaceId: "ws_1",
                    verification: TollFreeVerificationDraft(
                        phoneNumber: "+18005550100",
                        businessName: "Contoso",
                        useCase: "Customer Support",
                        optInImageUrls: ["https://contoso.example/opt-in.png"]
                    )
                ),
                .post,
                "\(host)/api/district/workspace/tfv",
                .json(
                    #"{"businessName":"Contoso","optInImageUrls":["https://contoso.example/opt-in.png"],"#
                        + #""phoneNumber":"+18005550100","useCase":"Customer Support","workspaceId":"ws_1"}"#
                )
            ),
        ]
    }

    /// SIP trunking, both verbs.
    ///
    /// ⚠️ ONE PATH AND TWO ROWS, which is what lets this suite assert a method per entry and
    /// what keeps the viewer-legal read from being expressible as the write. ⛔ There is no
    /// DELETE row because there is no DELETE route: a trunk created here cannot be taken down
    /// from this client, and its $25/month billing item keeps standing.
    static func sipTrunking() -> [EndpointExpectation] {
        [
            EndpointExpectation(
                .sipTrunks,
                DistrictEndpoints.sipTrunks(workspaceId: "ws_1"),
                .get,
                "\(host)/api/district/workspace/sip?workspaceId=ws_1"
            ),
            // ⚠️ `domain` IS THE LABEL ONLY. The route appends `.sip.twilio.com`, so a
            // fully-qualified value here would produce a doubled suffix.
            EndpointExpectation(
                .createSipTrunk,
                DistrictEndpoints.createSipTrunk(
                    workspaceId: "ws_1",
                    name: "Front desk",
                    domain: "contoso",
                    ipAccessControlList: ["203.0.113.7", "198.51.100.0/24"]
                ),
                .post,
                "\(host)/api/district/workspace/sip",
                .json(
                    #"{"domain":"contoso","ipAccessControlList":["203.0.113.7","198.51.100.0/24"],"#
                        + #""name":"Front desk","workspaceId":"ws_1"}"#
                )
            ),
        ]
    }

    /// The Verify (OTP) configuration, and the billable lookup.
    ///
    /// ⚠️ THREE ROWS FOR TWO PATHS: `workspace/verify` is GET + POST. ⛔ The lookup is the one
    /// GET on this whole table that costs money per call.
    static func verifyAndLookup() -> [EndpointExpectation] {
        [
            EndpointExpectation(
                .verifyService,
                DistrictEndpoints.verifyService(workspaceId: "ws_1"),
                .get,
                "\(host)/api/district/workspace/verify?workspaceId=ws_1"
            ),
            // ⚠️ A REAL BOOLEAN. The route checks `typeof enabled !== "boolean"` and answers
            // 400 "Missing required fields" for a string, which reads as a missing key rather
            // than a wrong type.
            EndpointExpectation(
                .setVerifyServiceEnabled,
                DistrictEndpoints.setVerifyServiceEnabled(workspaceId: "ws_1", enabled: true),
                .post,
                "\(host)/api/district/workspace/verify",
                .json(#"{"enabled":true,"workspaceId":"ws_1"}"#)
            ),
            // ⛔ BILLABLE PER CALL, ON A GET, ADMITTING `viewer`. The `+` is percent-encoded to
            // `%2B`, which is the whole reason `ApiURL` does not use
            // `URLComponents.queryItems`: a literal `+` arrives at the server as a SPACE after
            // form decoding, and a lookup for ` 1416…` is a spent carrier call that answers
            // `valid: false`.
            EndpointExpectation(
                .lookupNumber,
                DistrictEndpoints.lookupNumber(workspaceId: "ws_1", phoneNumber: "+14165550100"),
                .get,
                "\(host)/api/district/workspace/lookup?workspaceId=ws_1&phoneNumber=%2B14165550100"
            ),
        ]
    }
}
