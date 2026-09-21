import CallKit
import DistrictCall
import Foundation

/// Every sentence the dialer says, the two thresholds behind its button, and the
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
    /// See ``canPlaceCall``.
    static let minimumDigits = 8

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
    static let busy = FailureText(
        message: "There is already a call on this device. End it before placing another.",
        action: .none
    )

    static let notStarted = FailureText(
        message: "iOS did not start the call, so nothing was dialled. Another call may already be in progress.",
        action: .none
    )

    /// ⛔ NOTHING WAS PLACED, AND THE SENTENCE SAYS THAT BEFORE IT SAYS WHY. A refused microphone is
    /// answered before the OS or the carrier hears of the call (see
    /// ``startAfterMicrophone(uuid:handle:)``), so there is no call to end and nothing billed. It names
    /// the one remedy there is: iOS does not show the question a second time once somebody said no.
    static let microphoneOff = FailureText(
        message: "Nothing was dialled because District AI cannot use the microphone. Turn it on in Settings.",
        action: .none
    )

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
    static let inRoom = FailureText(
        message: "You are in a room on this device. Leave it before placing a call.",
        action: .none
    )

    static let doNotCallFallback = "That number has opted out of calls from this workspace."

    /// ⛔ STATES THE FACT AND STOPS, AND NAMES NO WEBSITE. App Store Review Guideline
    /// 3.1.3(b) keeps subscription purchase and management out of the app entirely, so a
    /// "Fix billing" control that deep-linked to Stripe would be rejected — and 3.1.1
    /// makes naming the place the same rejection with no button on it. A
    /// reactivation is a billing action, so there is no remedy that can honestly be given
    /// here; the sentence says why calls stopped and leaves it there.
    static let subscriptionFallback = "This workspace's subscription is not active, so calls are paused."

    /// ⛔ NOT A BILLING FAILURE AND NOT A PERMISSION FAILURE. "Pay and it resumes" is
    /// the case next door; this one is "ask us and we turn it back on".
    static let dormantFallback = "This workspace is paused for inactivity, so calls are on hold. "
        + "Ask us to reactivate it."

    /// ⛔ PRESENCE RATHER THAN WORDING, and the entry into this screen is hidden for the
    /// same role, so a viewer arriving here came from a restored back stack or a deep
    /// link. `POST /api/district/calls/dial` excludes `viewer` server-side.
    static let viewerNotice = "You are in this workspace as a viewer, so you cannot place calls."

    static let microphoneNotice = "Placing a call turns on your microphone."

    static let entryHint = "Enter a number with its country code, for example +1 416 555 0100."

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
            "Unrecognised country code. Check the number before calling."
        case let .named(name):
            "This number rings \(name)."
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
            return "Start with a country code, for example +1 for Canada and the United States."
        case .strayPlus:
            return "A number may contain only digits after the +."
        case .tooShort:
            return "That is too short. A number has at least \(DialEntry.minimumDigits) digits after the +."
        case .tooLong:
            return "That is too long. A number has at most \(DialEntry.maximumDigits) digits after the +."
        // ⛔ THE ONLY REFUSAL HERE THAT IS NOT A CORRECTION. Every other case tells the
        // operator how to fix the number; this one tells them to leave the app, because
        // District cannot place an emergency call and must not pretend it might. Naming
        // the Phone app is the load-bearing half — a bare refusal in an emergency is
        // barely better than the misleading "add a country code" it replaces.
        case .emergencyNumber:
            return "District cannot place emergency calls. Use the Phone app to call for help."
        }
    }

    /// ⛔ "Call back", NEVER "Redial", AND THE WORD IS THE WHOLE POINT OF THE
    /// HEADING. The call log records the workspace's OWN number on an outbound row,
    /// so only inbound calls carry a number worth dialling. See the ⛔ on
    /// ``CallsRepository/recentCallbacks(workspaceId:limit:)``, which is where the
    /// filter lives. A heading that said redial would promise to repeat outbound
    /// calls this list cannot repeat.
    static let callbacksTitle = "Call back"

    static let callbacksLoading = "Looking for recent callers…"

    /// ⚠️ AN EMPTY LIST IS AN ANSWER, so this sentence explains the absence rather
    /// than apologising for it.
    static let callbacksEmptyTitle = "No recent callers"

    static let callbacksEmpty = "Numbers from incoming calls appear here so you can call someone back with one tap."

    /// ⛔ A DIFFERENT SENTENCE FROM THE EMPTY ONE, because "we could not look" and
    /// "there is nothing" are different answers and confusing them is what
    /// ``FailureText`` exists to stop.
    static let callbacksFailed = "Could not load recent callers"

    /// ⛔ THE HINT SAYS WHAT THE TAP DOES, AND IT IS NOT "call". Android puts a
    /// button labelled Call in the row's trailing slot that also only fills the
    /// field, which is the one place its wording undersells the rule; a row that
    /// looks like it dials is a mis-scroll away from a call nobody asked for.
    static let callbackHint = "Fills the number into the keypad. You still press Call to dial."

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
