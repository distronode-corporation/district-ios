import Foundation

// The phone-number PROVISIONING paths: everything that happens to a number that is
// not buying one, plus the carrier-account surfaces a number needs before it can
// send or receive anything.
//
// ⛔ `workspace/numbers/purchase` IS ABSENT FROM THIS FILE AND FROM
// `DistrictPaths.swift`, AND THAT IS A DECISION RATHER THAN AN OVERSIGHT. Buying a
// number charges a setup fee AND opens a recurring monthly charge for a service
// consumed inside the app, which is App Store Review Guideline 3.1.1 territory: it
// has to be an in-app purchase or it is not offered at all. So there is no constant
// here, no ``EndpointID`` case, and no descriptor — and because
// ``ApiRequestDescriptor``'s initialiser is internal, the route is UNCONSTRUCTIBLE
// from outside this module rather than merely undocumented. `EndpointSurfaceTests`
// pins that, the same mechanism `calls/outbound` is held out by for an entirely
// different reason.
// ⛔ AND 3.1.1 COVERS STEERING, so there is no link to the web marketplace either,
// not even a tappable URL. ``MarketplaceCopy/readOnly`` names the site in prose and
// offers nothing to tap, which is what the rest of this app already does (see the ⛔
// at the top of `MarketplaceView.swift`, which explains why a 3.1.3(b) citation does
// not license a link).
// ⛔ THE NEXT READER WILL WANT TO FINISH THE SET IN GOOD FAITH. Everything else on
// the marketplace's six tabs is here; purchase is the hole, and this paragraph is
// the reason it stays one.
//
// ⛔ `workspace/verify/start` AND `workspace/verify/check` ARE ALSO ABSENT, for an
// ordinary scoping reason rather than a policy one. Both exist and both are live
// (POST, agency/client): they send an OTP and check one. An OTP entry flow is its own
// screen with its own retry, expiry and attempt-ceiling states, so it is a feature
// rather than two constants. ``DistrictPaths/workspaceVerify`` is the
// CONFIGURATION — whether the Verify service exists at all. Named here so nobody has
// to rediscover them.
//
// ⚠️ `workspace/channels`, `workspace/compliance`, `workspace/region-move` and
// `workspace/export` are adjacent and are not numbers. Deliberately out of scope.
//
// ⚠️ A `//` HEADER RATHER THAN A `///` ONE: SwiftFormat's `docComments` rule rejects
// a doc comment attached to no declaration, and a file header is exactly that.
//
// ⚠️ ITS OWN FILE RATHER THAN TWELVE MORE CONSTANTS IN `DistrictPaths.swift`, which
// is a lint ceiling rather than a taxonomy: that file is against SwiftLint's
// 500-line `file_length` and the commentary on each constant is the point of it.
// Same cut `EndpointClassification+Desk.swift` and `EndpointEnvelopes.swift` made.

extension DistrictPaths {
    /// ⚠️ NOT A SIBLING OF ``providerNumbers`` DESPITE THE SHARED `provider`
    /// SEGMENT, and the difference is the answer rather than the path. That one
    /// lists DIDs; this one reports, per carrier, whether credentials resolve.
    ///
    /// ⛔ IT IS THE ONE ROUTE IN THIS FAMILY WITH NO `success` FLAG AT ALL, and it
    /// answers TWO different key sets: `{connected:false, provider:null}` when no
    /// credentials resolve, and `{connected, providers:{…}}` when they do. Singular
    /// `provider` and plural `providers` are different keys on different branches,
    /// one letter apart. See ``ProviderStatusResponse``.
    ///
    /// ⚠️ IT ADMITS `viewer`, and a MANAGED provider reports connectivity ONLY. The
    /// route short-circuits those before asking the carrier anything, because
    /// `getAccountInfo` describes the AUTHENTICATING account — for a managed
    /// provider that is the platform's own shared account, so its name, prepaid
    /// balance and total number count are Distronode's figures plus every other
    /// managed tenant's, never this caller's.
    static var providerStatus: [String] {
        workspace + ["provider", "status"]
    }

    /// What a country's regulator asks for before a number there can be bought.
    ///
    /// ⛔ INFORMATIONAL, AND NOT THE COUNTRY GATE. The route's own header says it in
    /// terms: `purchasable` answers "can I buy one today" and `requirements` answers
    /// "what would it take", and the first must never be inferred from the second —
    /// a country can publish perfectly readable rules and still not be sellable
    /// here, because the purchase path also has to attach the resulting bundle and
    /// the number has to be routable to a bridge that serves it.
    ///
    /// ⚠️ IT ADMITS `viewer`, deliberately: reference data about a country rather
    /// than anything about the workspace, so someone evaluating whether we can serve
    /// their market does not need write access to find out.
    static var numbersRequirements: [String] {
        workspace + ["numbers", "requirements"]
    }

    /// ⛔ ONE PATH, TWO VERBS, AND THE WORKSPACE IS A QUERY PARAMETER ON BOTH. GET
    /// lists the workspace's regulatory filings; POST opens a new DRAFT, which is a
    /// local row and nothing at the carrier — assembly happens once, at
    /// ``numbersRegistrationSubmit``. The route reads `searchParams` before touching
    /// a body on either verb, so a `workspaceId` in the POST body would leave
    /// `requireWorkspaceRole` with null while the JSON reads perfectly correct.
    ///
    /// ⚠️ THE GET SPENDS A CARRIER CALL PER IN-REVIEW BUNDLE. There is no background
    /// poller: Twilio's review is asynchronous (~26h observed) and calls nobody back,
    /// so a status is refreshed on READ, at most once per bundle per request, and
    /// only for the two statuses that can still move. Both verbs share one 60/hour
    /// budget per workspace.
    ///
    /// ⛔ THE GET IS ALSO WHERE THE APPROVED-COUNTRY LIST LIVES, not on
    /// ``numbersSearch``: that response is byte-frozen by an Android contract fixture,
    /// so widening it is a breaking change for a client decoding with
    /// `ignoreUnknownKeys = false`.
    static var numbersRegistrations: [String] {
        workspace + ["numbers", "registrations"]
    }

    /// ⛔ THE THIRD MULTIPART ROUTE ON THIS SURFACE, AND ITS PART LIST MATCHES
    /// NEITHER OF THE OTHER TWO. `messages/media` sends `workspaceId` as a form field
    /// and nothing else; `desk/logo` sends no fields at all and reads the workspace
    /// off the query; this one reads the workspace off the QUERY **and** sends two
    /// fields that are not the workspace (`bundleId`, `requirementName`). Copying
    /// either neighbour's parts is a 400 from a request whose URL reads correctly —
    /// the exact mistake `EndpointTable.ExpectedBody.multipart` was made per-row to
    /// catch.
    ///
    /// ⛔ ONE PATH, TWO VERBS, AND **THE DELETE CARRIES A JSON BODY** — the only
    /// delete on this API that does. It reads `bundleId` and `documentId` off
    /// `req.json()`, and the workspace off the query. The "every DELETE here is
    /// query-only" convention therefore has exactly one documented exception; see
    /// `EndpointTableTests.testNoDeleteCarriesABodyExceptTheOneThatMust`.
    ///
    /// ⛔ THE ORDER IS DIFFERENT FROM `desk/logo`'S, AND ON PURPOSE. There the column
    /// is cleared first because that is what stops the image being SHOWN. Here
    /// nothing displays the document and `storageKey` is the ONLY pointer to the
    /// bytes, so a failed object delete refuses the whole request (502) and KEEPS the
    /// row — dropping it first would leave an identity document in a bucket under a
    /// name nobody can reconstruct.
    static var numbersRegistrationDocuments: [String] {
        numbersRegistrations + ["documents"]
    }

    /// ⛔ THE ONE MOMENT A REGISTRATION LEAVES THIS PLATFORM. It assembles the
    /// carrier's resources from the stored rows (an EndUser, a SupportingDocument per
    /// requirement, a Bundle tying them together), asks whether the result would
    /// pass, and FILES A REGULATED APPLICATION IN THE CUSTOMER'S NAME. 5/hour per
    /// workspace rather than its siblings' 60.
    ///
    /// ⚠️ A **422** IS "YOUR PAPERWORK IS WRONG" AND THE FILING STAYS A DRAFT; a
    /// **502** is "we could not reach the carrier". Two different sentences and two
    /// different next actions, which is why the route separates them rather than
    /// collapsing both into one failure.
    ///
    /// ⚠️ A RE-SUBMIT IS SAFE AT THE CARRIER AND IS STILL NOT AUTOMATIC HERE. The
    /// route persists each id as it is created, so a retry re-uses the EndUser and
    /// every uploaded document rather than filing a second copy of a customer's
    /// passport. That is what makes an operator's second tap cheap; it is not a
    /// licence for this client to retry a regulatory filing on its own.
    static var numbersRegistrationSubmit: [String] {
        numbersRegistrations + ["submit"]
    }

    /// Rebind one number's webhooks.
    ///
    /// ⛔ NOT A NO-OP WHEN IT LOOKS LIKE ONE, AND NOT SAFE TO SEND SPECULATIVELY. On
    /// Twilio the number-level voice URLs and a trunk binding are MUTUALLY
    /// EXCLUSIVE, so the route restates the EU trunk binding every time — otherwise
    /// a reconfigure UNBINDS an EU DID from the EU trunk and its calls are answered
    /// by the United States hub, contradicting what `/sovereign/data-residency`
    /// publishes, with a 200 either way. It fails CLOSED (**503**) rather than
    /// degrade when the trunk sid is not configured.
    ///
    /// ⚠️ **403 "Phone number not found in this workspace"** is the cross-tenant
    /// guard rather than a role refusal: on shared managed carrier accounts the
    /// resolved credentials could reconfigure any tenant's number, so ownership is
    /// asserted against the hub index first. ⚠️ **409** names a provider mismatch and
    /// is a real instruction to the operator (reconnect that account), never
    /// something to retry.
    static var numbersConfigure: [String] {
        workspace + ["numbers", "configure"]
    }

    /// ⛔ IRREVERSIBLE. The carrier takes the number back into the general pool, so
    /// it is generally NOT reclaimable, and every inbound call and message routed to
    /// it stops. Unlike a purchase there is no carrier balance that eventually stops
    /// a runaway — a loop simply keeps working until the workspace has no numbers
    /// left — so the only brake is 10/hour per workspace.
    ///
    /// ⚠️ IT CAN ANSWER **200 WITH `warnings`**, WHICH IS NOT A PARTIAL RELEASE. The
    /// number IS gone; a cleanup step after the irreversible part did not finish (a
    /// trunk still lists it, or its monthly charge could not be ended). A screen that
    /// swallowed the array would leave an operator believing they had stopped a charge
    /// they had not. See ``NumberReleaseResponse``.
    ///
    /// ⚠️ AND A **502** MEANS NOTHING WAS CHANGED, deliberately: the route refuses to
    /// run any cleanup after a carrier refusal, because every step below it is
    /// premised on the number being gone. The surviving index row is what makes a
    /// retry possible.
    static var numbersRelease: [String] {
        workspace + ["numbers", "release"]
    }

    /// A2P 10DLC brand and campaign registration.
    ///
    /// ⛔ **POST ONLY. THERE IS NO STATUS READ ANYWHERE**, so nothing in this client
    /// can ask how a submission is going — which is why a screen must adopt the
    /// POST's own answer rather than re-reading it back.
    ///
    /// ⛔ A SUCCESSFUL SUBMISSION CREATES REAL, BILLABLE, CARRIER-VETTED OBJECTS: a
    /// BrandRegistration (a one-time carrier fee), a Messaging Service, and a
    /// usAppToPerson Campaign (a monthly carrier fee this route then bills the tenant
    /// for). None is free and none is undone by retrying; a duplicate leaves an orphan
    /// brand and service on the account for a human to clear by hand in the Twilio
    /// console. 5/hour per workspace.
    ///
    /// ⚠️ ITS ORDINARY FIRST ANSWER IS A **400 carrying `code:
    /// "TRUST_BUNDLES_NOT_APPROVED"`**, and that is an account state rather than a
    /// fault: the TrustHub Customer Profile and A2P Trust Bundle are a manual,
    /// multi-day, once-per-account Console step. The route still PERSISTS the
    /// business-identity fields on that path, so a refused submission is not wasted
    /// typing.
    static var workspaceA2P: [String] {
        workspace + ["a2p"]
    }

    /// Toll-free verification.
    ///
    /// ⛔ **POST ONLY, NO STATUS READ**, like ``workspaceA2P``. Each accepted request
    /// files a real verification against the workspace's own carrier account, enters
    /// a slow MANUAL review queue, and flips the hub's `PhoneNumberIndex` row to
    /// `pending_verification` — so a loop churns a live number's routing state. A
    /// stream of duplicates for one number is the pattern that gets an account's
    /// compliance standing questioned. 10/hour per workspace.
    ///
    /// ⛔ `optInImageUrls` IS REQUIRED AND A MISSING ONE IS A **400** RATHER THAN A
    /// SUBMISSION. Twilio's reviewers open every URL by hand and reject the filing
    /// days later with error 30509 if one does not load, so refusing up front is
    /// strictly better: a doomed submission costs days and reviewer goodwill, a 400
    /// is instant and actionable. ⛔ And the evidence has to be the TENANT's own
    /// consent form: a Distronode-owned asset could never demonstrate the declared
    /// opt-in for somebody else's business, which is why the placeholder this route
    /// used to hardcode is now explicitly rejected.
    static var workspaceTfv: [String] {
        workspace + ["tfv"]
    }

    /// ⛔ ONE PATH, TWO VERBS, AND THE READ ADMITS `viewer` WHILE THE WRITE DOES NOT.
    /// GET lists the workspace's SIP trunks; POST provisions a real Twilio SIP Domain
    /// plus an IP Access Control List and opens a $25/month billing item.
    ///
    /// ⚠️ THIS IS A TWILIO-SIDE PBX ENDPOINT, NOT THE VOICE AGENT'S TRUNK. Twilio
    /// requires the domain to end in `sip.twilio.com`, so the provisioned name is
    /// `<domain>.sip.twilio.com` — a different thing entirely from
    /// `sip.distronode.com`, which is the LiveKit telephony gateway the AI agent
    /// uses. Nothing here touches that.
    ///
    /// ⚠️ THE GET'S ROWS ARE PARSED OUT OF A PACKED `productRef` STRING
    /// (`name|domain|ips|domainSid|ipAclSid`), which is why `domainSid` and `ipAclSid`
    /// are Optional on the wire: rows created before real provisioning was wired up
    /// have neither. There is no DELETE on this path, so nothing in this client can
    /// take a trunk down.
    static var workspaceSip: [String] {
        workspace + ["sip"]
    }

    /// ⛔ THE VERIFY (OTP) SERVICE'S CONFIGURATION, NOT THE OTP FLOW. GET reports
    /// whether a Twilio Verify Service exists for this workspace; POST creates one or
    /// clears the pointer to it. `workspace/verify/start` and `workspace/verify/check`
    /// are the flow itself and are absent — see the ⛔ at the head of this file.
    ///
    /// ⛔ ENABLE AND DISABLE ARE NOT SYMMETRICAL, AND THAT ASYMMETRY IS WHY THE ROUTE
    /// RATE LIMITS BOTH DIRECTIONS. Enabling creates a real, carrier-billable Verify
    /// Service; disabling deliberately does NOT delete it (verification history is
    /// preserved) and only clears our pointer. So an enable/disable/enable loop mints
    /// unbounded orphan senders that outlive the workspace's pointer and have to be
    /// reaped by hand. 10/hour per workspace, covering both branches.
    ///
    /// ⚠️ **A POST IS NOT A PATCH HERE.** The route takes `{workspaceId, enabled}` on
    /// a POST even though it changes one field of an existing row; that is the
    /// server's shape, and a PATCH would 405.
    static var workspaceVerify: [String] {
        workspace + ["verify"]
    }

    /// ⛔ **BILLABLE PER CALL, AND THE WIDEST-OPEN BILLABLE ROUTE ON THIS SURFACE.**
    /// Twilio bills every Lookup and Line Type Intelligence costs more than a basic
    /// one. It is a GET, so it is trivially loopable and reachable from an address
    /// bar with a live session, and it admits `viewer`, the lowest role. Nothing
    /// downstream caps it: the carrier bills whatever arrives, and the only brake is
    /// 60/minute per workspace.
    ///
    /// ⛔ SO NOTHING IN THIS CLIENT MAY FIRE IT ON A KEYSTROKE, ON APPEAR, OR IN A
    /// RETRY LOOP. One tap, one lookup, behind a confirmation that says out loud that
    /// it costs money. The web validates numbers as an operator types; a phone must
    /// not.
    ///
    /// ⚠️ AN UNPARSEABLE NUMBER IS A **200** carrying `info.valid: false`, not a 404 —
    /// the route translates Twilio's own 404 itself. The money is spent either way,
    /// which is the point worth knowing before treating "invalid" as a cheap answer.
    static var workspaceLookup: [String] {
        workspace + ["lookup"]
    }
}
