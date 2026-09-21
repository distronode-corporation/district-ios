import DistrictModel
import DistrictNetwork
import Foundation

/// The five things that can go wrong on the scheduling admin surface, as a
/// screen cares about them.
///
/// ⛔ NOT THE SERVER'S VOCABULARY, AND COLLAPSING TO IT IS THE POINT. The route
/// speaks `unavailable` / `conflict` / `not_found` / `rejected` plus a handful of
/// HTTP statuses; several of those want the same sentence and the same recovery,
/// and one status (403) wants a different sentence from every `failure` kind.
/// `admin-fetch.ts` performs exactly this collapse for the browser, and the two
/// clients have to agree — a person shown two different explanations of one
/// refusal depending on which device they picked it up on will report a bug
/// against whichever one they saw second.
///
/// ⛔ NO SENTENCES HERE. DistrictCore is Linux-testable and locale-free; the App
/// owns the copy, the same way ``ApiError`` refuses to invent a message. What this
/// type carries is the DECISION — which of five recoveries applies — and nothing
/// a translator would need to touch.
///
/// ⚠️ ONLY THREE OF THE FIVE ARE REACHABLE FROM A `failure` STRING
/// (``unavailable``, ``slotTaken``, ``unknown``); ``forbidden`` and ``notReady``
/// come only from a status. That is not an oversight in the mapping: a 200
/// carrying `{ok:false}` means our route was satisfied and the SCHEDULER refused,
/// and neither "you may not" nor "there is no tenancy" can be decided that far
/// down. See ``SchedulingAdminError``.
public enum SchedulingAdminFailureCode: String, Sendable, CaseIterable {
    /// The scheduler did not answer, is rate-limiting us, or failed. Retryable.
    case unavailable
    /// The booking slot was taken between rendering it and asking for it. The
    /// only code whose recovery is "choose something else" rather than "try
    /// again".
    case slotTaken
    /// The role gate refused: this member may read the surface and not change it.
    case forbidden
    /// The workspace has no scheduling tenancy. Not a fault and not retryable —
    /// somebody has to press Enable.
    case notReady
    /// Anything the two vocabularies do not name. ⚠️ The honest generic, and it
    /// must stay reachable: an unrecognised code rendered as a specific one is
    /// how a client starts lying about a server it no longer understands.
    case unknown

    /// A `{ok:false, failure}` body's `failure` string, mapped to a code.
    ///
    /// ⚠️ `instance_unavailable` SITS BESIDE `unavailable` BECAUSE TWO
    /// VOCABULARIES REACH THIS FIELD: the platform client's four kinds
    /// (`unavailable` / `conflict` / `not_found` / `rejected`) and the calendar
    /// failure modes (`instance_unavailable`, `slot_taken`). Naming both
    /// spellings of "our scheduler did not answer" costs one line and stops the
    /// more specific one falling through to ``unknown``. Copied arm for arm from
    /// `admin-fetch.ts`'s `codeForFailure`.
    static func forFailure(_ failure: String) -> Self {
        if failure == "unavailable" || failure == "instance_unavailable" {
            return .unavailable
        }
        if failure == "slot_taken" {
            return .slotTaken
        }
        return .unknown
    }
}

/// Everything ``SchedulingAdminRepository/perform(_:workspaceId:params:as:)`` can
/// throw.
///
/// ⛔ ``failure(_:)`` IS A **200** AND THE OTHERS ARE NOT, WHICH IS WHY IT IS A
/// SEPARATE CASE RATHER THAN FOLDED INTO THE CODE IT CARRIES. `failureResponse`
/// answers `{ok:false, failure, status}` at HTTP 200 on purpose: the request
/// reached Distronode, was authorised, cleared the op's role bar, validated, and
/// the SCHEDULER is what refused. Every other case here is our own route
/// declining before it ever spent a request. The distinction is invisible in the
/// sentence a user reads and it is the whole of the answer to "whose outage is
/// this", so it survives to the error type and is collapsed only at ``uiCode``.
///
/// ⚠️ THERE IS NO `.http(status:)` ESCAPE HATCH, DELIBERATELY. A caller that
/// switched on a raw status would re-implement this mapping badly and in several
/// places; the status is preserved where it matters — as the code — and thrown
/// away where it does not.
public enum SchedulingAdminError: Error, Equatable, Sendable {
    /// HTTP 200, `{ok:false, failure, status}`. The scheduler refused.
    case failure(SchedulingAdminFailureCode)
    /// HTTP 400 `invalid_params`, carrying FIELD NAMES only.
    ///
    /// ⛔ NAMES, NEVER MESSAGES, AND THE SERVER IS WHERE THAT IS ENFORCED. A zod
    /// issue's message quotes the offending input straight back out of the API,
    /// so `issueFields` flattens to paths and drops the text. Anything rendering
    /// these must treat them as identifiers to look up, not as prose to show.
    ///
    /// ⚠️ MAY BE EMPTY. The route caps the set at 20 issues and a body that
    /// carried none is still a 400; an empty array means "we could not say
    /// which", not "nothing was wrong".
    case invalidParams([String])
    /// HTTP 403 (or 401): the op's `minRole` bar, or no credential at all.
    case forbidden
    /// HTTP 409 `scheduling_not_ready`: the workspace has no tenancy.
    case notReady
    /// HTTP 413, 429 or 5xx. Retryable, eventually.
    case unavailable
    /// A refusal this client does not recognise, including the `unknown_op` a
    /// debug build traps on. See ``SchedulingAdminRepository``.
    case unknown
    /// The request never produced a response (DNS, TLS, timeout, offline).
    /// ⚠️ Carries the cause rather than swallowing it, like ``ApiError/transport(_:)``.
    case transport(String)
    /// A 2xx whose `data` did not match the type the caller named.
    case decoding(String)

    /// The one of five recoveries a screen should offer.
    ///
    /// ⚠️ ``transport(_:)`` LANDS ON ``SchedulingAdminFailureCode/unavailable``,
    /// which is what the browser does too: "the request never left" and "the far
    /// end is down" are indistinguishable from here and want the same sentence.
    /// ``decoding(_:)`` lands on ``SchedulingAdminFailureCode/unknown`` because a
    /// retry cannot fix a shape.
    public var uiCode: SchedulingAdminFailureCode {
        switch self {
        case let .failure(code):
            code
        case .forbidden:
            .forbidden
        case .notReady:
            .notReady
        case .unavailable, .transport:
            .unavailable
        case .invalidParams, .unknown, .decoding:
            .unknown
        }
    }
}
