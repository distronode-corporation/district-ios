import DistrictData
import Foundation

/// One refusal from the scheduling admin RPC, as a sentence and an offer.
///
/// ⛔ THE SENTENCE COMES FROM `uiCode` AND THE OFFER DOES NOT, AND THAT SPLIT IS
/// THE WHOLE CONTENT OF THIS FILE. `SchedulingAdminFailureCode` already performs
/// the collapse the browser performs (its `codeForFailure` / `codeForStatus`),
/// so the five sentences are copied from
/// `SCHEDULING_ERROR_SENTENCES` and the two clients agree by construction. What
/// the browser has no equivalent of is ``FailureText/Action``: it renders a flash
/// with no button at all, while this app draws a retry from that value. So the
/// action is decided here, once, against the ⛔ on ``FailureText/Action/retry`` —
/// a retry is a CLAIM that a second attempt could change the answer.
///
/// ⚠️ ONLY ``SchedulingAdminFailureCode/unavailable`` EARNS ONE. A refused role, a
/// tenancy that does not exist, a slot somebody else took and a body the route
/// called invalid all come back identically however many times they are asked;
/// the form's own Save button is the retry for the ones a person can act on, and
/// drawing a second one beside it would offer a fix that is not one.
///
/// ⛔ `decoding` IS LIFTED OUT AHEAD OF THE COLLAPSE, DELIBERATELY DIVERGING FROM
/// THE BROWSER. A shape this build cannot parse is not "that did not save" — the
/// write may well have landed — and no retry can fix it. The app already has the
/// honest sentence for it, on the `.decoding` arm of `FailureText.from` for an
/// `ApiError`, and saying two different things about one cause would be worse than
/// diverging from a client that cannot have the problem (the browser reads
/// `body.data` as `unknown` and never decodes it).
extension FailureText {
    /// ⚠️ NAMED FOR THIS SURFACE RATHER THAN OVERLOADING `from(_:)`. The scheduling
    /// READ screens may add their own mapping of the same error type, and two
    /// `static func from(_: SchedulingAdminError)` in one module is a redeclaration
    /// error that surfaces only in the full build.
    static func schedulingWriteC(_ error: SchedulingAdminError) -> FailureText {
        if case .decoding = error {
            return FailureText(
                message: "This version of the app could not read that response. Please update.",
                action: .none
            )
        }
        return FailureText(message: sentence(for: error.uiCode), action: action(for: error.uiCode))
    }

    /// The same mapping, from the `any Error` a `throws` call site actually holds.
    ///
    /// ⚠️ `SchedulingAdminRepository.perform` THROWS `SchedulingAdminError` AND
    /// NOTHING ELSE, but `throws` erases that, so every caller would otherwise
    /// repeat the cast. A value that does not match can only mean a new throw site
    /// upstream, and the honest answer for one nobody has classified is the
    /// generic — never a specific sentence it has not earned.
    static func schedulingWriteC(thrown error: any Error) -> FailureText {
        schedulingWriteC((error as? SchedulingAdminError) ?? .unknown)
    }

    private static func sentence(for code: SchedulingAdminFailureCode) -> String {
        switch code {
        case .unavailable: SchedulingWriteCopyC.unavailable
        case .slotTaken: SchedulingWriteCopyC.slotTaken
        case .forbidden: SchedulingWriteCopyC.forbidden
        case .notReady: SchedulingWriteCopyC.notReady
        case .unknown: SchedulingWriteCopyC.unknown
        }
    }

    private static func action(for code: SchedulingAdminFailureCode) -> FailureText.Action {
        switch code {
        case .unavailable: .retry
        case .slotTaken, .forbidden, .notReady, .unknown: .none
        }
    }
}
