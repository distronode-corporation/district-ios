import DistrictData
import DistrictModel
import Foundation

/// What to tell the operator about a refused scheduling-admin write.
///
/// ⛔ THE SENTENCES ARE THE BROWSER'S, COPIED VERBATIM FROM ITS
/// `SCHEDULING_ERROR_SENTENCES`, AND THAT IS THE WHOLE POINT OF THE FILE.
/// ``SchedulingAdminFailureCode`` carries the DECISION and refuses to carry copy
/// (DistrictCore is locale-free); the web owns the five sentences; a person shown
/// two different explanations of one refusal depending on which device they
/// picked it up on reports a bug against whichever they saw second.
///
/// ⛔ SEPARATE FROM ``FailureText/from(_:)`` BECAUSE THE INPUT IS A DIFFERENT
/// ERROR TYPE, NOT BECAUSE THE RULE DIFFERS. ``FailureText`` maps ``ApiError``,
/// whose 4xx carries a server-authored sentence worth showing; this route
/// deliberately answers a CODE and never the fork's own text, because that text is
/// remote and quotes back whatever was sent. The OUTPUT is the same
/// ``FailureText``, so a write failure renders through the same strip as every
/// other failure on the app.
///
/// ⚠️ THE ACTION IS OURS AND THE SENTENCE IS THEIRS, WHICH IS THE ONE PLACE THE
/// TWO CLIENTS DIVERGE ON PURPOSE. The web has no notion of an offered recovery;
/// ``FailureText/Action/retry`` is a CLAIM here (see its ⛔), so it is offered only
/// where a second attempt could genuinely change the answer. `unknown`'s sentence
/// ends "Try again." and still answers ``FailureText/Action/none`` for the two
/// cases a retry cannot fix — see ``action(for:)``.
enum SchedulingWriteFailureText {
    /// The five sentences, by code. Verbatim from the web.
    static func sentence(for code: SchedulingAdminFailureCode) -> String {
        switch code {
        case .unavailable: "The booking system did not answer. Try again in a minute."
        case .slotTaken: "That time was just taken. Pick another."
        case .forbidden: "You can view this but not change it."
        case .notReady: "Scheduling is not set up for this workspace yet."
        case .unknown: "That did not save. Try again."
        }
    }

    /// ⛔ SWITCHED ON THE ERROR, NOT ON ITS CODE, BECAUSE THREE ERRORS SHARE
    /// ``SchedulingAdminFailureCode/unknown`` AND ONLY ONE OF THEM IS RETRYABLE.
    /// ``SchedulingAdminError/invalidParams(_:)`` is a 400 against a body this
    /// client composed: resending the identical body is the identical refusal.
    /// ``SchedulingAdminError/decoding(_:)`` is a shape no retry can change. The
    /// bare ``SchedulingAdminError/unknown`` is a refusal we could not classify at
    /// all, so the honest offer is the one the sentence already makes.
    static func action(for error: SchedulingAdminError) -> FailureText.Action {
        switch error {
        case .failure(.unavailable), .unavailable, .transport, .unknown: .retry
        case .failure, .forbidden, .notReady, .invalidParams, .decoding: .none
        }
    }

    /// The pair a screen renders.
    static func from(_ error: SchedulingAdminError) -> FailureText {
        FailureText(message: sentence(for: error.uiCode), action: action(for: error))
    }

    /// ⚠️ THE FIELD NAMES OF A **400**, FOR A LOG LINE AND NEVER FOR A SCREEN.
    /// ``SchedulingAdminError/invalidParams(_:)`` carries identifiers the route
    /// flattened out of zod issues precisely so no input is quoted back; rendering
    /// them would put `msg_confirmation` in front of somebody looking at a field
    /// labelled "Confirmation email". Empty means "we could not say which", which
    /// is not the same as "nothing was wrong".
    static func refusedFields(_ error: SchedulingAdminError) -> [String] {
        guard case let .invalidParams(fields) = error else { return [] }
        return fields
    }
}

/// One write's state, as a sheet renders it.
///
/// ⛔ FOUR CASES AND NO `savedButStale`, WHICH IS THE DIFFERENCE FROM
/// ``SettingsSaveState`` AND IS A PROPERTY OF THE ROUTE RATHER THAN A
/// SIMPLIFICATION. Every workspace-settings write answers `{"success": true}` and
/// has to be re-read; every scheduling-admin write here ECHOES the row it wrote
/// (`eventTypes.patch` answers the whole updated event type, `hosts.put` answers
/// the new list, the deletes answer ``SchedulingNoContent``), so there is no
/// window in which the write landed and the client does not know what it wrote.
///
/// ⚠️ ``failed(_:)`` KEEPS THE OPERATOR'S EDITS, same rule as the settings
/// surface: a refused save that also discarded what somebody typed is two losses
/// for one fault.
enum SchedulingWriteState {
    case idle
    case saving
    case saved
    case failed(FailureText)

    var isSaving: Bool {
        if case .saving = self {
            return true
        }
        return false
    }

    var failure: FailureText? {
        guard case let .failed(text) = self else { return nil }
        return text
    }

    /// ⚠️ HAND-WRITTEN RATHER THAN SYNTHESISED, AND NOT FOR TASTE: synthesis would
    /// need ``FailureText`` to be `Equatable`, and conforming somebody else's type
    /// from here is a conformance the next screen to want one would declare a
    /// second time — a duplicate-conformance error in a file nobody edited. The
    /// two fields are the whole of what a test asks about.
    func describes(_ other: SchedulingWriteState) -> Bool {
        switch (self, other) {
        case (.idle, .idle), (.saving, .saving), (.saved, .saved):
            true
        case let (.failed(lhs), .failed(rhs)):
            lhs.message == rhs.message && lhs.action == rhs.action
        default:
            false
        }
    }
}
