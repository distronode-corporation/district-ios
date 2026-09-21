import Foundation

/// The carrier-account surfaces a phone number needs before it can send or receive
/// anything: A2P 10DLC, toll-free verification, SIP trunking, the Verify (OTP)
/// service, and the billable number lookup.
///
/// ⛔ TWO OF THESE ROUTES ARE **POST-ONLY WITH NO STATUS READ ANYWHERE**, which is a
/// property of the server rather than of this port. `workspace/a2p` and
/// `workspace/tfv` each accept a submission and answer what happened; there is no
/// GET, no polling endpoint and no webhook we receive, so a screen must ADOPT the
/// POST's own answer and cannot re-read it back. That is unusual on this surface,
/// where almost every write has a sibling read, and it is the single most important
/// thing to know before designing either flow.
///
/// ⛔ AND FOUR OF THE SIX SPEND REAL MONEY OR FILE REAL PAPERWORK. A2P creates a
/// BrandRegistration (one-time carrier fee) plus a Campaign (monthly carrier fee);
/// toll-free verification enters a slow manual review and flips a live number's
/// routing state; the SIP POST provisions a Twilio SIP Domain and opens a $25/month
/// billing item; enabling the Verify service creates a carrier-billable OTP sender
/// that OUTLIVES our pointer to it. None is undone by retrying. ⚠️ The lookup is the
/// fifth and is different in kind: it is cheap per call, and it is a GET that admits
/// `viewer`, which is what makes it the easiest one to spend by accident.
///
/// ⚠️ ITS OWN FILE RATHER THAN MORE OF `DistrictEndpoints+Numbers.swift`, for
/// SwiftLint's 500-line `file_length`. The cut is on a real seam: that file is
/// about a NUMBER (its paperwork, its webhooks, giving it back), this one is about
/// the ACCOUNT the number lives on.
public extension DistrictEndpoints {
    /// Submit an A2P 10DLC brand and campaign registration.
    ///
    /// ⛔ **NO STATUS READ EXISTS.** This POST's answer is the only report available,
    /// so a screen adopts `status`, `brandSid`, `messagingServiceSid` and
    /// `campaignSid` from it and cannot verify any of them afterwards.
    ///
    /// ⛔ IT CREATES REAL, BILLABLE, CARRIER-VETTED OBJECTS AND IS NOT IDEMPOTENT. A
    /// duplicate submission leaves an orphan Brand and Messaging Service on the
    /// account for a human to clear by hand in the Twilio console, and pays the
    /// one-time brand fee twice. ⚠️ The route's own resume guards (`if (!brandSid)`)
    /// read STORED sids, so they make a RETRY cheap and do nothing at all about
    /// concurrency: N simultaneous requests all read no stored sid and all register.
    /// The role check authorises one member to do this; it does not bound how many
    /// times. 5/hour per workspace is the only ceiling.
    ///
    /// ⛔ ITS ORDINARY FIRST ANSWER IS A **400 CARRYING `code:
    /// "TRUST_BUNDLES_NOT_APPROVED"`**, AND THAT IS AN ACCOUNT STATE RATHER THAN A
    /// FAULT. A TrustHub Customer Profile and an A2P Trust Bundle have to clear
    /// Twilio's own regulatory vetting first — a manual, multi-day, once-per-account
    /// Console step — and no amount of retrying moves it. ⚠️ The route still PERSISTS
    /// the business-identity fields on that path, deliberately, because that is
    /// exactly when whoever builds the Customer Profile needs them: a refused
    /// submission is not wasted typing, and telling the operator otherwise would
    /// invite them to type it all again.
    ///
    /// - Parameter registration: ⛔ A TYPE RATHER THAN EIGHT LOOSE ARGUMENTS, SEVEN OF THEM
    ///   STRINGS. At that shape a transposition COMPILES and posts a website where a business
    ///   name belongs, or an example message where a campaign description does. See
    ///   ``A2PRegistrationDraft``, which records what `campaignType` decides about the brand
    ///   type and the price, and why the three optional business fields survive a refusal.
    static func submitA2PRegistration(
        workspaceId: String,
        registration: A2PRegistrationDraft
    ) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .submitA2PRegistration,
            .post,
            DistrictPaths.workspaceA2P,
            body: .json(.object([
                ("workspaceId", .string(workspaceId)),
                ("businessName", .string(registration.businessName)),
                ("ein", .optional(registration.ein)),
                ("website", .optional(registration.website)),
                ("vertical", .optional(registration.vertical)),
                ("campaignType", .string(registration.campaignType)),
                ("campaignDescription", .string(registration.campaignDescription)),
                ("sampleMessage1", .string(registration.sampleMessage1)),
                ("sampleMessage2", .string(registration.sampleMessage2)),
            ]))
        )
    }

    /// Submit a toll-free verification for one number.
    ///
    /// ⛔ **NO STATUS READ EXISTS**, like ``submitA2PRegistration``. The POST's
    /// `status` and `tfvSid` are the whole report.
    ///
    /// ⛔ IT FILES A REAL VERIFICATION AGAINST THE WORKSPACE'S OWN CARRIER ACCOUNT,
    /// ENTERS A SLOW MANUAL REVIEW QUEUE, AND FLIPS THE HUB'S OWNERSHIP ROW TO
    /// `pending_verification` — so a loop churns a live number's routing state, and a
    /// stream of duplicates for one number is the pattern that gets an account's
    /// compliance standing questioned. 10/hour per workspace.
    ///
    /// ⛔ `optInImageUrls` MUST BE NON-EMPTY AND MUST BE THE TENANT'S OWN EVIDENCE.
    /// Twilio's reviewers open every URL by hand and reject the filing days later
    /// with error 30509 if one does not load, so the route refuses an empty list up
    /// front: a doomed submission costs days and reviewer goodwill, a 400 is instant
    /// and actionable. ⛔ And a Distronode-owned asset could never satisfy it in
    /// principle — this is a BYOK flow, each workspace is a different business with
    /// its own consent form, and the evidence has to demonstrate the declared opt-in
    /// for THAT business. The placeholder this route used to hardcode
    /// (`opt-in-placeholder`) is now explicitly rejected by pathname, so passing it
    /// through from anywhere is a 400.
    /// ⚠️ Each URL is parsed server-side and must be `http` or `https`; the reviewers
    /// fetch them anonymously over the public internet, so anything behind a login is
    /// a rejection weeks later rather than an error now.
    ///
    /// ⚠️ **404 "Phone number not found in this workspace"** is the ownership guard
    /// (asserted against the hub index before any carrier client is built), while
    /// **400 "…was not found on this Twilio account"** is a different thing entirely:
    /// the number is this workspace's but does not live on the connected Twilio
    /// account. Two refusals that read alike and mean opposite things.
    ///
    /// - Parameter verification: ⛔ A TYPE RATHER THAN SEVEN LOOSE ARGUMENTS, SIX OF THEM
    ///   STRINGS. See ``TollFreeVerificationDraft``, which records that `useCase` is mapped
    ///   rather than validated, and that two of the optionals have server-side fallbacks a
    ///   human reviewer will actually read.
    static func submitTollFreeVerification(
        workspaceId: String,
        verification: TollFreeVerificationDraft
    ) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .submitTollFreeVerification,
            .post,
            DistrictPaths.workspaceTfv,
            body: .json(.object([
                ("workspaceId", .string(workspaceId)),
                ("phoneNumber", .string(verification.phoneNumber)),
                ("businessName", .string(verification.businessName)),
                ("website", .optional(verification.website)),
                ("useCase", .string(verification.useCase)),
                ("messageContent", .optional(verification.messageContent)),
                ("optInFlow", .optional(verification.optInFlow)),
                // ⚠️ ALWAYS SENT, EVEN EMPTY, so the refusal is the route's own
                // sentence about opt-in evidence rather than a generic missing-field
                // 400. The route accepts a bare string too; an array is what the web
                // sends and matching it keeps a capture from one readable as the other.
                ("optInImageUrls", .array(verification.optInImageUrls.map { JSONValue.string($0) })),
            ]))
        )
    }

    /// The workspace's SIP trunks.
    ///
    /// ⚠️ A TWILIO-SIDE PBX ENDPOINT, NOT THE VOICE AGENT'S TRUNK. The provisioned
    /// domain is `<domain>.sip.twilio.com` because Twilio requires that suffix — a
    /// different thing entirely from `sip.distronode.com`, which is the LiveKit
    /// telephony gateway the AI agent's own SIP trunks use. Nothing on this route
    /// touches that.
    ///
    /// ⚠️ THE ROWS ARE PARSED OUT OF A PACKED STRING. `productRef` holds
    /// `name|domain|ips|domainSid|ipAclSid`, which is why ``SipTrunk/domainSid`` and
    /// ``SipTrunk/ipAclSid`` are Optional on the wire: rows created before real
    /// provisioning was wired up carry neither, and the route writes an explicit null
    /// for them.
    ///
    /// ⛔ THERE IS NO DELETE ON THIS PATH, so nothing in this client can take a trunk
    /// down — and the $25/month billing item it opened keeps standing. A screen that
    /// offered a create without saying so would be offering a one-way door.
    ///
    /// ⚠️ THE READ ADMITS `viewer` AND THE WRITE DOES NOT.
    static func sipTrunks(workspaceId: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .sipTrunks,
            .get,
            DistrictPaths.workspaceSip,
            query: [ApiQueryItem("workspaceId", workspaceId)]
        )
    }

    /// Provision a SIP trunk.
    ///
    /// ⛔ IT CREATES THREE REAL RESOURCES AND OPENS A $25/MONTH BILLING ITEM, AND
    /// THERE IS NO ROUTE TO UNDO ANY OF IT. An IP Access Control List, its member
    /// addresses, and a Twilio SIP Domain with the ACL mapped onto it. The route rolls
    /// the Twilio side back only if the WORKSPACE LOOKUP fails (a 404); every other
    /// partial failure leaves what it created.
    ///
    /// ⛔ AT LEAST ONE IP OR CIDR RANGE IS REQUIRED and an empty list is a **400**
    /// rather than an open trunk, which is the correct direction: a SIP domain with no
    /// ACL is an endpoint anybody can register against.
    ///
    /// ⚠️ IT REQUIRES TWILIO SPECIFICALLY. A workspace on Sinch or Telnyx gets a
    /// **400** naming that, not a role refusal.
    ///
    /// - Parameters:
    ///   - domain: ⚠️ THE LABEL ONLY. The route appends `.sip.twilio.com`, so passing
    ///     a full domain produces `example.sip.twilio.com.sip.twilio.com`.
    ///   - ipAccessControlList: ⚠️ Each entry is an address or `address/prefix`; the
    ///     route splits on `/` and passes the prefix length through. Blank entries are
    ///     dropped server-side, which is why an all-blank list is the same 400 as an
    ///     empty one.
    static func createSipTrunk(
        workspaceId: String,
        name: String,
        domain: String,
        ipAccessControlList: [String]
    ) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .createSipTrunk,
            .post,
            DistrictPaths.workspaceSip,
            body: .json(.object([
                ("workspaceId", .string(workspaceId)),
                ("name", .string(name)),
                ("domain", .string(domain)),
                ("ipAccessControlList", .array(ipAccessControlList.map { JSONValue.string($0) })),
            ]))
        )
    }

    /// Whether the Verify (OTP) service exists for this workspace.
    ///
    /// ⛔ THIS IS THE SERVICE'S CONFIGURATION, NOT THE OTP FLOW.
    /// `workspace/verify/start` and `workspace/verify/check` send and check a code and
    /// are deliberately not ported — see the ⚠️ at the top of
    /// `DistrictEndpoints+Numbers.swift`. What this reads is whether a Twilio Verify
    /// Service has been created and its sid persisted.
    ///
    /// ⚠️ ADMITS `viewer` WHILE THE WRITE DOES NOT.
    ///
    /// ⚠️ `verifyServiceSid` IS AN EXPLICIT NULL HERE AND AN ABSENT KEY ON THE DISABLE
    /// RESPONSE, which decode identically and are worth knowing apart when reading a
    /// capture. See ``VerifyServiceResponse``.
    static func verifyService(workspaceId: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .verifyService,
            .get,
            DistrictPaths.workspaceVerify,
            query: [ApiQueryItem("workspaceId", workspaceId)]
        )
    }

    /// Turn the Verify (OTP) service on or off.
    ///
    /// ⛔ **A POST, NOT A PATCH**, even though it changes one field. That is the
    /// server's shape; a PATCH would 405.
    ///
    /// ⛔ ENABLE AND DISABLE ARE NOT SYMMETRICAL, AND THE ASYMMETRY IS WHAT MAKES THIS
    /// ABUSABLE. Enabling creates a REAL, carrier-billable Twilio Verify Service.
    /// Disabling deliberately does NOT delete it — verification history and config are
    /// preserved — and only clears our pointer. So an enable/disable/enable loop mints
    /// an unbounded number of billable OTP senders, each of which outlives the
    /// workspace's pointer to it and has to be reaped by hand in the Twilio Console.
    /// ⚠️ That is why the route's 10/hour limit covers BOTH directions and sits above
    /// the `!enabled` branch: limiting only the enable half would leave the other half
    /// of the same loop uncapped, and the loop needs both.
    ///
    /// ⚠️ AN ENABLE ON AN ALREADY-CONFIGURED WORKSPACE IS A CHEAP SHORT-CIRCUIT
    /// answering the stored sid, which caps the steady state at one service — but only
    /// while the pointer survives, which the disable path removes.
    ///
    /// ⚠️ IT REQUIRES TWILIO SPECIFICALLY: a workspace on another carrier gets a
    /// **400** naming that rather than a role refusal.
    ///
    /// ⚠️ THE ANSWER IS ADOPTABLE. Both branches echo `enabled`, and the enable branch
    /// echoes the sid, so this write needs no re-read.
    static func setVerifyServiceEnabled(workspaceId: String, enabled: Bool) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .setVerifyServiceEnabled,
            .post,
            DistrictPaths.workspaceVerify,
            body: .json(.object([
                ("workspaceId", .string(workspaceId)),
                // ⚠️ A REAL BOOLEAN, NOT A STRING. The route checks `typeof enabled
                // !== "boolean"` and answers 400 "Missing required fields" for
                // anything else, which reads as a missing key rather than a wrong type.
                ("enabled", .bool(enabled)),
            ]))
        )
    }

    /// Look one phone number up at the carrier.
    ///
    /// ⛔ **BILLABLE PER CALL, AND THE WIDEST-OPEN BILLABLE ROUTE ON THIS WHOLE
    /// SURFACE.** Twilio bills every Lookup and Line Type Intelligence costs more than
    /// a basic one. It is a GET, so it is trivially loopable, and it admits `viewer`,
    /// the lowest role. Nothing downstream caps it: the carrier bills whatever
    /// arrives, and the only brake is 60/minute per workspace — which is a runaway
    /// brake, not a budget.
    ///
    /// ⛔ SO IT MUST NOT FIRE ON A KEYSTROKE, ON APPEAR, OR IN A RETRY LOOP, AND IT
    /// NEEDS A CONFIRMATION THAT SAYS OUT LOUD THAT IT COSTS MONEY. The web validates
    /// numbers as an operator types, which is defensible on a desktop form and is not
    /// on a phone where a scroll can re-run an effect. One tap, one lookup.
    ///
    /// ⚠️ AN UNPARSEABLE NUMBER IS A **200 CARRYING `info.valid: false`**, not a 404 —
    /// the route translates Twilio's own 404 itself. The money is spent either way,
    /// which is the fact worth knowing before treating "invalid" as a cheap answer or
    /// as something to probe for.
    ///
    /// ⚠️ IT REQUIRES TWILIO SPECIFICALLY: another carrier is a **400** naming that.
    static func lookupNumber(workspaceId: String, phoneNumber: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .lookupNumber,
            .get,
            DistrictPaths.workspaceLookup,
            query: [
                ApiQueryItem("workspaceId", workspaceId),
                ApiQueryItem("phoneNumber", phoneNumber),
            ]
        )
    }
}
