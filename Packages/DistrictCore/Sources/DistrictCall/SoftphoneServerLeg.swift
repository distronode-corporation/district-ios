/// The half of an ending that reaches the CARRIER rather than this device.
///
/// ⛔ A SEPARATE FILE BECAUSE `SoftphoneSession.swift` IS AT SwiftLint's 500-LINE
/// `file_length` AND ITS TYPE BODY IS NEAR THE 300-LINE `type_body_length`, NOT
/// BECAUSE THIS IS A SEPARATE CONCERN. It is the same reducer and the same
/// invariants; `ShellView+Routing.swift` exists for the identical reason and says
/// so in its own header. Read this beside the ⛔ on
/// ``SoftphoneCommand/requestServerHangUp(callId:)``.
///
/// ⛔ THE DEFECT THIS CLOSES, WRITTEN DOWN BECAUSE NOTHING ABOUT IT IS VISIBLE.
/// Ending a direct softphone call with `Room.disconnect()` alone removes THIS
/// device from the room; the SIP participant is untouched, so the telephone at the
/// far end goes on ringing or talking to an empty room, and the carrier goes on
/// billing. Two calls ended in under a second can each bill roughly 90 seconds.
/// Nothing throws, nothing logs, and every screen says the call is over — the only
/// artefact is a number on an invoice.
///
/// ⛔ THE HARD CASE IS THE ORDERING, AND IT IS THE COMMON ONE RATHER THAN AN EDGE.
/// `POST /api/district/calls/dial` writes the `Call` row and instructs the carrier
/// BEFORE it answers, so a dial that has not come back may already be ringing
/// somebody. An operator who mis-dials hangs up in well under a second, and the
/// response can take three: `CXEndCallAction` at +0.7s, the server's leg placed
/// at +3s is a typical trace. In that window the session is ALREADY
/// ``SoftphonePhase/ended(_:)`` and the `callId` does not exist yet — so an
/// implementation that could only ask the server to hang up while a call was live
/// would miss exactly the case the operator cares most about, and would look
/// correct in every test that walked a call from end to end.
///
/// 🔑 THE ANSWER IS THAT THE TERMINAL PHASE ABSORBS THE CREDENTIAL FOR EVERY
/// PURPOSE BUT THIS ONE. ``reduceEnded(_:_:)`` takes the late
/// ``SoftphoneEvent/dialAccepted(url:token:callId:)``, records the id, changes no
/// phase, joins nothing, and emits the hang-up. Everything else that arrives after
/// the end is still swallowed, so the "exactly once" property the terminal phase
/// exists for is intact.
///
/// ⛔ EXACTLY ONCE ACROSS BOTH EXITS, LATCHED IN THE STATE. Two paths can emit the
/// request — an ordinary ending that already knows the id, and a credential that
/// lands after an ending that did not — and a hang-up during
/// ``SoftphonePhase/connecting`` followed by a redelivered credential would take
/// both. ``SoftphoneState/serverHangUpRequested`` is what stops that, and it is
/// state rather than a phase test because the phase is `ended` in both cases.
extension SoftphoneSession {
    /// Append the carrier hang-up to an ending's commands, at most once.
    ///
    /// ⛔ LAST IN THE LIST, AND THE POSITION IS A CONTRACT RATHER THAN A HABIT.
    /// The two commands before it are local and instant: the OS is told the call
    /// is over and the socket is closed. This one is a network round trip, and the
    /// App tier performs the list IN ORDER — so putting it first would let a future
    /// implementation that awaited the request hold the system's call UI open for
    /// the length of a timeout, on a call the user has already ended. Last means
    /// the worst a mistake there can cost is a late request. ⚠️ The App tier fires
    /// it detached today precisely so that even last it costs nothing; the ordering
    /// is the belt to that brace.
    ///
    /// ⚠️ A NO-OP WITH NO `callId`, WHICH IS THE WHOLE OF
    /// ``SoftphonePhase/dialing``. A hang-up there produces the local teardown
    /// alone and the carrier request is issued later, by ``reduceEnded(_:_:)``,
    /// when the credential finally lands.
    static func withServerHangUp(
        _ state: inout SoftphoneState,
        _ commands: [SoftphoneCommand]
    ) -> [SoftphoneCommand] {
        guard let callId = state.callId, !state.serverHangUpRequested else { return commands }
        state.serverHangUpRequested = true
        return commands + [.requestServerHangUp(callId: callId)]
    }

    /// The ``SoftphonePhase/ended(_:)`` arm.
    ///
    /// ⛔ IT ANSWERS ONE EVENT AND DROPS THE REST, WHICH KEEPS THE TERMINAL PHASE
    /// TERMINAL. A second hang-up, a late engine failure, an OS end-call callback
    /// that arrives twice: all still produce nothing, which is what makes "the
    /// disconnect happens exactly once" true. The single exception carries the one
    /// fact the machine is still missing.
    ///
    /// ⛔ IT DOES NOT MOVE THE PHASE AND MUST NEVER BE MADE TO. The call is over:
    /// the operator is looking at a summary, the engine is gone, and CallKit has
    /// been told. Re-entering ``SoftphonePhase/connecting`` on a credential for a
    /// call nobody is on would join a room to hang it up, which is both slower and
    /// a live microphone.
    ///
    /// ⚠️ THE ID IS RECORDED EVEN WHEN THE LATCH IS ALREADY CLOSED. Nothing reads
    /// it on that path today; it is written because a state that knows the call's
    /// id is strictly more truthful than one that does not, and the alternative is
    /// a field whose value depends on which of two orderings happened.
    static func reduceEnded(
        _ state: SoftphoneState,
        _ event: SoftphoneEvent
    ) -> (state: SoftphoneState, commands: [SoftphoneCommand]) {
        guard case let .dialAccepted(_, _, callId) = event else { return (state, []) }
        var next = state
        next.callId = callId
        // ⚠️ BOUND BEFORE THE TUPLE, like ``SoftphoneSession/end(_:_:)`` and
        // ``SoftphoneSession/toggleSpeaker(_:)``. The helper mutates `next`, and a
        // tuple literal evaluates left to right, so an inline call would pair the
        // command with the state as it was BEFORE the latch closed — and the whole
        // point of the latch is that the next reader sees it shut.
        let commands = withServerHangUp(&next, [])
        return (next, commands)
    }
}
