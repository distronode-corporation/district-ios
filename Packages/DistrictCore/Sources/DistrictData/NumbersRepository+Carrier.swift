import DistrictModel
import DistrictNetwork
import Foundation

/// The carrier-account surfaces a number needs before it can send or receive anything.
///
/// ⛔ TWO OF THESE ARE **POST-ONLY WITH NO STATUS READ ANYWHERE**, and that changes the
/// obligation on the caller rather than only the shape of the code.
/// ``submitA2PRegistration`` and ``submitTollFreeVerification`` answer the only report
/// their flows will ever produce: there is no GET, no polling route, and no webhook we
/// receive. A screen must ADOPT what comes back and cannot re-read it, which is the
/// opposite of nearly every other write on this surface.
///
/// ⛔ AND FOUR OF THE FIVE WRITES HERE SPEND REAL MONEY THAT NO RETRY UNDOES. A2P pays a
/// one-time carrier brand fee and opens a monthly campaign fee; toll-free verification
/// enters a slow manual review and flips a live number's routing state; the SIP create
/// provisions three Twilio resources and opens a $25/month billing item with **no route
/// to take it down**; enabling the Verify service mints a carrier-billable OTP sender
/// that OUTLIVES our pointer to it. ⚠️ The lookup is different in kind and is the easiest
/// to spend by accident: cheap per call, a GET, and it admits `viewer`.
public extension NumbersRepository {
    /// The workspace's SIP trunks.
    ///
    /// ⛔ THERE IS NO DELETE ON THIS PATH, so nothing in this client can take a trunk
    /// down and the $25/month billing item a create opened keeps standing. A screen
    /// offering the create without saying so would be offering a one-way door.
    ///
    /// ⚠️ THE READ ADMITS `viewer` AND THE WRITE DOES NOT, so a viewer may see this list
    /// and must not see a create control.
    ///
    /// ⚠️ AN EMPTY LIST IS A REAL ANSWER. Most workspaces have no SIP trunk at all, which
    /// is why the envelope check matters here: "we could not look" drawn as "you have
    /// none" would invite a duplicate provision, and a duplicate is a second $25/month.
    func sipTrunks(workspaceId: String) async -> Result<SipTrunksResponse, ApiError> {
        let outcome = await client.send(
            DistrictEndpoints.sipTrunks(workspaceId: workspaceId),
            as: SipTrunksResponse.self
        )
        return outcome.flatMap { response in
            ResponseEnvelope.affirm("SipTrunksResponse", response.success, response)
        }
    }

    /// Provision a SIP trunk.
    ///
    /// ⛔ ``NumberWriteRepeat/once``. It creates an IP Access Control List, its member
    /// addresses and a Twilio SIP Domain, and opens a recurring $25/month charge — and
    /// there is no route to undo any of it. ⚠️ Only ONE failure path rolls the Twilio
    /// side back (a workspace lookup miss, answered 404); every other partial failure
    /// leaves what it created, so a blind retry can double the resources AND the charge.
    /// That is why a failure here must not silently re-arm the control.
    ///
    /// ⛔ AT LEAST ONE IP OR CIDR RANGE IS REQUIRED and an empty list is a **400** rather
    /// than an open trunk — the correct direction, since a SIP domain with no ACL is an
    /// endpoint anybody can register against. Blank entries are dropped server-side, so
    /// an all-blank list is the same 400 as an empty one.
    ///
    /// ⚠️ IT REQUIRES TWILIO SPECIFICALLY: a workspace on Sinch or Telnyx gets a **400**
    /// naming that, which is an account state rather than a fault and no retry fixes it.
    ///
    /// - Parameter domain: ⚠️ THE LABEL ONLY. The route appends `.sip.twilio.com`, so a
    ///   full domain here produces `example.sip.twilio.com.sip.twilio.com`.
    func createSipTrunk(
        workspaceId: String,
        name: String,
        domain: String,
        ipAccessControlList: [String]
    ) async -> Result<SipTrunkCreatedResponse, ApiError> {
        let descriptor = DistrictEndpoints.createSipTrunk(
            workspaceId: workspaceId,
            name: name,
            domain: domain,
            ipAccessControlList: ipAccessControlList
        )
        let outcome = await client.send(descriptor, as: SipTrunkCreatedResponse.self)
        return outcome.flatMap { response in
            ResponseEnvelope.affirm("SipTrunkCreatedResponse", response.success, response)
        }
    }

    /// Whether the Verify (OTP) service exists for this workspace.
    ///
    /// ⛔ THIS IS THE SERVICE'S CONFIGURATION, NOT THE OTP FLOW.
    /// `workspace/verify/start` and `workspace/verify/check` send and check a code and
    /// are deliberately unported — an OTP entry screen owns its own retry, expiry and
    /// attempt-ceiling states. Named here so nobody has to rediscover them.
    ///
    /// ⚠️ ADMITS `viewer` WHILE THE WRITE DOES NOT.
    func verifyService(workspaceId: String) async -> Result<VerifyServiceResponse, ApiError> {
        let outcome = await client.send(
            DistrictEndpoints.verifyService(workspaceId: workspaceId),
            as: VerifyServiceResponse.self
        )
        return outcome.flatMap { response in
            ResponseEnvelope.affirm("VerifyServiceResponse", response.success, response)
        }
    }

    /// Turn the Verify (OTP) service on or off.
    ///
    /// ⛔ ``NumberWriteRepeat/once``, AND THE REASON IS THE ASYMMETRY RATHER THAN THE
    /// COST OF ONE CALL. Enabling creates a REAL, carrier-billable Twilio Verify
    /// Service. Disabling deliberately does NOT delete it — verification history is
    /// preserved — and only clears our pointer. So an enable/disable/enable loop mints
    /// an unbounded number of billable OTP senders, each outliving the workspace's
    /// pointer to it and needing to be reaped by hand in the Twilio console. ⚠️ The
    /// route's 10/hour limit covers BOTH directions and sits above the `!enabled`
    /// branch, because limiting only the enable half would leave the other half of the
    /// same loop uncapped.
    ///
    /// ⛔ SO A SCREEN MUST NOT DESCRIBE DISABLING AS REMOVING ANYTHING. A workspace can
    /// read `enabled: false` while a sender it once created is still alive on the
    /// carrier account, invisible from here.
    ///
    /// ⚠️ AN ENABLE ON AN ALREADY-CONFIGURED WORKSPACE IS A CHEAP SHORT-CIRCUIT
    /// answering the stored sid, which is what caps the steady state at one service —
    /// but only while the pointer survives, which the disable path removes.
    ///
    /// ⚠️ THE ANSWER IS ADOPTABLE: both branches echo `enabled` and the enable branch
    /// echoes the sid, so this write needs no re-read.
    func setVerifyServiceEnabled(
        workspaceId: String,
        enabled: Bool
    ) async -> Result<VerifyServiceResponse, ApiError> {
        let descriptor = DistrictEndpoints.setVerifyServiceEnabled(workspaceId: workspaceId, enabled: enabled)
        let outcome = await client.send(descriptor, as: VerifyServiceResponse.self)
        return outcome.flatMap { response in
            ResponseEnvelope.affirm("VerifyServiceResponse", response.success, response)
        }
    }

    /// Submit an A2P 10DLC brand and campaign registration.
    ///
    /// ⛔ ``NumberWriteRepeat/once``, AND THERE IS NO STATUS READ TO CHECK AFTERWARDS.
    /// The reply is the only report this flow will ever produce, so a screen adopts
    /// `status`, `brandSid`, `messagingServiceSid` and `campaignSid` and cannot verify
    /// any of them later.
    ///
    /// ⛔ IT CREATES REAL, BILLABLE, CARRIER-VETTED OBJECTS AND IS NOT IDEMPOTENT. A
    /// duplicate leaves an orphan Brand and Messaging Service on the account for a human
    /// to clear by hand, and pays the one-time brand fee twice. ⚠️ The route's resume
    /// guards read STORED sids, so they make a deliberate RETRY cheap and do nothing
    /// about concurrency: N simultaneous requests all read no stored sid and all
    /// register. The role check authorises one member to do this; it does not bound how
    /// many times, and 5/hour is the only ceiling.
    ///
    /// ⛔ ITS ORDINARY FIRST ANSWER IS A **400 CARRYING `code:
    /// "TRUST_BUNDLES_NOT_APPROVED"`**, WHICH IS AN ACCOUNT STATE RATHER THAN A FAULT.
    /// The TrustHub Customer Profile and A2P Trust Bundle must clear Twilio's own
    /// regulatory vetting first: a manual, multi-day, once-per-account Console step that
    /// no retry moves. It must render as an explanatory state with no retry button, the
    /// same call ``MarketplaceSearchState/notConfigured(_:)`` makes for the search's 400.
    /// ⚠️ AND THE TYPING IS NOT LOST ON THAT PATH: the route persists the
    /// business-identity fields anyway, deliberately, because that is exactly when
    /// whoever builds the Customer Profile needs them. Telling the operator to start
    /// again would be wrong.
    /// - Parameter registration: ⛔ A TYPE RATHER THAN EIGHT LOOSE ARGUMENTS. See
    ///   ``A2PRegistrationDraft``; seven of its fields are strings and a transposition at a call
    ///   site would compile and pay a carrier brand fee against the wrong details.
    func submitA2PRegistration(
        workspaceId: String,
        registration: A2PRegistrationDraft
    ) async -> Result<A2PRegistrationResponse, ApiError> {
        let descriptor = DistrictEndpoints.submitA2PRegistration(
            workspaceId: workspaceId,
            registration: registration
        )
        let outcome = await client.send(descriptor, as: A2PRegistrationResponse.self)
        return outcome.flatMap { response in
            ResponseEnvelope.affirm("A2PRegistrationResponse", response.success, response)
        }
    }

    /// Submit a toll-free verification for one number.
    ///
    /// ⛔ ``NumberWriteRepeat/once``, NO STATUS READ, AND IT CHANGED A LIVE NUMBER'S
    /// ROUTING STATE. The route flips the hub's ownership row to
    /// `pending_verification` once the carrier accepts, so this is not an inert filing:
    /// a loop churns the state of a number that is answering calls. With a slow MANUAL
    /// review behind it, a stream of duplicates for one number is the pattern that gets
    /// an account's compliance standing questioned. 10/hour per workspace.
    ///
    /// ⛔ `optInImageUrls` MUST BE NON-EMPTY AND MUST BE THE TENANT'S OWN EVIDENCE.
    /// Reviewers open every URL by hand and reject the filing days later with error
    /// 30509 if one does not load, so the route refuses an empty list up front — a 400
    /// now beats losing days. ⛔ And a Distronode-owned asset could never satisfy it in
    /// principle: this is a BYOK flow, every workspace is a different business, and the
    /// evidence has to demonstrate THAT business's declared opt-in. The placeholder this
    /// route once hardcoded is explicitly rejected by pathname, so passing it through
    /// from anywhere is a 400.
    ///
    /// ⚠️ TWO REFUSALS READ ALIKE AND MEAN OPPOSITE THINGS. **404 "Phone number not
    /// found in this workspace"** is the ownership guard against the hub index; **400
    /// "…was not found on this Twilio account"** means the number IS this workspace's
    /// but does not live on the connected carrier account. The first is somebody else's
    /// number, the second is a mis-wired account.
    /// - Parameter verification: ⛔ A TYPE RATHER THAN SEVEN LOOSE ARGUMENTS. See
    ///   ``TollFreeVerificationDraft``. ⚠️ It was already under SwiftLint's parameter ceiling
    ///   here — three of the seven carried defaults, which the rule does not count — and it is a
    ///   draft anyway, because the ceiling was never the reason: six of the seven are strings.
    func submitTollFreeVerification(
        workspaceId: String,
        verification: TollFreeVerificationDraft
    ) async -> Result<TollFreeVerificationResponse, ApiError> {
        let descriptor = DistrictEndpoints.submitTollFreeVerification(
            workspaceId: workspaceId,
            verification: verification
        )
        let outcome = await client.send(descriptor, as: TollFreeVerificationResponse.self)
        return outcome.flatMap { response in
            ResponseEnvelope.affirm("TollFreeVerificationResponse", response.success, response)
        }
    }

    /// Look one phone number up at the carrier.
    ///
    /// ⛔ ``NumberWriteRepeat/once`` ON A **GET**, WHICH IS THE POINT. Twilio bills every
    /// Lookup and Line Type Intelligence costs more than a basic one, so the ordinary
    /// safety of an idempotent read does not apply: repeating it is free of side effects
    /// and not free of money. It is also the widest-open billable route on this surface —
    /// a GET that admits `viewer`, the lowest role — and nothing downstream caps it. The
    /// only brake is 60/minute per workspace, which is a runaway brake rather than a
    /// budget.
    ///
    /// ⛔ SO A CALLER MUST NOT FIRE THIS ON A KEYSTROKE, ON APPEAR, OR IN A RETRY LOOP,
    /// AND THE CONTROL NEEDS A CONFIRMATION THAT SAYS OUT LOUD THAT IT COSTS MONEY. One
    /// tap, one lookup. The web validates numbers as an operator types, which is
    /// defensible on a desktop form and is not on a phone where a scroll can re-run an
    /// effect. ⚠️ This is why there is deliberately no convenience that takes a list.
    ///
    /// ⚠️ AN UNPARSEABLE NUMBER IS A **200 CARRYING `info.valid: false`**, not a 404 —
    /// the route translates Twilio's own 404 itself. The money is spent either way, so
    /// "invalid" is not a cheap answer and must not be probed for.
    ///
    /// ⚠️ IT REQUIRES TWILIO SPECIFICALLY: another carrier is a **400** naming that,
    /// which is an account state and no retry fixes it.
    func lookupNumber(workspaceId: String, phoneNumber: String) async -> Result<NumberLookupResponse, ApiError> {
        let descriptor = DistrictEndpoints.lookupNumber(workspaceId: workspaceId, phoneNumber: phoneNumber)
        let outcome = await client.send(descriptor, as: NumberLookupResponse.self)
        return outcome.flatMap { response in
            ResponseEnvelope.affirm("NumberLookupResponse", response.success, response)
        }
    }
}
