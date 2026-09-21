import DistrictModel
import DistrictNetwork
import Foundation

/// What happened to one dial.
///
/// ⛔ FOUR CASES, AND THE THREE REFUSALS EXIST BECAUSE THEIR REMEDIES ARE
/// DIFFERENT RATHER THAN BECAUSE THEIR STATUS CODES ARE. Collapsing them into a
/// bare ``ApiError`` leaves the dialer with a status and a sentence and nothing
/// to branch on, so a screen wanting to say "ask us to turn this workspace back
/// on" would have to substring-match English the server rewrites without a
/// version bump. The Kotlin client took the same decision for the same reason
/// (`DialOutcome` in `core-data`), and this enum is its Swift sibling.
///
/// ⛔ EVERY REFUSAL CARRIES THE SERVER'S OWN SENTENCE, WHICH IS A DIVERGENCE
/// FROM KOTLIN AND A DELIBERATE ONE. Kotlin's coded cases are `data object`s
/// with no payload, on the rule that a `code` is the contract and the prose is
/// the client's to author. That rule holds for the wording of a REMEDY; it does
/// not hold for the dormancy refusal, whose sentence is the only place the
/// 100-day window and the reactivation instruction are stated at all
/// (`CallsAnalyticsContractTests` pins it verbatim for exactly that reason). A
/// client that paraphrased it would tell the operator something the server did
/// not say. The message is nil-able, so a screen still owns a fallback.
///
/// ⛔ NOTHING HERE CARRIES THE 402's `status` FIELD, AND THAT IS THE POINT OF
/// LEAVING IT OUT. ``SubscriptionInactiveError/status`` is modelled because a
/// committed fixture proves the key exists, and its own doc forbids branching on
/// it — which Stripe states count as delinquent is the server's decision. Lifting
/// it into an outcome a screen can see is how a client ends up deciding for
/// itself, so the repository never decodes that type.
///
/// ⚠️ NOT `Equatable`. ``DialResponse`` is a gate-pinned wire shape and adding a
/// conformance to it to make an assertion terser would be the tail wagging the
/// dog; the tests pattern-match instead.
public enum DialOutcome: Sendable {
    /// The carrier accepted the dial and the credential is usable.
    ///
    /// ⚠️ NOT "THE CALLEE ANSWERED". The route returns before the far end picks
    /// up, deliberately (it does not pass `waitUntilAnswered`), so the app is in
    /// the room hearing call progress while the phone is still ringing. A screen
    /// that rendered this as "connected" would be wrong about the most visible
    /// thing on it.
    case placed(DialResponse)

    /// 403: the number has opted out of this workspace's calls.
    ///
    /// ⛔ CLASSIFIED STRUCTURALLY, NOT BY A `code`, BECAUSE THE ROUTE PUBLISHES
    /// NONE FOR IT. See the ⛔ on ``DialRepository`` for what that costs and why
    /// the sentence below is the server's rather than this client's.
    case doNotCall(message: String?)

    /// 402 `subscription_inactive`: the workspace's plan is delinquent or
    /// terminated, so every billable action is refused rather than this call
    /// specifically.
    ///
    /// ⛔ THE REMEDY IS ON THE WEB AND THIS APP MUST NOT OFFER ONE. App Store
    /// Review Guideline 3.1.3(b) keeps subscription purchase and management out
    /// of the app entirely, so the wording names the website and stops; a
    /// "Fix billing" control that deep-linked to Stripe is the rejection.
    case subscriptionInactive(message: String?)

    /// 403 `workspace_dormant`: nothing has been sent for 100 days and outbound
    /// calling and messaging are paused pending an account review.
    ///
    /// ⛔ NOT A BILLING FAILURE AND NOT A PERMISSION FAILURE. `subscription_
    /// inactive` means "pay and it resumes"; this means "ask us and we turn it
    /// back on", and the dashboard has a reactivation route that the server's
    /// own sentence points at. Rendered as a generic 403 it reads
    /// as an account the operator has lost.
    case workspaceDormant(message: String?)
}

/// What happened to one server-side hang-up.
///
/// ⛔ ALL FOUR CASES ARE `.success`, WHICH IS FURTHER THAN ``DialOutcome`` GOES AND
/// IS CORRECT FOR A DIFFERENT REASON. There, three refusals are successes because
/// each needs its own sentence on screen. Here NOTHING reaches a screen at all:
/// the request is fired on a teardown that has already happened, so there is no
/// surface left to say anything on and no remedy to offer. What the cases buy is a
/// LOG line that says which of four things happened, and the difference between
/// them is the difference between "the leg was up and we ended it" and "we were
/// too late", which is exactly the question the billing defect turns on.
///
/// ⚠️ `Equatable`, UNLIKE ``DialOutcome`` AND ``AnswerOutcome``. Those two carry
/// gate-pinned wire DTOs and conforming one to make an assertion terser would be
/// the tail wagging the dog; this enum carries no payload at all.
public enum HangUpOutcome: Sendable, Equatable {
    /// 200 `{"ended": true}` — this request tore the room down.
    case ended

    /// 200 `{"ended": false}` — the call was already gone.
    ///
    /// ⛔ NOT A FAILURE, AND THE COMMON CASE ON TWO OF THE FOUR PATHS THAT SEND
    /// THIS. A callee who hangs up first, and a media failure that is reported
    /// after the SIP leg has already dropped, both land here.
    case alreadyEnded

    /// 404: no call with this id that this workspace can see.
    ///
    /// ⚠️ INDISTINGUISHABLE FROM ANOTHER TENANT'S ID, like every other per-call
    /// route: the server reads by id and checks ownership afterwards.
    case notFound

    /// 409: the call exists and is not a direct softphone call.
    ///
    /// ⛔ UNREACHABLE FROM THIS CLIENT TODAY AND MODELLED ANYWAY. The only caller
    /// is ``SoftphoneSession``, whose id can only have come from
    /// ``DialResponse/callId``, so a 409 here would mean the server had reclassified
    /// a call this app placed — a contract fact worth seeing in a log rather than
    /// folding into a generic failure.
    case notDirectCall
}

/// Placing one outbound call, and ending it.
///
/// ⛔ TWO WRITES WITH OPPOSITE RULES, ONE PATH SEGMENT APART, WHICH IS WHY THEY
/// SHARE A FILE RATHER THAN IN SPITE OF IT. ``dial(workspaceId:to:)`` may never be
/// re-sent; ``hangUp(workspaceId:callId:)`` is sent on endings that have already
/// happened. Keeping them together is what makes the asymmetry readable instead of
/// leaving a second file to restate half of it and drift.
///
/// ⛔ THE ONLY WRITE IN THIS CLIENT WHOSE FAILURE MODE IS A TELEPHONE RINGING
/// WITH NOBODY ON IT. The server writes the `Call` row and instructs the carrier
/// BEFORE it mints the credential it answers with, so a 5xx here may be a call
/// that is already happening.
///
/// ⛔ NO RETRY MAY BE ADDED TO ``dial(workspaceId:to:)``, at this layer or above
/// it. Every other write on this surface is safe to re-send — a duplicate member
/// add is a 409, a duplicate draft save overwrites, and ``hangUp(workspaceId:
/// callId:)`` next door is idempotent BY DESIGN and is deliberately sent on paths
/// that may have sent it already — and this one places a second call,
/// bills for it, and rings the callee again. ⚠️ The property is a property of
/// the DIAL, not of the type: the file holds a second write with the opposite
/// rule. ``ApiClient`` does not retry either,
/// and ``TokenRefreshCoordinator`` only supplies tokens (it has no resend), so
/// today the property holds by construction rather than by a flag. The workspace
/// rate limit of 20 dials a minute is a backstop against a stuck finger, not a
/// design.
///
/// ⛔ THE DNC REFUSAL HAS NO `code`, AND CLASSIFYING IT IS THE ONE JUDGEMENT
/// THIS FILE MAKES. `POST /api/district/calls/dial` answers an opted-out number
/// with `{success:false, error}` at 403 and nothing machine-readable. The Kotlin
/// client concluded that it is therefore indistinguishable from the role refusal
/// the same route can emit, and folded both into its catch-all — correctly, for
/// that client: `ApiResult.HttpFailure` keeps `status`, `message` and `code` and
/// DROPS the `success` key, so the distinction is not visible from where its
/// decision is made.
///
/// It is visible from here. ``ApiErrorEnvelope/success`` is `Bool?` precisely
/// because the API ships three envelope shapes, and the two 403s this route can
/// produce are different ones: the shared auth guard's role refusal is a bare
/// `{error}` with NO `success` key, while DNC is the route's own
/// `{success:false, error}`. So the test is: **403, an explicitly false
/// `success`, and no `code`.**
///
/// ⛔ ALL THREE TERMS ARE LOAD-BEARING AND DROPPING ANY ONE MISCLASSIFIES A REAL
/// BODY. Without the status check the route's own catch branch — a 500 carrying
/// `{success:false, error}` — becomes a compliance refusal, and so do its three
/// 400s ("Invalid phone number", "No phone number configured", the Sinch
/// constraint). Without the `success` check the role refusal does. Without the
/// `code` check the dormancy 403 does, since it is the DNC shape plus a code.
///
/// ⚠️ AND IF THE ROUTE EVER GROWS A SECOND UNCODED 403 OF ITS OWN, IT WILL LAND
/// HERE. That is why ``DialOutcome/doNotCall(message:)`` carries the server's
/// sentence instead of client-authored DNC copy: a misfire then shows a true
/// sentence under a wrong case name, rather than telling an operator a number is
/// on a do-not-call list when it is not. Giving DNC a `code` server-side is the
/// real fix, and it is recorded as a finding on both clients.
public struct DialRepository: Sendable {
    private let client: ApiClient

    public init(client: ApiClient) {
        self.client = client
    }

    /// Dial `to` on behalf of `workspaceId`.
    ///
    /// ⚠️ THE NUMBER GOES AS TYPED. Normalisation is the server's and it runs
    /// BEFORE the DNC lookup and before the dial, so a client-side canonicaliser
    /// that disagreed by one character would place a call the compliance check
    /// never saw. See ``DistrictEndpoints/dial(workspaceId:to:)``.
    ///
    /// ⛔ `sendUnmapped`, BECAUSE THE REFUSAL BODY IS PART OF THE ANSWER. The
    /// `code` and the `success` key are what separate three different remedies
    /// from each other, and ``ApiError`` keeps neither. ``WorkspaceRepository``
    /// reaches for the same method for the same reason.
    ///
    /// - Returns: `.failure` for everything that is not one of the three known
    ///   refusals — offline, signed out, the role 403, the rate limit, a 400 for
    ///   an unusable number or a Sinch-only workspace, a 5xx, contract drift —
    ///   already normalised by ``ApiErrorNormalizer``.
    public func dial(workspaceId: String, to: String) async -> Result<DialOutcome, ApiError> {
        let outcome = await client.sendUnmapped(DistrictEndpoints.dial(workspaceId: workspaceId, to: to))
        return outcome.flatMap(Self.classify)
    }

    /// Ask the server to end `callId`, carrier leg included.
    ///
    /// ⛔ BEST EFFORT, AND THE CALLER MUST NEVER WAIT ON IT OR SHOW ITS RESULT.
    /// Every local teardown has already happened by the time this is sent: the OS
    /// has been told, the socket is closing, and the operator is looking at a call
    /// summary. A failure here is a log line. Rendering one would put an error over
    /// a call that ended correctly from the user's point of view, and blocking on
    /// it would hold the call screen open on a network timeout.
    ///
    /// ⛔ SAFE TO SEND TWICE, WHICH IS THE ONE WAY IT DIFFERS FROM EVERY OTHER
    /// WRITE IN THIS FILE. ``dial(workspaceId:to:)`` may never be re-sent because a
    /// re-send places a second call; this route is idempotent by contract and the
    /// design leans on it, because the case it exists for is a hang-up racing a
    /// dial response that has not arrived yet. ⚠️ That is a licence to send it on
    /// paths that may have already sent it, NOT a licence to add a retry: a retry
    /// loop on a teardown path would spend requests after a call nobody is on.
    ///
    /// ⛔ `sendUnmapped`, FOR THE THIRD TIME IN THIS FAMILY AND FOR THE FAMILIAR
    /// REASON. 404 and 409 are answers rather than errors, and the 200's `ended`
    /// key is a fact ``ApiError`` could never carry.
    ///
    /// - Returns: `.failure` only for things that are genuinely faults — offline,
    ///   signed out, the role 403, a 5xx, contract drift — already normalised by
    ///   ``ApiErrorNormalizer``.
    public func hangUp(workspaceId: String, callId: String) async -> Result<HangUpOutcome, ApiError> {
        let outcome = await client.sendUnmapped(
            DistrictEndpoints.hangUpCall(callId: callId, workspaceId: workspaceId)
        )
        return outcome.flatMap(Self.classifyHangUp)
    }

    private static func classifyHangUp(_ response: RawResponse) -> Result<HangUpOutcome, ApiError> {
        guard (200 ... 299).contains(response.statusCode) else {
            return hangUpRefusal(response)
        }
        guard let decoded = try? JSONDecoder().decode(CallHangUpResponse.self, from: response.body) else {
            return .failure(ApiErrorNormalizer.apiError(statusCode: response.statusCode, body: response.body))
        }
        // ⛔ ENVELOPE-CHECKED LIKE EVERY OTHER WRITE. Both fields are required, so
        // `{}` never decodes — but a route falling into its error branch after the
        // headers are written answers a well-formed `{success: false}` with a 200,
        // and reading `ended` off that body would report a carrier leg as ended
        // when the server had just told us it could not do it.
        return ResponseEnvelope.affirm("CallHangUpResponse", decoded.success, decoded)
            .map { (body: CallHangUpResponse) -> HangUpOutcome in
                // ⛔ `ended: false` IS A SUCCESS. See the ⛔ on ``CallHangUpResponse``.
                body.ended ? .ended : .alreadyEnded
            }
    }

    /// ⛔ BY STATUS ALONE, WHICH IS ``InboundCallRepository``'S RULE RATHER THAN
    /// THE DIAL'S. The dial has to read the envelope's SHAPE because its
    /// compliance 403 publishes no `code` and is otherwise identical to the role
    /// 403 on the same route. Nothing on this route is ambiguous that way: 404 and
    /// 409 each mean one thing, and the only 403 it can produce is the role
    /// refusal, which is a genuine `.failure` here because a viewer's phone cannot
    /// have placed the call it is trying to end.
    private static func hangUpRefusal(_ response: RawResponse) -> Result<HangUpOutcome, ApiError> {
        switch response.statusCode {
        case 404:
            .success(.notFound)
        case 409:
            .success(.notDirectCall)
        default:
            .failure(ApiErrorNormalizer.apiError(statusCode: response.statusCode, body: response.body))
        }
    }

    private static func classify(_ response: RawResponse) -> Result<DialOutcome, ApiError> {
        guard (200 ... 299).contains(response.statusCode) else {
            return refusal(response)
        }
        guard let decoded = try? JSONDecoder().decode(DialResponse.self, from: response.body) else {
            return .failure(ApiErrorNormalizer.apiError(statusCode: response.statusCode, body: response.body))
        }
        // ⛔ ENVELOPE-CHECKED, AND HERE THAT IS NOT THE USUAL HYGIENE. Every
        // other route's `success:false` on a 200 means "we could not look"; this
        // one may mean "the call is already ringing and the credential is not
        // usable", which is the one case where reporting a refusal for a call
        // that WAS placed is possible. It is still the right answer — joining a
        // room on an unaffirmed envelope shows a working call over a failure —
        // but the dialer's copy has to say the attempt may have gone out.
        return ResponseEnvelope.affirm("DialResponse", decoded.success, decoded).map(DialOutcome.placed)
    }

    /// ⛔ ORDERED, AND THE ORDER IS THE CLASSIFICATION. The two coded refusals
    /// are matched first because the dormancy body is the DNC body plus a `code`;
    /// testing structure before code would swallow it.
    private static func refusal(_ response: RawResponse) -> Result<DialOutcome, ApiError> {
        let envelope = ApiErrorEnvelope.lenient(response.body)
        // ⚠️ `message`, not `error`: it is the shared normalisation rule (blank
        // means absent, and `code` is never substituted for a sentence), so the
        // three refusals and the pass-through path all word themselves the same
        // way for the same bytes.
        let message = envelope?.message
        if envelope?.code == ApiErrorCode.subscriptionInactive {
            return .success(.subscriptionInactive(message: message))
        }
        if envelope?.code == ApiErrorCode.workspaceDormant {
            return .success(.workspaceDormant(message: message))
        }
        if response.statusCode == 403, envelope?.success == false, envelope?.code == nil {
            return .success(.doNotCall(message: message))
        }
        return .failure(ApiErrorNormalizer.apiError(statusCode: response.statusCode, body: response.body))
    }
}
