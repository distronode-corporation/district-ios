import DistrictCall
import Foundation

/// What the live-call surface can be asked to do, whichever direction the call
/// came from.
///
/// ⛔ SHARED RATHER THAN COPIED, AND THE THING BEING SHARED IS THE PART THAT
/// WOULD DRIFT. Mute, speaker, hang up and the ended-call dismissal are properties
/// of a live audio call, not of how it started: the two models drive two reducers
/// that emit the SAME ``CallCommand`` for each of them, through the same one
/// ``CallStack``. ⚠️ Each reducer wraps that command in its own type
/// (``IncomingCallCommand/engine(_:)`` and ``SoftphoneCommand/engine(_:)``) because
/// a call also has to tell the OS things the engine knows nothing about; what is
/// shared is the engine half, which is the half these four controls move. A second
/// copy of ``InCallView`` would have been a second place for "mute goes through
/// CallKit so the OS and the screen cannot disagree" to be true, and the second
/// place is the one that stops being true. The Kotlin client reached the same
/// conclusion from the other end: `IncomingCallScreen` hands straight to
/// `InCallScreen` with a `DialerHandlers`.
///
/// ⛔ IT IS THE ACTIONS ONLY, NEVER THE STATE. What each model holds underneath is
/// a different reducer with a different phase vocabulary — an outbound call can be
/// ``SoftphonePhase/ringing`` in a room while an inbound one is already in one —
/// so the view is handed a rendered ``LiveCallDisplay`` instead. Widening this
/// protocol to expose a phase would put the branch back in the view and make the
/// two vocabularies collide there.
///
/// ⚠️ `AnyObject` BECAUSE BOTH CONFORMERS ARE `@Observable` MODELS THE VIEW MUST
/// NOT COPY. A struct witness would be snapshotted into the view and the taps
/// would land on a value nobody owns.
///
/// ⚠️ `Sendable` IS STATED RATHER THAN INFERRED, AND IT COSTS NEITHER CONFORMER A
/// LINE. Both are `@MainActor final class`es and are therefore implicitly
/// `Sendable` already; what the refinement buys is that `any LiveCallControls` is
/// Sendable too, which is what lets a view's `Task { await controls.hangUp() }`
/// capture it. Without it the existential loses the guarantee its conformers have,
/// and the button that ends a call does not compile.
@MainActor
protocol LiveCallControls: AnyObject, Sendable {
    /// ⛔ THROUGH CALLKIT, NEVER STRAIGHT TO THE ENGINE, on both implementations.
    func toggleMute()
    /// ⚠️ NOT through CallKit: there is no system action for the audio route.
    func toggleSpeaker() async
    func hangUp() async
    /// Leave the ended-call summary. ⚠️ Not a hang-up; the call is already over.
    func dismissEndedCall()
}

/// Everything ``InCallView`` draws, rendered once by whichever model owns the
/// call.
///
/// ⛔ A VALUE RATHER THAN THE TWO STATE TYPES, WHICH IS WHAT KEEPS THE COPY
/// DECISIONS OUT OF THE VIEW. `InCallCopy` already owns the wording; this is the
/// one place each reducer's own vocabulary is translated into it, so the two
/// translations sit beside each other and can be read against one another.
struct LiveCallDisplay: Equatable {
    /// Who the call is with. ⚠️ The number as TYPED for an outbound call, and a
    /// LABEL for an inbound one, because the ring push carries identifiers only.
    let title: String

    /// The one line that says what is happening. See ``InCallCopy``.
    let sentence: String

    /// ⚠️ A VALUE EVEN BEFORE MEDIA EXISTS. ``IncomingCallState/media`` is nil
    /// until the room is joined; this substitutes a fresh one, which is safe
    /// ONLY because the ringing phases never reach this view — the incoming
    /// screen draws its own surface until the call is up. See ``IncomingCallView``.
    let media: CallMediaState

    /// Whether the call is over. Drives the summary and the Done button.
    let ended: Bool

    /// ⛔ STATED BECAUSE THIS APP NEVER WRITES THE CALL'S OUTCOME, in either
    /// direction. The row's terminal status and its billed duration come from the
    /// carrier's webhooks, so the log is the record and this screen is not.
    static let logNotice = "This call is in the workspace call log."
}

extension LiveCallDisplay {
    /// One outbound call, as ``DialerModel`` holds it.
    ///
    /// - Parameter endedByOperator: whether the end came from THIS SCREEN'S hang-up
    ///   button. ⛔ Supplied by the model rather than read out of the state, because
    ///   the reducer genuinely does not have it: ``CallEndReason/hungUpLocally``
    ///   covers both the button and the OS's own end-call affordance, and telling an
    ///   operator "you hung up" for the second is a mislabel. See the ⛔
    ///   on ``InCallCopy/word(for:endedByOperator:)``.
    static func softphone(_ state: SoftphoneState, endedByOperator: Bool) -> LiveCallDisplay {
        LiveCallDisplay(
            title: state.number,
            sentence: InCallCopy.sentence(for: state, endedByOperator: endedByOperator),
            media: state.media,
            ended: state.phase.isEnded
        )
    }

    /// One answered inbound call, as ``IncomingCallModel`` holds it.
    ///
    /// - Parameter title: the caller line. ⛔ Supplied by the caller rather than
    ///   derived here, because it is the one part of an inbound call this client
    ///   genuinely does not know: the push payload carries identifiers only, so
    ///   the best available line is a label plus the workspace's name when the
    ///   app happens to have loaded one.
    static func inbound(_ state: IncomingCallState, title: String, endedByOperator: Bool) -> LiveCallDisplay {
        // ⚠️ SUBSTITUTED, NOT FORCED. See the ⚠️ on ``media``.
        let media = state.media ?? CallMediaState()
        return LiveCallDisplay(
            title: title,
            sentence: IncomingCallCopy.sentence(for: state, endedByOperator: endedByOperator),
            media: media,
            ended: state.phase.isEnded
        )
    }
}

extension SoftphonePhase {
    /// ⚠️ A PROPERTY RATHER THAN A `case .ended` AT EACH SITE, because three of
    /// them ask the question and a fourth would be the one that forgot.
    var isEnded: Bool {
        if case .ended = self {
            return true
        }
        return false
    }
}

extension IncomingCallPhase {
    var isEnded: Bool {
        if case .ended = self {
            return true
        }
        return false
    }
}
