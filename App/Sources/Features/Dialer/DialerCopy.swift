import CallKit
import DistrictCall
import Foundation

/// Every sentence the dialer says, the start timeout behind its button, and the
/// one thing it tells the OS rather than a person.
///
/// ⚠️ ITS OWN FILE RATHER THAN AN EXTENSION AT THE BOTTOM OF `DialerModel.swift`, AND
/// THAT IS A LINT CEILING RATHER THAN A DESIGN STATEMENT — the same call ``OverviewEntry``
/// makes, for the same reason. `swiftlint --strict` promotes the `file_length` WARNING at
/// 500 lines to an error, and the model crosses it with this block in it.
///
/// ⛔ THE THREE REFUSAL STRINGS ARE FALLBACKS, NOT THE COPY. Every coded refusal shows the
/// SERVER'S own sentence when there is one, because the remedies differ and the dormancy
/// message is the only place the 100-day window and the reactivation instruction are
/// stated at all. These are what a blank message degrades to. See the ⛔ on ``DialOutcome``.
extension DialerModel {
    /// ⚠️ GENEROUS, BECAUSE THE COST OF FIRING EARLY IS A CALL ABANDONED THAT WAS ABOUT
    /// TO START. A `CXStartCallAction` is normally performed in well under a second.
    static let startTimeoutSeconds = 10

    /// ⚠️ THE SERVER'S SENTENCE WHEN THERE IS ONE. Blank counts as absent, which is the
    /// shared normalisation rule ``ApiErrorEnvelope`` follows.
    static func refusalText(_ message: String?, fallback: String) -> FailureText {
        let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return FailureText(message: trimmed.isEmpty ? fallback : trimmed, action: .none)
    }

    /// ⛔ NOT RETRYABLE, AND NEITHER IS ``notStarted``. A second tap places a second call
    /// or meets the identical refusal; see the ⛔ on ``FailureText/Action``.
    static var busy: FailureText {
        FailureText(message: busyMessage, action: .none)
    }

    static var notStarted: FailureText {
        FailureText(message: notStartedMessage, action: .none)
    }

    /// ⛔ NOTHING WAS PLACED, AND THE SENTENCE SAYS THAT BEFORE IT SAYS WHY. A refused microphone is
    /// answered before the OS or the carrier hears of the call (see
    /// ``startAfterMicrophone(uuid:handle:)``), so there is no call to end and nothing billed. It names
    /// the one remedy there is: iOS does not show the question a second time once somebody said no.
    static var microphoneOff: FailureText {
        FailureText(message: microphoneOffMessage, action: .none)
    }

    /// ⛔ THE ROOM SIDE OF THE SAME REFUSAL ``RoomsCopy/busyWithCall`` MAKES, AND THE
    /// PAIR IS THE POINT: one process owns one `AVAudioSession`, so whichever surface
    /// is asked SECOND says so. Without this half, a dial from inside a live meeting
    /// would simply be allowed.
    ///
    /// ⚠️ IT NAMES THE REMEDY RATHER THAN THE MECHANISM. "Leave the room" is something
    /// the operator can do; "two audio owners" is not.
    ///
    /// ⛔ AN INBOUND CALL IS NOT REFUSED THIS WAY AND MUST NEVER BE. It arrives from
    /// somebody who cannot be shown a sentence, so the room yields to it instead — see
    /// the ⛔ on ``RoomAudioYield/telephoneCall``.
    static var inRoom: FailureText {
        FailureText(message: inRoomMessage, action: .none)
    }

    /// Which country the leading digits will ring, said beside the field.
    ///
    /// ⛔ THIS SENTENCE IS THE GUARD AGAINST A WRONG-COUNTRY DIAL (see the ⛔ at the top
    /// of `DialerEntry.swift`). `+41…` reads "Switzerland" and the operator catches it in the
    /// second before pressing Call; nothing else in the app or on the server ever
    /// mentions the country.
    ///
    /// ⚠️ AN UNKNOWN CODE SAYS SO PLAINLY RATHER THAN GUESSING. Naming the wrong
    /// country is worse than naming none, because a wrong name is read as
    /// confirmation. See ``DialRegion/unrecognised``.
    ///
    /// ⚠️ nil MEANS THERE IS NOTHING HONEST TO SAY YET: no `+` has been typed, so
    /// the string names no country at all and ``entryProblem(_:)`` is the line
    /// that speaks.
    static func destinationLine(_ region: DialRegion) -> String? {
        switch region {
        case .none:
            nil
        case .unrecognised:
            destinationUnrecognised
        case let .named(name):
            destinationNamed(name)
        }
    }

    /// Why the Call button is off, in the operator's terms.
    ///
    /// ⛔ A DISABLED BUTTON WITH NO REASON CONFUSES PEOPLE (THE EIGHT-DIGIT FLOOR
    /// ALONE DOES), so every refusal that is not "you have not typed
    /// anything" gets a sentence. ⚠️ ``DialRefusal/empty`` returns nil because
    /// ``entryHint`` already occupies that moment; two sentences saying the same
    /// thing under an empty field is worse than one.
    ///
    /// ⚠️ THE COUNTRY-CODE SENTENCE NAMES AN EXAMPLE RATHER THAN ASSUMING ONE.
    /// It is the one place a `+1` could creep into the client as a default, and
    /// it stays an illustration in a label rather than a value in the field.
    static func entryProblem(_ refusal: DialRefusal?) -> String? {
        guard let refusal else { return nil }
        switch refusal {
        case .empty:
            return nil
        case .missingCountryCode:
            return entryMissingCountryCode
        case .strayPlus:
            return entryStrayPlus
        case .tooShort:
            return entryTooShort(DialEntry.minimumDigits)
        case .tooLong:
            return entryTooLong(DialEntry.maximumDigits)
        // ⛔ THE ONLY REFUSAL HERE THAT IS NOT A CORRECTION. Every other case tells the
        // operator how to fix the number; this one tells them to leave the app, because
        // District cannot place an emergency call and must not pretend it might. Naming
        // the Phone app is the load-bearing half — a bare refusal in an emergency is
        // barely better than the misleading "add a country code" it replaces.
        case .emergencyNumber:
            return entryEmergencyNumber
        }
    }

    // MARK: - What the OS is told

    /// The OS's own word for how an outbound call finished.
    ///
    /// ⛔ THE MIRROR OF ``IncomingCallCopy/endedReason(for:)``, AND IT IS ONLY EVER
    /// REACHED FOR AN ENDING CALLKIT DID NOT PERFORM ITSELF. Which endings those are
    /// is decided in the reducer — see the ⛔ on ``SoftphoneCommand`` — so a
    /// `hungUpLocally` never arrives here, and it is answered anyway rather than
    /// defaulted so a new ``CallEndReason`` cannot pass through silently.
    ///
    /// ⚠️ A PHASE THAT IS NOT `ended` IS THE REFUSED DIAL, AND `.failed` IS THE RIGHT
    /// ANSWER FOR IT. ``SoftphoneEvent/dialRefused`` returns to `idle` on purpose (no
    /// call summary is drawn for a call that never happened), but the CallKit call
    /// created by the start action is real and has to be ended: a DNC hit, a 402, a
    /// dormant workspace and a handset that is simply offline all land here.
    ///
    /// ⚠️ ``CXCallEndedReason/remoteEnded`` RATHER THAN `.answeredElsewhere` OR
    /// `.declinedElsewhere` FOR THE FAR END. Both of those describe another DEVICE of
    /// this account taking the call, which this app never learns and must not claim.
    static func endedReason(for phase: SoftphonePhase) -> CXCallEndedReason {
        guard case let .ended(reason) = phase else { return .failed }
        switch reason {
        case .remoteHungUp, .remoteEnded:
            return .remoteEnded
        case .failed:
            return .failed
        // ⚠️ UNREACHABLE, AND ANSWERED ANYWAY. `hungUpLocally` went through a
        // `CXEndCallAction`, so the reducer emits no report for it at all; the other
        // four belong to ``IncomingCallController`` and cannot occur on an outbound
        // call. Writing them out makes a NEW reason a compile error here.
        case .hungUpLocally, .declined, .ringTimedOut, .callerCancelled, .answerRefused:
            return .remoteEnded
        }
    }
}
