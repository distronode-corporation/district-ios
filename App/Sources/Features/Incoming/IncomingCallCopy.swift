import CallKit
import DistrictCall
import Foundation

/// Every sentence the ringing surface says, and the CallKit reasons behind it.
///
/// ⚠️ ITS OWN FILE FOR THE REASON ``DialerCopy`` IS ONE: `swiftlint --strict`
/// promotes the 500-line `file_length` warning to an error, and the model does not
/// have room for this block.
///
/// ⛔ THE PUSH CARRIES IDENTIFIERS ONLY. No number, no name, no token, because a
/// push is readable by the operating system and by any notification-service
/// extension, and the answer route returns a join credential rather than a caller.
///
/// ⚠️ THE APP ASKS AFTERWARDS INSTEAD. ``IncomingCallIdentity`` resolves the caller
/// over the authenticated API once the call has been reported, so the line names the
/// caller when the workspace's own records answered, and names the workspace being
/// called until then. That placeholder is the honest answer for the first second of
/// every ring, for a handset that has not been unlocked since it booted, and for a
/// number nobody has ever saved.
enum IncomingCallCopy {
    /// ⚠️ THE WORKSPACE NAME IS APPENDED ONLY WHEN THE APP HAPPENS TO HOLD ONE. A
    /// cold launch from a VoIP push has not loaded the workspace list yet, and a
    /// push can arrive for a workspace that is not the selected one, so the name is
    /// a bonus rather than a guarantee.
    ///
    /// ⚠️ THE WORKSPACE STAYS ON THE LINE EVEN ONCE THE CALLER IS KNOWN. An
    /// operator holding two businesses needs to know WHICH of their lines rang
    /// before they pick up, and a caller's name does not tell them that.
    ///
    /// - Parameter caller: ``IncomingCallIdentity/displayLine``, or nil while the
    ///   lookup is out or after it resolved nothing. ⚠️ Blank is treated as nil:
    ///   the identity type already refuses to produce one, and a lead of `""` would
    ///   render a line that opens with the separator.
    static func callerLine(caller: String?, workspaceName: String?) -> String {
        let known = caller?.trimmingCharacters(in: .whitespaces) ?? ""
        let lead = known.isEmpty ? "Incoming call" : known
        guard let workspaceName, !workspaceName.trimmingCharacters(in: .whitespaces).isEmpty else {
            return lead
        }
        return "\(lead) · \(workspaceName)"
    }

    /// ⛔ THE MESSAGE WINS OVER THE PHASE ON AN ENDED CALL, which is the same call
    /// the Kotlin screen makes: "the caller hung up" is more useful than the word
    /// "Ended", and the two are never both worth showing.
    ///
    /// - Parameter endedByOperator: whether the end came from THIS SCREEN'S hang-up
    ///   button. ⛔ Supplied by the model, never derived from the state: the reducer
    ///   feeds `.hangUpPressed` from ``IncomingCallModel/hangUp()`` AND from its
    ///   CallKit handler, so ``CallEndReason/hungUpLocally`` means "ended on this
    ///   device" and nothing narrower — the same fact the outbound screen carries.
    static func sentence(for state: IncomingCallState, endedByOperator: Bool) -> String {
        switch state.phase {
        case .idle, .ringing:
            "Ringing…"
        // ⛔ ITS OWN SENTENCE RATHER THAN A SPINNER OVER "Ringing…". The answer
        // round trip plus a room join is a real gap to fill, and the buttons have
        // gone by now; a screen still saying "Ringing…" reads as frozen.
        case .answering:
            "Answering…"
        case .inCall:
            "Connected · \(InCallCopy.duration(state.media?.elapsedSeconds ?? 0))"
        case let .ended(reason):
            InCallCopy.endedSentence(
                reason: reason,
                endedByOperator: endedByOperator,
                seconds: state.media?.elapsedSeconds ?? 0,
                // ⛔ `media != nil` IS THE ANSWERED TEST, AND IT IS THE SAME FACT
                // ``IncomingCallState/media`` DOCUMENTS: it is nil until the room
                // is joined. A call that ended while ringing must not read
                // "Lasted 0:00", which says the opposite of "nobody picked up".
                answered: state.media != nil
            )
        }
    }

    /// The notice under the Answer button.
    ///
    /// ⚠️ SAID BEFORE THE SYSTEM ASKS, like the dialer's, so the microphone prompt has a visible
    /// reason. The app asks at a foreground Answer (``IncomingCallModel/prepareMicrophoneForAnswer()``),
    /// and a request with no explanation is the one people deny permanently.
    static let answerNotice = "Answering turns on your microphone."

    /// Why the OS should record this call as having ended.
    ///
    /// ⛔ THIS IS THE **REPORT**, SO EVERY REASON HERE IS ONE THE USER DID NOT
    /// PRESS. A decline or a hang-up inside this app goes out as a
    /// `CXEndCallAction` through ``CallKitBridge/requestEndCall(uuid:)`` and never
    /// reaches this function — see ``IncomingCallModel``'s `endRequestedLocally`.
    /// Reporting an ending the user asked for would leave the OS's own end-call
    /// affordance armed against a call that is gone.
    ///
    /// ⚠️ ``CXCallEndedReason/unanswered`` IS WHAT PUTS A MISSED CALL IN THE
    /// SYSTEM'S RECENTS LIST, which is where a person looks for one. It is the
    /// right answer for a ring nobody reached in time and for a ring that arrived
    /// on a signed-out handset, and it is the WRONG answer for a caller who hung
    /// up (they were answered by nobody, but the call did happen).
    static func endedReason(for phase: IncomingCallPhase) -> CXCallEndedReason {
        guard case let .ended(reason) = phase else { return .failed }
        switch reason {
        case .ringTimedOut:
            return .unanswered
        case .callerCancelled, .remoteHungUp, .remoteEnded:
            return .remoteEnded
        case .failed, .answerRefused:
            return .failed
        // ⚠️ UNREACHABLE, AND ANSWERED ANYWAY RATHER THAN DEFAULTED. Both are
        // local endings, so the OS was told through a `CXEndCallAction` before the
        // reducer ever produced them. Writing them out is what makes a NEW
        // ``CallEndReason`` a compile error here instead of a silent `.failed`.
        case .declined, .hungUpLocally:
            return .remoteEnded
        }
    }
}
