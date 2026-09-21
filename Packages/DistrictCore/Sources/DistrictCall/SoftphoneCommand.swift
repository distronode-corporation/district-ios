/// What an outbound call asks the app to do.
///
/// ⛔ ITS OWN FILE PURELY FOR SwiftLint's 500-LINE `file_length`, WHICH
/// `swiftlint --strict` PROMOTES TO AN ERROR. It is read with
/// `SoftphoneSession.swift` and nothing here is a separate concern from it; the
/// same holds for `SoftphoneServerLeg.swift`.
///
/// ⛔ IT EXISTS SO THAT "DOES THE OS ALREADY KNOW THIS CALL IS OVER" IS ANSWERED
/// HERE RATHER THAN IN A VIEW MODEL. If ``SoftphoneSession`` replied in
/// ``CallCommand`` alone, the only thing an ending could ask for would be a media
/// disconnect and nothing on the outbound path would report an end to CallKit.
/// The OS would go on believing a call was live after the callee hung up, after
/// a refused dial and after a media failure — and because the provider is configured
/// `maximumCallGroups = 1`, a call the OS still believes in silently refuses
/// every later one in BOTH directions for the life of the process, and
/// `provider(_:didDeactivate:)` never fires so the audio session is never
/// released. This is the outbound twin of
/// ``IncomingCallCommand/reportCallEnded``.
///
/// ⛔ WHICH ENDINGS THE OS ALREADY KNOWS ABOUT, WRITTEN DOWN BECAUSE BOTH
/// MISTAKES ARE SILENT. Reporting an ending the OS performed itself is API misuse
/// and leaves its own end-call affordance armed against a call that is gone; not
/// reporting one it did not perform is the defect above. The dividing line is
/// ``CallEndReason/hungUpLocally`` and nothing else:
///
///   * `hungUpLocally` is the ONLY reason ``SoftphoneEvent/hangUpPressed``
///     produces, and every producer of that event has already put a
///     `CXEndCallAction` through CallKit — the in-app button asks for one before
///     it feeds the reducer, the lock screen / CarPlay / headset IS one, and a
///     provider reset has torn its calls down without asking. The OS knows, so
///     the list carries no report.
///   * Every other reason is the media layer or the dial route talking, and
///     CallKit cannot see either. The OS does not know, so the report is the only
///     thing that can tell it.
///
/// ⛔ THAT DIVIDING LINE GOVERNS ``reportCallEnded`` AND NOTHING ELSE, WHICH IS THE
/// ONE THING TO GET RIGHT WHEN READING IT NEXT TO ``requestServerHangUp(callId:)``.
/// The SERVER saw none of these endings, local or remote, so the carrier request is
/// emitted on ALL of them; splitting it the same way would leave the leg up on
/// exactly the endings CallKit performed itself.
///
/// ⚠️ THE REDUCER CAN MAKE THIS DECISION AND ``IncomingCallController``'S CANNOT,
/// WHICH IS WHY THE TWO ARE SHAPED DIFFERENTLY AND NEITHER IS WRONG. Inbound
/// emits ``IncomingCallCommand/reportCallEnded`` on every terminal path and lets
/// `IncomingCallModel` suppress it with a flag, because a decline, a ring timeout
/// and a hang-up share one exit there and only some of them went through CallKit.
/// Outbound has exactly one local ending and it is spelled in the reason, so
/// there is no App-side flag to keep in step and no untested branch.
public enum SoftphoneCommand: Sendable, Equatable {
    /// Something for the media session. ⛔ The ordering contract is
    /// ``CallCommand``'s and is unchanged by the wrapper.
    case engine(CallCommand)

    /// Tell the OS the call is over.
    ///
    /// ⚠️ IDEMPOTENT BY CONTRACT, AND ISSUED ON PATHS WHERE NOTHING WAS EVER
    /// CONNECTED. A dial the server refused has a CallKit call and no media at
    /// all, which is precisely the case that would otherwise leave one behind.
    case reportCallEnded

    /// Ask the server to end this call, carrier leg included.
    ///
    /// ⛔ `disconnect` IS NOT A HANG-UP. ``CallCommand/disconnect`` drops THIS
    /// device from the room; the SIP participant stays, so the telephone at the
    /// other end goes on ringing or talking to an empty room and goes on being
    /// billed, with nothing failing and nothing logged.
    ///
    /// ⛔ EMITTED AT MOST ONCE PER SESSION, GUARDED BY
    /// ``SoftphoneState/serverHangUpRequested`` RATHER THAN BY THE TERMINAL PHASE.
    /// The phase alone is not enough, because one of the two exits that can emit
    /// this fires while the session is ALREADY ended — see `SoftphoneServerLeg.swift`.
    ///
    /// ⚠️ BEST EFFORT AT THE FAR END: a failure is logged, never shown, and never
    /// blocks the local teardown. It is emitted LAST for that reason.
    case requestServerHangUp(callId: String)
}
