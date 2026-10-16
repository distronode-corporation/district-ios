import CallKit
import DistrictCall
import DistrictModel
import Foundation

/// What this iPhone does with a ``RingCancel``: the `call_ring_cancelled` background push.
///
/// ⛔ THE PARSE IS DistrictCore's (`RingCancel.parse`, 7.0.1), SHARED WITH THE MAC. What lives
/// here is the half that needs CallKit, which the Linux tier cannot reach: which ring a
/// cancel may stop, what Recents records, and which delivered alert goes. The contract is
/// the monorepo's `docs/ring_cancel_contract.md`.
///
/// ⛔ IT ARRIVES ON THE ALERT TOKEN AS AN APNs BACKGROUND PUSH, NEVER OVER VoIP. A VoIP push
/// obliges the app to report a NEW call, so this one reaches
/// ``AppDelegate/application(_:didReceiveRemoteNotification:fetchCompletionHandler:)``
/// instead, as top-level keys beside `aps: {content-available: 1}`. Apple may throttle or
/// drop it, which is why the local ring timeout stays as the fallback.
///
/// ⛔ IT REACHES THE DEVICE THAT ANSWERED TOO, AND THERE IT CHANGES NOTHING. See
/// ``outcome(phase:ringingCallId:)``: a call answered or being answered here is never
/// touched, so a late cancel cannot hang up a conversation.
extension RingCancel {
    /// What this device should do about the cancel, given the one inbound call it holds.
    ///
    /// ⛔ MATCHED ON `callId` ONLY, AND NEVER AGAINST A DIFFERENT CALL. A ring for another
    /// call is not stopped, whatever its phase.
    ///
    /// ⛔ ``IncomingCallPhase/answering`` COUNTS AS ANSWERED HERE. The answer request is in
    /// flight, so the cancel that says `answered` may well be about this device's own press,
    /// and it can arrive before the answer response does.
    ///
    /// - Parameter ringingCallId: the call ``IncomingCallModel`` holds
    ///   (`IncomingCallState.callID`), or nil when it holds none.
    func outcome(phase: IncomingCallPhase, ringingCallId: String?) -> RingCancelOutcome {
        guard ringingCallId == callId else { return .notRingingHere }
        switch phase {
        case .ringing:
            return .endRing(reason.endedReason)
        case .answering, .inCall:
            return .answeredHere
        // ⚠️ NOTHING LEFT TO STOP. A ring this device declined or timed out is already
        // over; only a leftover alert can remain, and the caller removes it.
        case .idle, .ended:
            return .notRingingHere
        }
    }

    /// The delivered alerts that announced this call ringing, by notification identifier.
    ///
    /// ⚠️ THE `incoming_call` ALERT ONLY. The ring reaches an iPhone's alert row as well as
    /// its VoIP row, so an alert naming this `callId` can be sitting in Notification Centre
    /// after the ring is over. Any other notification that happens to carry the id is not
    /// this cancel's to remove.
    func alertIdentifiers(in delivered: [(identifier: String, payload: [String: String])]) -> [String] {
        delivered.compactMap { item in
            guard item.payload[PushPayload.keyType] == PushPayload.typeIncomingCall,
                  item.payload[PushPayload.keyCallId]?.trimmingCharacters(in: .whitespacesAndNewlines) == callId
            else { return nil }
            return item.identifier
        }
    }
}

extension RingCancelReason {
    /// What CallKit records in Recents for the ring.
    ///
    /// ⚠️ `.answeredElsewhere` IS WHAT KEEPS AN ANSWERED CALL OUT OF THE MISSED LIST:
    /// somebody did take it. `.unanswered` is a missed call, which is the truth for a ring
    /// nobody reached. `.remoteEnded` is a caller who hung up first, the same answer
    /// ``IncomingCallCopy/endedReason(for:)`` gives `callerCancelled`.
    var endedReason: CXCallEndedReason {
        switch self {
        case .answered: .answeredElsewhere
        case .callEnded: .remoteEnded
        case .timeout, .withdrawn: .unanswered
        }
    }
}

/// What a ring cancel did on this device.
enum RingCancelOutcome: Equatable, Sendable {
    /// This device holds that call ringing: end it with this reason.
    case endRing(CXCallEndedReason)

    /// This device answered that call, or is answering it. ⛔ Nothing is touched, not even
    /// its alert: the contract's rule is to ignore the cancel completely.
    case answeredHere

    /// Nothing rings here for that call. Only a leftover alert can be removed.
    case notRingingHere
}
