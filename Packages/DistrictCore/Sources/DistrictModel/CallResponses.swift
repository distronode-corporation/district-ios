import Foundation

/// `GET /api/district/calls/{callId}/transcript?workspaceId=`
///
/// ⚠️ FETCHED LAZILY AND SEPARATELY, BY DESIGN. The contact timeline used to
/// embed transcripts and they dominated its payload, so it stopped — every
/// surface that wants one now asks for it when the user actually opens it. The
/// calls feed does still carry a copy on each row, but the detail screen should
/// prefer this route: the feed's copy is whatever was loaded with the page, and
/// a transcript can be appended to after a call ends.
///
/// ⛔ AN ABSENT TRANSCRIPT IS THE EMPTY STRING, NOT NULL, AND THAT IS WHY
/// ``transcript`` IS NON-OPTIONAL. The handler writes `call.transcript || ""`,
/// so `isEmpty` is the "nothing to show" test and a nil check would never fire.
/// A missing CALL is a different thing entirely and arrives as a 404
/// `{error: "Call not found"}`.
public struct CallTranscriptResponse: Codable, Sendable {
    public let success: Bool
    /// ⛔ `""` rather than nil when there is nothing. See the type note.
    public let transcript: String

    /// True when there is something worth rendering. See the note about `""`
    /// versus null.
    public var hasTranscript: Bool {
        !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// `POST /api/district/calls/dial` — the outbound softphone's one server call.
///
/// ⛔ THIS IS A CREDENTIAL PAIR, NOT A DATA SHAPE, AND THAT CHANGES WHAT A DECODE
/// FAILURE COSTS. Everywhere else in this client a renamed field means a screen
/// renders wrong and the user tries again. Here the server has ALREADY written
/// the `Call` row and ALREADY told the carrier to dial by the time it mints this
/// body — so a field this app cannot read is a telephone that rings with nobody
/// on the other end, billed, with the operator looking at an error. There is no
/// second round trip and nothing to retry onto: retrying places a SECOND call.
///
/// ⛔ ``url`` IS THE TRUNK'S DEPLOYMENT AND MUST BE USED VERBATIM — and it is a
/// different answer from the one ``RoomTokenResponse/url`` gives for a standalone
/// room. A `direct_` room is created by the SIP dial on whichever bus the
/// server's SIP client points at, which is not necessarily the deployment that
/// serves the workspace. A client that derived this from its own region would
/// join a bus that has never heard of the room, and the by-room resolver cannot
/// rescue it either: the room does not exist until the dial lands.
///
/// ⛔ ``roomName`` IS `direct_…`, WHICH IS A ROUTING DECISION RATHER THAN A
/// LABEL. The voice agent auto-dispatches into every room it does not refuse,
/// and its `request_fnc` refuses this prefix BY NAME — a `call_` room here would
/// put the AI on a human's own call, talking over them. This client never
/// constructs a room name; ``DialRoom/directPrefix`` exists to ASSERT the
/// server's answer, never to build one.
///
/// ⛔ ``callId`` IS THE `Call.callSid`, AND IT IS THE ONLY THING THAT CAN END THE
/// CARRIER LEG. The route is `POST /api/district/calls/{callId}/hangup` (see
/// ``CallHangUpResponse``); without it a call the operator ended locally keeps
/// ringing at the carrier and keeps being billed, because `Room.disconnect()`
/// drops THIS device from the room and says nothing to the SIP leg. Every local
/// ending must spend this id. The row is still written before the dial with `status: "in-progress"`,
/// `direction: "outbound"`, and its terminal status still belongs to the
/// SIP/webhook pipeline.
///
/// ⚠️ The token's TTL is 70 minutes — long, deliberately, because the operator is
/// a PARTY to the call rather than a supervisor dropping in. It authorises the
/// JOIN; an established connection is not re-checked against it.
public struct DialResponse: Codable, Sendable {
    public let success: Bool
    /// ⚠️ The `Call.callSid` of a row that already exists. See the type note.
    public let callId: String
    /// ⛔ Always `direct_…`. See the type note.
    public let roomName: String
    /// The operator's own LiveKit token, ~70 minutes. Used verbatim.
    public let token: String
    /// ⛔ The TRUNK deployment's websocket URL, not the workspace's. Used
    /// verbatim.
    public let url: String
}

/// `POST /api/district/calls/{callId}/answer` — the inbound half of the same
/// credential exchange, pinned by `district-call-answer.json`.
///
/// ⛔ THE FOUR KEYS ARE NOT ``DialResponse``'S FOUR, AND THE ONE THAT IS MISSING
/// IS THE ONE A CALLER WOULD REACH FOR. There is no `callId` here: the client
/// already knows it, because it sent it in the path, and the server has nothing
/// to add. A shared DTO would therefore have to make `callId` Optional and every
/// dial-side reader would lose a guarantee it has today.
///
/// ⛔ ``url`` IS THE **INBOUND BRIDGE'S** DEPLOYMENT, WHICH IS A THIRD ANSWER
/// AGAIN. `RoomTokenResponse/url` resolves from the workspace and
/// ``DialResponse/url`` from the TRUNK; this one is the deployment that already
/// holds the ringing room, which for a US or Canadian number is the US hub
/// regardless of where the workspace lives. A client that derived it from its
/// own region would join a bus that has never heard of this room and sit there
/// alone while the caller waited. Used verbatim.
///
/// ⛔ ``roomName`` IS `call_…`, NOT `direct_…`, AND THERE MUST BE NO PREFIX
/// ASSERTION HERE. `DialRepository` checks for `direct_` because that prefix is
/// what keeps the voice agent off a room this app created; an ANSWERED call is a
/// `call_` room the agent is already in and is supposed to be in — the handoff
/// metadata inside the token is what tells it to step back. A prefix check here
/// would refuse every legitimate answer. The Kotlin `InboundCallRepository`
/// states the same thing.
///
/// ⚠️ ``roomName`` IS MODELLED AND NOTHING JOINS BY IT. It is here because the
/// fixture carries it and the strict gate compares key sets; the join is
/// ``url`` plus ``token``.
///
/// ⚠️ EVERY FIELD IS REQUIRED, WHICH IS A DIVERGENCE FROM KOTLIN AND THE REASON
/// THIS CLIENT NEEDS ONE FEWER HAND-WRITTEN GUARD. `CallAnswerResponse.kt`
/// defaults all four, so a `{}` body decodes there into a well-formed response
/// holding an empty token; here it fails to decode. The BLANK case survives on
/// both clients and is still checked by hand — see ``DistrictData``'s
/// `InboundCallRepository`.
public struct CallAnswerResponse: Codable, Sendable {
    public let success: Bool
    /// ⛔ The inbound bridge's websocket URL. Used verbatim. See the type note.
    public let url: String
    /// The operator's own LiveKit token. Used verbatim.
    public let token: String
    /// ⛔ Always `call_…`, and never prefix-asserted. See the type note.
    public let roomName: String
}

/// `POST /api/district/calls/{callId}/hangup` — telling the SERVER to end a
/// direct softphone call's carrier leg.
///
/// ⛔ TWO KEYS, AND ``ended`` IS NOT A SUCCESS FLAG. ``success`` says the request
/// was understood; ``ended`` says whether THIS request is what tore the room
/// down. `false` means the call was already gone by the time the server looked,
/// which is the ordinary answer whenever the far end hung up first or a previous
/// attempt won the race — it is a normal outcome, not a refusal, and a client
/// that reported it as one would tell an operator their hang-up failed on the
/// most common path there is.
///
/// ⛔ THE ROUTE IS IDEMPOTENT AND THAT IS LOAD BEARING RATHER THAN CONVENIENT.
/// The whole point of the endpoint is that it is spent on every local ending
/// including the ones that arrive after the call is over, so a second send has to
/// be free. It is the exact opposite property from ``DialResponse``'s route,
/// which may never be re-sent because a re-send places a second call — the two
/// live one path segment apart and the rules could not be further apart, which is
/// why this is written on the type rather than left to the repository.
///
/// ⚠️ NO FIXTURE, ON THE SAME FOOTING AS `messages/search` AND `createContact`.
/// The shared contract corpus mirrors the Android client, and that client has
/// no hang-up call, so nothing on disk pins this
/// shape and ``ContractManifest/expectedFixtureCount`` must NOT move for it. What
/// pins it is the route's own source and `DialRepositoryTests`.
public struct CallHangUpResponse: Codable, Sendable {
    /// Present and `true` on the 200. Envelope-checked like every other write.
    public let success: Bool

    /// Whether THIS request tore the room down. ⛔ `false` is a success. See the
    /// type note.
    public let ended: Bool
}

/// Room-name facts about the dial path.
public enum DialRoom {
    /// The prefix every direct-dial room carries.
    ///
    /// ⛔ FOR ASSERTION, NEVER FOR CONSTRUCTION. Nothing in this client mints a
    /// `direct_` name, because the name embeds a server-generated call id. The
    /// constant exists so a test can prove the server's answer still carries the
    /// prefix that keeps the AI off the line — the only thing standing between a
    /// human's call and an agent that joins every room it is not told to skip.
    public static let directPrefix = "direct_"
}

/// The 402 body from any route behind `requireActiveSubscription` — pinned by
/// `district-dial-subscription.json`.
///
/// ⛔ IT IS ITS OWN TYPE RATHER THAN ``ApiErrorEnvelope`` BECAUSE OF ``status``,
/// the same call ``WorkspaceListDegradedError`` makes about `degradedRegions`.
/// Decoding it as the generic envelope would drop that key silently —
/// `JSONDecoder` cannot reject unknown keys — and the strict gate would then
/// fail on the missing key at re-encode. ⚠️ THIS DIVERGES FROM KOTLIN, WHICH
/// FOLDS `status` ONTO ITS SHARED `ApiErrorEnvelope`. Both are defensible; the
/// Swift envelope is gate-pinned against four fixtures that have no `status`,
/// and keeping it at three keys is what makes those four assertions mean
/// something.
///
/// ⛔ BRANCH ON ``code``, NEVER ON ``status`` AND NEVER ON ``error``. Which
/// Stripe states count as delinquent is the SERVER's decision — the blocked-state
/// set already includes `past_due` as a deliberate strictness choice that could
/// be reversed — so a client that decided for itself would disagree with the
/// guard the moment that set changed, and would disagree silently. ``error`` is
/// product copy and gets rewritten. ``code`` is the contract.
///
/// ⚠️ EMITTED BY THE SHARED GUARD, so it can appear on any billable route rather
/// than only the dial. What the branch buys is a message naming the remedy — the
/// plan lapsed and billing has to be fixed on the web — rather than the generic
/// "that did not work" a bare 402 would produce. ⛔ And it must not become a
/// purchase CTA or a link-out to Stripe: App Store Review Guideline 3.1.3(b).
public struct SubscriptionInactiveError: Codable, Sendable {
    /// Present and `false`. This route builds its own envelope.
    public let success: Bool
    /// Server-authored copy. ⛔ Branch on ``code``, never on this.
    public let error: String
    /// `subscription_inactive`. See ``ApiErrorCode/subscriptionInactive``.
    public let code: String
    /// The workspace's Stripe subscription status, e.g. `past_due`.
    ///
    /// ⛔ DIAGNOSTIC ONLY, AND NOTHING MAY BRANCH ON IT. Modelled because a
    /// committed fixture proves the key exists, not because anything reads it.
    public let status: String
}
