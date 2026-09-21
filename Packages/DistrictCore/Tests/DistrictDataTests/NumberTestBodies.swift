import Foundation

// Minimal, VALID bodies for every phone-number provisioning and carrier-account shape.
//
// ⚠️ NOT CONTRACT FIXTURES, AND THERE ARE NONE FOR THIS FAMILY. The contract corpus
// mirrors the Kotlin client and that client has no provisioning surface, so ⛔
// `ContractManifest.expectedFixtureCount` does not move for any of these. What pins the
// shapes is the route source, quoted on each DTO. These are the smallest bodies that
// satisfy the Swift types, the same footing as `Bodies` and `DeskTestBodies`.
//
// ⛔ EVERY MULTI-LINE BODY BREAKS BETWEEN JSON TOKENS, NEVER INSIDE A STRING VALUE. A
// newline inside a value is invalid JSON and the failure it produces is a decode error in
// the code under test rather than in the fixture — see the ⛔ on
// `Bodies.subscriptionRefusal`. The long server sentences are therefore built by
// concatenating Swift literals, which also keeps every line under SwiftLint's 120.
//
// ⚠️ ITS OWN FILE RATHER THAN A `private enum` AT THE FOOT OF ONE TEST FILE, because
// three suites read it and SwiftLint caps a file at 500 lines. Same call
// `MessagingTestBodies.swift` and `WorkflowTestBodies.swift` already made.
//
// ⛔ NAMED `NumberProvisioningBodies` AND NOT `NumberBodies`, WHICH IS NOT COSMETIC.
// `NumbersRepositoryTests.swift` already declares a `private enum NumberBodies` for the
// two marketplace reads. `private` is FILE scope, so an internal type of the same name
// would shadow inside that file and read as the wrong bodies from every other one — the
// kind of collision that compiles and then makes a test assert against a neighbour's
// fixture.
//
// ⚠️ A `//` HEADER RATHER THAN A `///` ONE: SwiftFormat's `docComments` rule rejects a
// doc comment attached to no declaration.

enum NumberProvisioningBodies {
    // MARK: - Provider status

    /// ⚠️ SINGULAR `provider`, EXPLICITLY NULL, AND NO `providers` MAP AT ALL. This is
    /// the branch a fresh workspace gets, and a decoder that modelled only the plural
    /// would read it as contract drift.
    static let providerStatusDisconnected = #"{"connected":false,"provider":null}"#

    /// ⚠️ `balance` IS A STRING on the wire, which is Twilio's own spelling.
    static let providerStatusMixed = #"""
    {"connected":true,"providers":{
      "twilio":{"connected":true,"accountName":"Contoso","status":"active",
                "balance":"12.34","currency":"USD","numberCount":3},
      "telnyx":{"connected":false,"error":"Invalid credentials"}}}
    """#

    /// ⛔ CONNECTIVITY ONLY. A managed provider's account figures are the platform's,
    /// plus every other managed tenant's, so the route sends none of them.
    static let providerStatusManaged = #"""
    {"connected":true,"providers":{"twilio":{"connected":true,"managed":true}}}
    """#

    // MARK: - Requirements

    /// ⛔ `purchasable: false` BESIDE A NULL `requirements` is the combination a reader
    /// would least expect, and is exactly why neither may be inferred from the other.
    static let requirementsNone = #"""
    {"success":true,"country":"US","numberType":"local","purchasable":false,"requirements":null}
    """#

    /// ⚠️ ONE `end_user` REQUIREMENT AND ONE `supporting_document` ONE, because the two
    /// are satisfied by entirely different actions and a screen must tell them apart.
    static let requirementsEstonia = #"""
    {"success":true,"country":"EE","numberType":"local","purchasable":true,
     "requirements":{"isoCountry":"EE","numberType":"local","endUserType":"business",
                     "regulationSid":"RN1","friendlyName":"Estonia local business",
                     "requirements":[
                       {"kind":"end_user","name":"Business","requirementName":"business_info",
                        "type":"business","fields":["business_name"]},
                       {"kind":"supporting_document","name":"Registry extract",
                        "requirementName":"business_registration_number_info",
                        "type":"document","fields":["business_registration_number"],
                        "acceptedDocuments":[{"name":"Extract","type":"registry_extract",
                                              "fields":["business_registration_number"]}]}]}}
    """#

    static let requirementsRefused = #"""
    {"success":false,"country":"EE","numberType":"local","purchasable":false,"requirements":null}
    """#

    // MARK: - Filings

    /// A draft: nothing submitted, nothing reviewed, no reasons, no documents.
    static func draftRow(id: String = "bun_1", country: String = "EE") -> String {
        #"""
        {"id":"\#(id)","isoCountry":"\#(country)","numberType":"local","endUserType":"business",
         "friendlyName":null,"status":"draft","rejectionReasons":[],"submittedAt":null,
         "reviewedAt":null,"createdAt":"2026-09-07T09:41:00.000Z","documents":[]}
        """#
    }

    static let registrationsEmpty = #"""
    {"success":true,"registrations":[],"approvedCountries":[],"platformCountries":["EE"]}
    """#

    /// ⚠️ THE TWO COUNTRY LISTS DELIBERATELY DISAGREE HERE, so a test cannot pass by
    /// reading either one for the other.
    static let registrationsOneDraft = #"""
    {"success":true,"registrations":[\#(draftRow())],
     "approvedCountries":["DE"],"platformCountries":["EE"]}
    """#

    /// ⚠️ A TERMINAL VERDICT: both dates present, reasons non-empty, and a document that
    /// is both stored and submitted.
    static let registrationsRejected = #"""
    {"success":true,"registrations":[
      {"id":"bun_2","isoCountry":"DE","numberType":"local","endUserType":"business",
       "friendlyName":"Contoso GmbH","status":"twilio-rejected",
       "rejectionReasons":["The registry extract is unreadable."],
       "submittedAt":"2026-09-05T09:41:00.000Z","reviewedAt":"2026-09-06T11:02:00.000Z",
       "createdAt":"2026-09-04T09:41:00.000Z",
       "documents":[{"id":"doc_9","requirementName":"business_registration_number_info",
                     "mimeType":"application/pdf","sizeBytes":2048,"stored":true,
                     "submitted":true,"updatedAt":"2026-09-05T09:40:00.000Z"}]}],
     "approvedCountries":[],"platformCountries":["EE"]}
    """#

    static let registrationsRefused = #"""
    {"success":false,"registrations":[],"approvedCountries":[],"platformCountries":[]}
    """#

    static let registrationCreated = #"{"success":true,"registration":\#(draftRow())}"#

    static let registrationCreatedRefused = #"{"success":false,"registration":\#(draftRow())}"#

    static let duplicateRegistrationMessage =
        "This workspace already has a registration for EE local numbers."

    static let registrationDuplicate =
        #"{"success":false,"error":"\#(duplicateRegistrationMessage)"}"#

    // MARK: - Documents

    /// ⛔ `createdAt`, NOT `updatedAt`, AND NEITHER BOOLEAN. The upload's row is narrower
    /// than a list row, which is why it has its own type.
    static let documentUploaded = #"""
    {"success":true,"document":{"id":"doc_1","requirementName":"business_registration_number_info",
     "mimeType":"application/pdf","sizeBytes":1024,"createdAt":"2026-09-07T09:41:00.000Z"}}
    """#

    static let documentUploadRefused = #"""
    {"success":false,"document":{"id":"doc_1","requirementName":"business_registration_number_info",
     "mimeType":"application/pdf","sizeBytes":1024,"createdAt":"2026-09-07T09:41:00.000Z"}}
    """#

    /// ⛔ THE ONE SENTENCE A CUSTOMER CAN ACT ON ("re-export it"), which is why this layer
    /// passes it through rather than re-authoring it. Built by concatenation because it
    /// contains escaped quotes and must not break mid-value.
    static let sniffMismatchMessage = #"That file's contents look like image/png, but it "#
        + #"was uploaded as "application/pdf". Re-export it and try again."#

    static let documentSniffMismatch = #"{"success":false,"error":"That file's contents look "#
        + #"like image/png, but it was uploaded as \"application/pdf\". Re-export it and try "#
        + #"again."}"#

    /// ⚠️ A **409**, NOT A 403: the request is well-formed and will be valid again if the
    /// review comes back rejected.
    static let documentNotDraft = #"{"success":false,"error":"This registration has already "#
        + #"been submitted (status \"in-review\") and its documents can no longer be changed."}"#

    static let documentRemoved = #"{"success":true,"documentId":"doc_1"}"#

    static let documentRemovalRefused = #"""
    {"success":false,"error":"We could not remove that document's file. Please try again."}
    """#

    // MARK: - Submitting a filing

    static let submitAccepted = #"""
    {"success":true,"registration":{"id":"bun_1","status":"pending-review",
     "submittedAt":"2026-09-07T09:41:00.000Z"}}
    """#

    static let submitRefused = #"""
    {"success":false,"registration":{"id":"bun_1","status":"draft",
     "submittedAt":"2026-09-07T09:41:00.000Z"}}
    """#

    static let evaluationFailedMessage =
        "The carrier refused this registration. Fix the items below and submit again."

    /// ⛔ CARRIES `failures` AND `reasons`, WHICH `ApiError` DELIBERATELY DROPS. Present
    /// here so that loss is exercised rather than assumed — the screen's remedy is to
    /// re-read the filing list, where the route stored them verbatim.
    static let submitEvaluationFailed = #"""
    {"success":false,"error":"\#(evaluationFailedMessage)",
     "failures":[{"requirementName":"business_registration_number_info","field":null,
                  "reason":"unreadable","code":null}],
     "reasons":["The registry extract is unreadable."]}
    """#

    static let submitCarrierUnreachable = #"""
    {"success":false,"error":"The carrier could not accept this registration: upstream timeout"}
    """#

    // MARK: - Configure and release

    /// ⛔ THE EU-TRUNK FAIL-CLOSED, which is a real sentence to show: the degrade it
    /// refuses is a state CHANGE dressed as a no-op.
    static let configureNoEuTrunk = #"{"error":"This number is answered on the EU bridge, "#
        + #"and TWILIO_EU_TRUNK_SID is not configured in this environment, so the change "#
        + #"was refused."}"#

    static let numberNotInWorkspaceMessage = "Phone number not found in this workspace"

    static let numberNotInWorkspace = #"{"error":"\#(numberNotInWorkspaceMessage)"}"#

    static let providerMismatch = #"{"error":"This number was provisioned on telnyx, and "#
        + #"this workspace has no telnyx credentials configured."}"#

    static let releaseChargeWarning =
        "The number was released, but its monthly charge could not be ended."

    /// ⛔ A **200** CARRYING A WARNING. The number is gone; the monthly charge is not.
    static let releaseWithWarnings =
        #"{"success":true,"warnings":["\#(releaseChargeWarning)"]}"#

    static let releaseCarrierRefused = #"{"error":"The carrier did not release this number, "#
        + #"so nothing was changed. It is still assigned to this workspace and still "#
        + #"billing."}"#

    // MARK: - Carrier accounts

    static let sipTrunksEmpty = #"{"success":true,"trunks":[]}"#

    /// ⚠️ ONE FULLY-PROVISIONED ROW AND ONE LEGACY ROW WITH BOTH SIDS NULL, because the
    /// list parses these out of a packed `productRef` and a row written before real
    /// provisioning has neither.
    static let sipTrunksMixed = #"""
    {"success":true,"trunks":[
      {"id":"mbi_1","name":"Front desk","domain":"contoso.sip.twilio.com",
       "ipAccessControlList":["203.0.113.7"],"domainSid":"SD1","ipAclSid":"AL1",
       "status":"active"},
      {"id":"mbi_0","name":"Legacy","domain":"legacy.sip.twilio.com",
       "ipAccessControlList":[],"domainSid":null,"ipAclSid":null,"status":"active"}]}
    """#

    static let sipTrunkCreated = #"""
    {"success":true,"trunk":{"id":"mbi_2","name":"Front desk","domain":"contoso.sip.twilio.com",
     "ipAccessControlList":["203.0.113.7","198.51.100.0/24"],"domainSid":"SD2",
     "ipAclSid":"AL2","status":"active"}}
    """#

    static let sipRequiresTwilio = #"{"error":"SIP Trunking currently requires a Twilio "#
        + #"account connected to this workspace."}"#

    // MARK: - Verify service

    /// ⚠️ AN EXPLICIT NULL, which is what the GET sends when the service is off.
    static let verifyOffOnRead = #"{"success":true,"enabled":false,"verifyServiceSid":null}"#

    /// ⚠️ THE KEY IS **ABSENT**, which is what the DISABLE reply sends. Both decode to
    /// nil, and the pair is the reason the field is Optional rather than nullable-only.
    static let verifyDisabled = #"{"success":true,"enabled":false}"#

    static let verifyEnabled = #"{"success":true,"enabled":true,"verifyServiceSid":"VA1"}"#

    static let verifyRefused = #"{"success":false,"enabled":true,"verifyServiceSid":"VA1"}"#

    // MARK: - A2P and toll-free verification

    static let a2pAccepted = #"""
    {"success":true,"status":"IN_PROGRESS","brandSid":"BN1","messagingServiceSid":"MG1",
     "campaignSid":"QE1"}
    """#

    static let a2pRefusedEnvelope = #"""
    {"success":false,"status":"IN_PROGRESS","brandSid":"BN1","messagingServiceSid":"MG1",
     "campaignSid":"QE1"}
    """#

    /// ⛔ THE ORDINARY FIRST ANSWER, AND AN ACCOUNT STATE RATHER THAN A FAULT. The
    /// TrustHub bundles are a manual, multi-day, once-per-account Console step.
    static let a2pTrustBundlesMissing = #"{"error":"A2P 10DLC registration requires a "#
        + #"Twilio TrustHub Customer Profile and A2P Trust Bundle that have already "#
        + #"completed Twilio's regulatory vetting.","code":"TRUST_BUNDLES_NOT_APPROVED"}"#

    static let tfvAccepted = #"{"success":true,"status":"PENDING_REVIEW","tfvSid":"HH1"}"#

    static let tfvRefusedEnvelope = #"{"success":false,"status":"PENDING_REVIEW","tfvSid":"HH1"}"#

    static let optInRequiredMessage = "Opt-in proof URL is required."

    static let tfvOptInMissing = #"{"error":"\#(optInRequiredMessage)"}"#

    // MARK: - Lookup

    static let lookupValid = #"""
    {"success":true,"info":{"valid":true,"phoneNumber":"+14165550100","country":"CA",
     "type":"mobile","carrier":"Rogers"}}
    """#

    /// ⛔ A **200**, AND IT COST A CARRIER CALL. The route translates Twilio's own 404
    /// itself, so `valid: false` is not a cheap answer.
    static let lookupInvalid = #"""
    {"success":true,"info":{"valid":false,"phoneNumber":"+1416","country":null,
     "type":null,"carrier":null}}
    """#

    static let lookupRefused = #"""
    {"success":false,"info":{"valid":true,"phoneNumber":"+14165550100","country":"CA",
     "type":"mobile","carrier":"Rogers"}}
    """#
}
