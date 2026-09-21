import Foundation

// The carrier-account surfaces a phone number needs before it can send or receive
// anything: SIP trunking, the Verify (OTP) service, A2P 10DLC, toll-free
// verification, and the billable number lookup.
//
// ⛔ TWO OF THESE ARE **POST-ONLY WITH NO STATUS READ ANYWHERE**, which changes what a
// DTO is FOR. ``A2PRegistrationResponse`` and ``TollFreeVerificationResponse`` are the
// only report those flows will ever produce: there is no GET, no polling route and no
// webhook we receive, so a screen must ADOPT these values rather than re-read them.
// That is the opposite of almost every other write on this surface, where the answer is
// a bare `{success:true}` and the truth is re-read.
//
// ⚠️ NONE OF THESE HAS A CONTRACT FIXTURE. The shared contract corpus mirrors the
// Android client and that client has no carrier-account surface — so
// ⛔ `ContractManifest.expectedFixtureCount` MUST NOT MOVE for them. What pins
// the shapes is the route source, quoted per type, and
// `CarrierAccountRepositoryTests`.
//
// ⚠️ A `//` HEADER RATHER THAN A `///` ONE: SwiftFormat's `docComments` rule rejects a
// doc comment attached to no declaration.

// MARK: - SIP trunking

/// One SIP trunk on the workspace's Twilio account.
///
/// ⚠️ A TWILIO-SIDE PBX ENDPOINT, NOT THE VOICE AGENT'S TRUNK. ``domain`` is
/// `<label>.sip.twilio.com` because Twilio requires that suffix; it is a different
/// thing entirely from `sip.distronode.com`, which is the LiveKit telephony gateway the
/// AI agent uses. Confusing them would have an operator pointing their PBX at the
/// agent's bus.
///
/// ⛔ ``domainSid`` AND ``ipAclSid`` ARE OPTIONAL BECAUSE OF HOW THE ROW IS STORED, NOT
/// BECAUSE THE RESOURCES ARE OPTIONAL. The list parses these out of a packed
/// `productRef` string (`name|domain|ips|domainSid|ipAclSid`) and writes an explicit
/// null for a part that is not there — which is every row created before real
/// provisioning was wired up. A row with nulls describes a billing item with no Twilio
/// resources behind it, which is worth surfacing rather than hiding.
///
/// ⚠️ ``domain`` IS ALWAYS PRESENT EVEN WHEN THE PACKED STRING IS MALFORMED, because
/// the route builds it by template interpolation — so a truncated `productRef` yields
/// the literal `undefined.sip.twilio.com` rather than a missing key. A domain reading
/// like that is a corrupt row, not a decode problem.
public struct SipTrunk: Codable, Sendable {
    /// The `ManagedBillingItem` row id, which is the only identifier this client has
    /// for a trunk — there is no per-trunk route to use it on.
    public let id: String
    public let name: String
    /// ⚠️ Fully qualified, `<label>.sip.twilio.com`. See the type doc.
    public let domain: String
    /// ⚠️ Present and possibly EMPTY: the route answers `[]` for a row whose packed
    /// string carried no addresses.
    public let ipAccessControlList: [String]
    /// ⛔ Null on a row created before real provisioning. See the type doc.
    public let domainSid: String?
    /// ⛔ Null on a row created before real provisioning. See the type doc.
    public let ipAclSid: String?
    /// The billing item's status, e.g. `active`.
    public let status: String
}

/// `GET /api/district/workspace/sip`.
///
/// ⛔ **THERE IS NO DELETE ON THIS PATH**, so nothing in this client can take a trunk
/// down and the $25/month billing item a create opened keeps standing. A screen
/// offering the create without saying so would be offering a one-way door.
///
/// ⚠️ THE READ ADMITS `viewer` AND THE WRITE DOES NOT, so a viewer sees the list and
/// must not see a create control.
public struct SipTrunksResponse: Codable, Sendable {
    public let success: Bool
    public let trunks: [SipTrunk]
}

/// `POST /api/district/workspace/sip`.
///
/// ⚠️ THE ECHOED TRUNK CARRIES REAL SIDS, unlike some rows the list returns, because
/// they were just created. Adopting it saves a re-read.
///
/// ⛔ IT CREATED THREE RESOURCES AND A RECURRING CHARGE, AND ONLY ONE FAILURE PATH
/// ROLLS ANY OF IT BACK. The route removes the Twilio domain and ACL if the WORKSPACE
/// LOOKUP fails (a 404); every other partial failure leaves what it made. So a failed
/// create is not necessarily a no-op, and a blind retry can double the resources.
public struct SipTrunkCreatedResponse: Codable, Sendable {
    public let success: Bool
    public let trunk: SipTrunk
}

// MARK: - The Verify (OTP) service

/// `GET`/`POST /api/district/workspace/verify` — one type for three bodies.
///
/// ⛔ THIS IS THE SERVICE'S CONFIGURATION, NOT THE OTP FLOW. `workspace/verify/start`
/// and `workspace/verify/check` send and check a code and are deliberately not ported.
/// What this reports is whether a Twilio Verify Service exists for the workspace at
/// all.
///
/// ⛔ ENABLE AND DISABLE ARE NOT SYMMETRICAL AND THE SID IS WHERE IT SHOWS. Enabling
/// creates a REAL, carrier-billable Verify Service; disabling deliberately does NOT
/// delete it and only clears our pointer — so a workspace can be `enabled: false` while
/// a billable OTP sender it once created is still alive on the carrier account,
/// invisible from here. A screen must not describe disabling as removing anything.
///
/// ⚠️ ``verifyServiceSid`` IS AN EXPLICIT NULL ON THE GET AND AN **ABSENT KEY** ON THE
/// DISABLE REPLY. Both decode to nil, and the distinction is worth knowing when reading
/// a capture: `{success:true, enabled:false}` from the POST is not the same document as
/// `{success:true, enabled:false, verifyServiceSid:null}` from the GET.
///
/// ⚠️ THE ENABLE REPLY IS ADOPTABLE and both branches echo ``enabled``, so this write
/// needs no re-read.
public struct VerifyServiceResponse: Codable, Sendable {
    public let success: Bool
    /// ⚠️ Derived server-side from the presence of the sid, so it cannot disagree with
    /// it on the GET.
    public let enabled: Bool
    /// ⛔ Null (GET) or absent (disable POST) when off. See the type doc.
    public let verifyServiceSid: String?
}

// MARK: - A2P 10DLC

/// `POST /api/district/workspace/a2p`.
///
/// ⛔ **THE ONLY REPORT THIS FLOW WILL EVER PRODUCE.** There is no status read
/// anywhere, so a screen adopts these four values and cannot verify any of them
/// afterwards. ⚠️ ``status`` is the CARRIER's campaign status (or the literal
/// `IN_PROGRESS` when the carrier sent none), which is a snapshot at submission and
/// nothing will update it.
///
/// ⛔ EVERY SID HERE NAMES A REAL, BILLABLE OBJECT ON THE WORKSPACE'S CARRIER ACCOUNT.
/// ``brandSid`` is a one-time carrier fee; ``campaignSid`` is a monthly one this route
/// then bills the tenant for as a `ManagedBillingItem`. None is undone by retrying, and
/// a duplicate submission leaves an orphan brand and messaging service for a human to
/// clear by hand in the Twilio console.
///
/// ⛔ THE ORDINARY FIRST ANSWER IS NOT THIS TYPE AT ALL. It is a **400 carrying `code:
/// "TRUST_BUNDLES_NOT_APPROVED"`**, which is an account state rather than a fault: the
/// TrustHub Customer Profile and A2P Trust Bundle have to clear Twilio's own regulatory
/// vetting first, a manual multi-day once-per-account Console step that no retry moves.
/// ⚠️ The route still PERSISTS the business-identity fields on that path, so a refused
/// submission is not wasted typing and must not be presented as one.
public struct A2PRegistrationResponse: Codable, Sendable {
    public let success: Bool
    /// ⚠️ A snapshot. Nothing will update it. See the type doc.
    public let status: String
    /// ⛔ A one-time carrier fee was paid for this. Never re-register.
    public let brandSid: String
    public let messagingServiceSid: String
    /// ⛔ A monthly carrier fee hangs off this.
    public let campaignSid: String
}

// MARK: - Toll-free verification

/// `POST /api/district/workspace/tfv`.
///
/// ⛔ **THE ONLY REPORT THIS FLOW WILL EVER PRODUCE**, like A2P. No status read exists.
///
/// ⛔ AND THE SUBMISSION CHANGED A LIVE NUMBER'S ROUTING STATE. The route flips the
/// hub's `PhoneNumberIndex` row to `pending_verification` after the carrier accepts, so
/// this is not an inert filing: a loop churns the state of a number that is answering
/// calls. Combined with a slow MANUAL review queue, a stream of duplicates for one
/// number is the pattern that gets an account's compliance standing questioned.
///
/// ⚠️ ``status`` IS THE CARRIER'S VERIFICATION STATUS AT SUBMISSION and will move over
/// days with nothing here to observe it. ⚠️ ``tfvSid`` is stored on the hub row, so it
/// is the handle an operator quotes to support rather than something this client can
/// resolve.
public struct TollFreeVerificationResponse: Codable, Sendable {
    public let success: Bool
    /// ⚠️ A snapshot; the real review takes days. See the type doc.
    public let status: String
    public let tfvSid: String
}

// MARK: - The billable lookup

/// What the carrier knows about one number.
///
/// ⛔ AN INVALID NUMBER STILL COST MONEY. `valid: false` arrives on a **200** — the
/// route translates Twilio's own 404 itself — so this is not a cheap "no such number"
/// answer and must never be used to probe.
///
/// ⚠️ EVERY FIELD BUT ``valid`` AND ``phoneNumber`` IS AN EXPLICIT NULL RATHER THAN
/// ABSENT, on both branches, because the route builds the object with `|| null`. So a
/// screen shows "not reported" rather than treating nil as a missing response.
///
/// ⚠️ ``type`` AND ``carrier`` COME FROM LINE TYPE INTELLIGENCE, which is the part of
/// the lookup that costs extra. Both are null when the carrier had nothing to say,
/// which is indistinguishable here from the add-on not being available on the account.
public struct NumberLookupInfo: Codable, Sendable {
    /// ⛔ False still cost a carrier call. See the type doc.
    public let valid: Bool
    /// ⚠️ The carrier's canonical spelling when it gave one, otherwise the number as
    /// asked. Never absent.
    public let phoneNumber: String
    /// ⚠️ ISO country code, explicit null when unreported.
    public let country: String?
    /// ⚠️ `mobile`, `landline`, `voip` and friends. Explicit null when unreported.
    public let type: String?
    /// ⚠️ Explicit null when unreported.
    public let carrier: String?
}

/// `GET /api/district/workspace/lookup`.
///
/// ⛔ **BILLABLE PER CALL, AND THE WIDEST-OPEN BILLABLE ROUTE ON THIS SURFACE.** Twilio
/// bills every Lookup and Line Type Intelligence costs more than a basic one. It is a
/// GET, so it is trivially loopable, and it admits `viewer`, the lowest role. Nothing
/// downstream caps it: the carrier bills whatever arrives, and 60/minute per workspace
/// is a runaway brake rather than a budget.
///
/// ⛔ SO A CALLER MUST NOT FIRE IT ON A KEYSTROKE, ON APPEAR, OR IN A RETRY LOOP, AND
/// THE CONTROL NEEDS A CONFIRMATION THAT SAYS OUT LOUD THAT IT COSTS MONEY. The web
/// validates numbers as an operator types, which is defensible on a desktop form and is
/// not on a phone where a scroll can re-run an effect.
public struct NumberLookupResponse: Codable, Sendable {
    public let success: Bool
    public let info: NumberLookupInfo
}
