import DistrictModel
import DistrictNetwork
import Foundation

/// What happened when the operator pressed Answer.
///
/// ⛔ THREE CASES, AND TWO OF THEM ARE `.success` DESPITE BEING REFUSALS,
/// EXACTLY AS ``DialOutcome``'S THREE ARE. A bare ``ApiError`` leaves a ringing
/// screen with a status and a sentence and nothing to branch on, and here the
/// branch decides between two sentences that mean opposite things about whose
/// fault it was.
///
/// ⛔ ``callerGone`` IS NOT AN ERROR AND MUST NOT BE WORDED AS ONE. The
/// overwhelmingly common way to reach it is that the caller hung up, or the AI
/// finished with them, in the seconds between the phone ringing and a thumb
/// arriving. On a ringing screen that is the difference between "you missed it"
/// and "the app is broken", and the Kotlin `AnswerOutcome.AlreadyEnded` carries
/// the identical note.
///
/// ⛔ THE TWO REFUSAL CASES ARE NAMED FOR ``DistrictCall``'S
/// `IncomingAnswerRejection`, WHICH IS THE TYPE THEY BECOME ONE LAYER UP, AND
/// THEY ARE NOT THAT TYPE BECAUSE THE MODULE GRAPH FORBIDS IT. `DistrictCall`
/// depends on `DistrictModel` alone — deliberately, so a state machine cannot
/// start calling routes — and `DistrictData` does not depend on `DistrictCall`,
/// so this module cannot name that enum without inverting a dependency
/// `Package.swift` argues for at length. The vocabulary is kept identical
/// instead, so the App-side mapping is one exhaustive switch with no decisions
/// left in it. ⚠️ If the two ever diverge, THIS is the copy to change: the
/// controller's is the one the reducer branches on.
///
/// ⚠️ NOT `Equatable`, for the reason ``DialOutcome`` is not: ``CallAnswerResponse``
/// is a gate-pinned wire shape and adding a conformance to it to make an
/// assertion terser would be the tail wagging the dog. Tests pattern-match.
public enum AnswerOutcome: Sendable {
    /// The server minted a credential and it is usable.
    ///
    /// ⛔ `url` AND `token` ARE USED VERBATIM. The room lives on the deployment
    /// that CREATED it — for an inbound call the bridge that answered the
    /// carrier, which for a US or Canadian number is the US hub whatever region
    /// the workspace is in. A client that derived a URL would join a bus that has
    /// never heard of this room and sit in it alone while the caller waited.
    case joinable(CallAnswerResponse)

    /// 404 or 409: the call ended while the phone was ringing.
    ///
    /// ⚠️ THE TWO ARE COLLAPSED HERE, ONCE, RATHER THAN MATCHED ON STATUS IN A
    /// MODEL. 404 is a call this workspace cannot see (deliberately
    /// indistinguishable from another tenant's id) and 409 is a call whose status
    /// is no longer answerable; both are the ordinary race and both need the same
    /// sentence.
    case callerGone

    /// 403: this device may not answer, carrying the server's own sentence.
    ///
    /// ⚠️ REACHABLE BY AN ORDINARY USER RATHER THAN BEING A DEVELOPER ERROR. The
    /// ring is fanned out to every registered device in the workspace without
    /// consulting roles, so a viewer's phone genuinely rings and then meets this.
    /// It cannot be prevented by hiding a button, because the entry point is a
    /// push.
    case refused(message: String?)
}

/// Taking a call this device is ringing on.
///
/// ⛔ SEPARATE FROM ``DialRepository`` EVEN THOUGH BOTH END IN A LiveKit
/// CREDENTIAL, AND THE SPLIT IS THE SERVER'S OWN. `calls/answer` exists as a
/// distinct route because folding a third case into `calls/token` is how a
/// supervisor token was once minted for a primary participant: the voice agent's
/// whisper handler unsubscribed the human's microphone and the AI greeted
/// somebody it could not hear. Keeping the two repositories apart means a screen
/// that answers cannot dial and a screen that dials cannot answer.
///
/// ⛔ AND THE RISK SHAPES ARE OPPOSITE, WHICH IS WORTH STATING BECAUSE THE CODE
/// LOOKS ALIKE. ``DialRepository``'s hazard is that a refusal after a 200
/// describes a call that is ALREADY ringing a stranger and is billed. Nothing is
/// placed or billed here: the call exists and somebody is on it, and the only
/// thing this request decides is whether a human joins. What it DOES do is write
/// the Redis rendezvous the agent's `ring-app` transfer is blocked on — so
/// calling it to "pre-warm" a credential would tell the agent a human took the
/// call while the phone was still ringing in a pocket, and the caller would be
/// handed to nobody. ⛔ It is called from the ANSWER press and from nowhere else.
///
/// ⛔ NO RETRY LIVES HERE AND NONE MAY BE ADDED, at this layer or above it. Not
/// because a second answer is billable but because a 5xx may already have
/// released the agent's transfer, and a second attempt races a call that is being
/// connected. ``ApiClient`` does not retry either and
/// ``TokenRefreshCoordinator`` only supplies tokens, so today the property holds
/// by construction rather than by a flag.
///
/// ⚠️ THE `workspaceId` COMES FROM THE PUSH PAYLOAD, AND ECHOING IT BACK IS NOT
/// A TRUST DECISION THIS CLIENT IS MAKING. The server sent that push to devices
/// belonging to members of that workspace, and the route re-checks membership and
/// the role against the BEARER before it mints anything, so an id lifted out of a
/// payload cannot widen what this account may reach. It is carried rather than
/// derived because the app's SELECTED workspace need not be the one ringing.
public struct InboundCallRepository: Sendable {
    private let client: ApiClient

    public init(client: ApiClient) {
        self.client = client
    }

    /// Answer `callId` in `workspaceId` and receive the credential to join its
    /// room.
    ///
    /// ⛔ `sendUnmapped`, BECAUSE TWO OF THE REFUSAL STATUSES ARE PART OF THE
    /// ANSWER. 404, 409 and 403 each mean something a screen has to say
    /// differently, and ``ApiError`` keeps only a status and a sentence.
    ///
    /// - Returns: `.failure` for everything that is not one of the two known
    ///   refusals — offline, signed out, the rate limit, a 5xx, contract drift —
    ///   already normalised by ``ApiErrorNormalizer``.
    public func answer(callId: String, workspaceId: String) async -> Result<AnswerOutcome, ApiError> {
        let outcome = await client.sendUnmapped(
            DistrictEndpoints.answerCall(callId: callId, workspaceId: workspaceId)
        )
        return outcome.flatMap(Self.classify)
    }

    private static func classify(_ response: RawResponse) -> Result<AnswerOutcome, ApiError> {
        guard (200 ... 299).contains(response.statusCode) else {
            return refusal(response)
        }
        guard let decoded = try? JSONDecoder().decode(CallAnswerResponse.self, from: response.body) else {
            return .failure(ApiErrorNormalizer.apiError(statusCode: response.statusCode, body: response.body))
        }
        // ⛔ ENVELOPE-CHECKED. A required non-optional field rejects `{}`; it does
        // not reject a well-formed body that says `success: false`, which is what
        // this route's own catch branch produces on a 200 once the headers are
        // written. Joining a room on an unaffirmed envelope would show a
        // connected call over a server refusal.
        return ResponseEnvelope.affirm("CallAnswerResponse", decoded.success, decoded)
            .flatMap(Self.joinable)
    }

    /// ⛔ CLASSIFIED BY STATUS ALONE, WHICH IS THE OPPOSITE OF THE DIAL'S RULE
    /// AND IS CORRECT FOR THE OPPOSITE REASON. `calls/dial` has to read the
    /// envelope's SHAPE because its compliance 403 publishes no `code` and is
    /// otherwise indistinguishable from the role 403 on the same route. Here the
    /// only 403 the route can produce IS the role refusal, so a shape test would
    /// buy nothing and would misfire the day the route grew a second one.
    private static func refusal(_ response: RawResponse) -> Result<AnswerOutcome, ApiError> {
        switch response.statusCode {
        case 404, 409:
            .success(.callerGone)
        case 403:
            // ⚠️ `message`, not `error`: the shared normalisation rule, so a
            // blank sentence counts as absent and `code` is never substituted
            // for one. The screen owns the fallback.
            .success(.refused(message: ApiErrorEnvelope.lenient(response.body)?.message))
        default:
            .failure(ApiErrorNormalizer.apiError(statusCode: response.statusCode, body: response.body))
        }
    }

    /// ⛔ A BLANK CREDENTIAL IS CONTRACT DRIFT, NOT A CALL. Every field of
    /// ``CallAnswerResponse`` is required, so `{}` never reaches here — but `""`
    /// decodes perfectly, and the failure would then surface at `engine.connect`
    /// as a media-plane error, on a screen already showing a connected call, for
    /// what was really a server refusal. The Kotlin client makes the identical
    /// check for a stronger reason: its DTO defaults all four fields.
    private static func joinable(_ response: CallAnswerResponse) -> Result<AnswerOutcome, ApiError> {
        guard !isBlank(response.url), !isBlank(response.token) else {
            return .failure(.decoding("CallAnswerResponse carried no join credential"))
        }
        return .success(.joinable(response))
    }

    private static func isBlank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
