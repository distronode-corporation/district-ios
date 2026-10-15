import CallKit
import DistrictCall
import DistrictModel
import Foundation

/// The server stopped ringing a call: the `call_ring_cancelled` background push.
///
/// ⛔ WHY IT EXISTS (3.0.1). Nothing was sent when a ring ended, so after one device
/// answered, every other one kept ringing until its own 30 second timer ran out, and a
/// ring that timed out into the assistant kept ringing the same way. The server now
/// sends this on every end of a ring, to the same people the ring reached. The contract
/// is the monorepo's `docs/ring_cancel_contract.md`.
///
/// ⛔ IT ARRIVES ON THE ALERT TOKEN AS AN APNs BACKGROUND PUSH, NEVER OVER VoIP. A VoIP
/// push obliges the app to report a NEW call, so this one reaches
/// ``AppDelegate/application(_:didReceiveRemoteNotification:fetchCompletionHandler:)``
/// instead, as top-level keys beside `aps: {content-available: 1}`. Apple may throttle or
/// drop it, which is why the local ring timeout stays as the fallback.
///
/// ⛔ IT REACHES THE DEVICE THAT ANSWERED TOO, AND THERE IT CHANGES NOTHING. See
/// ``outcome(phase:ringingCallId:)``: a call answered or being answered here is never
/// touched, so a late cancel cannot hang up a conversation.
///
/// ⚠️ IN THE APP TARGET RATHER THAN BESIDE `PushPayload` IN DistrictModel, because its
/// answer is a `CXCallEndedReason` and CallKit does not exist on the Linux tier. The
/// keys are `PushPayload`'s, so the two parsers cannot drift on a name.
struct RingCancel: Equatable, Sendable {
    /// ⚠️ The server's push `type`, verbatim (`RING_CANCELLED_TYPE` in `ring-cancel.ts`).
    static let pushType = "call_ring_cancelled"

    /// ⚠️ The server's key for ``RingCancelReason``, verbatim.
    static let keyReason = "reason"

    let workspaceId: String
    let callId: String
    let reason: RingCancelReason

    /// Read a background push's `userInfo`, or nil when it is not a ring cancel.
    ///
    /// ⚠️ FLATTENED THE WAY EVERY OTHER PAYLOAD IS (``NotificationPresenter/flatten(_:)``):
    /// top-level `String` pairs only, so `aps` and any non-string value are dropped rather
    /// than coerced.
    static func parse(userInfo: [AnyHashable: Any]) -> RingCancel? {
        parse(NotificationPresenter.flatten(userInfo))
    }

    /// ⛔ A MISSING ID IS A DROP, THE RULE `PushPayload.parse` STATES. A blank `callId`
    /// could only match nothing, and the type is matched exactly, so a future
    /// `call_ring_cancelled_v2` is not read as this one.
    static func parse(_ data: [String: String]) -> RingCancel? {
        guard value(data, PushPayload.keyType) == pushType,
              let workspaceId = value(data, PushPayload.keyWorkspaceId),
              let callId = value(data, PushPayload.keyCallId)
        else { return nil }
        return RingCancel(
            workspaceId: workspaceId,
            callId: callId,
            reason: RingCancelReason(wire: value(data, keyReason))
        )
    }

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

    /// ⚠️ TRIMMED, AND A BLANK IS ABSENT, as in `PushPayload`: the payload has one type,
    /// string, so "no id" and "an empty id" are the same wire shape.
    private static func value(_ data: [String: String], _ key: String) -> String? {
        guard let raw = data[key] else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Why the ring ended, as the server says it.
///
/// ⛔ AN UNKNOWN VALUE IS ``withdrawn``, NEVER A DROP. The server may add a reason before
/// this build is on every handset, and the cancel still means "stop ringing"; the contract
/// says to read anything else as `withdrawn`.
enum RingCancelReason: Equatable, Sendable {
    /// Somebody took the call, on any device (possibly this one).
    case answered
    /// The ring window closed and nobody answered; the assistant keeps the call.
    case timeout
    /// The caller hung up while it was ringing.
    case callEnded
    /// The server stopped ringing for its own reason.
    case withdrawn

    init(wire: String?) {
        switch wire {
        case "answered": self = .answered
        case "timeout": self = .timeout
        case "call_ended": self = .callEnded
        // ⚠️ `withdrawn` ITSELF LANDS HERE, with a missing reason and every value this
        // build does not know.
        default: self = .withdrawn
        }
    }

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
