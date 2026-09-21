import DistrictData
import DistrictModel
import Foundation

/// The request list's own load state.
///
/// ⛔ THREE CASES, AND THE THIRD IS THE WHOLE POINT. A single Optional cannot tell
/// "still loading" from "finished and failed", and collapsing those two renders an
/// unreachable desk as the empty-queue copy: a customer with three open tickets is
/// told they have none, stops chasing, and nobody here ever sees the request.
/// ``SupportListState/ready(_:)`` with an empty array is a REAL answer and
/// must look nothing like ``SupportListState/failed(_:)``.
enum SupportListState {
    case loading
    /// ⛔ An empty array is a workspace that has never raised a request, which is
    /// where every workspace starts.
    case ready([SupportRequestSummary])
    case failed(FailureText)
}

/// One thread's load state.
enum SupportThreadState {
    case loading
    case ready(SupportRequestDetail)
    case failed(FailureText)
}

/// What a support write left behind.
///
/// ⛔ ``done(_:)`` IS NOT "IT WORKED" — IT IS "HERE IS THE SENTENCE FOR WHAT
/// HAPPENED". Raising a request has three successful outcomes with three different
/// sentences (filed, already open, being opened) and only one of them is the
/// ordinary one. Modelling this as a boolean would have forced the two unusual
/// successes to borrow the ordinary one's copy or be reported as failures, and
/// reporting `deduplicated` as a failure is what invites a third attempt into a
/// human's queue.
///
/// ⛔ ``failed(_:_:)`` CARRIES A ``SupportResubmit`` BECAUSE A FAILED WRITE ON THIS
/// SURFACE MAY ALREADY HAVE POSTED A PUBLIC COMMENT IN A CUSTOMER'S OWN THREAD. The
/// rule lives on that type; what lives here is the consequence, which is that the
/// control's armed state is read off the failure rather than reset to idle.
enum SupportWriteState {
    case idle
    case sending
    /// A notice to show. See the ⛔ on the type: not necessarily a congratulation.
    case done(String)
    case failed(FailureText, SupportResubmit)
}

extension SupportWriteState {
    var isSending: Bool {
        if case .sending = self {
            return true
        }
        return false
    }

    /// ⛔ WHETHER THE CONTROL MAY BE PRESSED AT ALL. `.sending` answers false for the
    /// ordinary reason (one tap is one write); a `.failed` answers what its own
    /// ``SupportResubmit`` says, which is the guard that stops a lost response
    /// becoming a duplicate reply.
    var isArmed: Bool {
        switch self {
        case .idle, .done:
            true
        case .sending:
            false
        case let .failed(_, resubmit):
            resubmit.isAllowed
        }
    }

    /// The one state where the control is gone and is not coming back.
    ///
    /// ⚠️ NOT THE NEGATION OF ``isArmed``: a write in flight is also unarmed and is
    /// the opposite situation. This is what puts ``SupportCopy/writeUnrepeatable``
    /// under the failure.
    var refusedRepeat: Bool {
        switch self {
        case .idle, .sending, .done:
            false
        case let .failed(_, resubmit):
            !resubmit.isAllowed
        }
    }

    /// The sentence to show, whatever kind of outcome this is.
    var notice: String? {
        switch self {
        case .idle, .sending:
            nil
        case let .done(message):
            message
        case let .failed(failure, _):
            failure.message
        }
    }

    /// ⚠️ Drawn in the destructive colour only for a real failure. A `deduplicated`
    /// or `pending` notice is a success and must not be red.
    var isFailure: Bool {
        if case .failed = self {
            return true
        }
        return false
    }
}

/// What to say about a filing outcome.
///
/// ⛔ A FREE FUNCTION ON THE COPY RATHER THAN A PROPERTY ON THE DTO, because the
/// three sentences are product copy and `DistrictModel` owns no copy. All three are
/// successes; see ``SupportWriteState``.
enum SupportFilingCopy {
    static func notice(for filing: SupportRequestFiling) -> String {
        switch filing {
        case .filed: SupportCopy.filed
        case .deduplicated: SupportCopy.deduplicated
        case .pending: SupportCopy.pending
        }
    }
}
