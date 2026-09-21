import DistrictCall
import DistrictData
import DistrictModel
import Foundation

/// Performing a reducer's commands, including the one that reaches the CARRIER.
///
/// ⛔ SPLIT OUT OF `DialerModel.swift` FOR THE 500-LINE `file_length` CEILING THAT
/// `swiftlint --strict` PROMOTES TO AN ERROR, exactly as `DialerTasks.swift`,
/// `DialerCopy.swift` and `DialerEntry.swift` are. Nothing here is a separate
/// concern from the model.
///
/// ⚠️ THE PRICE IS THREE MORE MODULE-VISIBLE MEMBERS: ``DialerModel/dial``,
/// ``DialerModel/workspaceId`` and ``DialerModel/reportEnded()``. The first two are
/// immutable `let`s and the third neither reads nor writes user-facing state, so
/// none of them fails the test `DialerTasks.swift` records — ``DialerModel/refusal``
/// stays narrow because a view assigning one would put a sentence on the keypad the
/// operator never earned.
///
/// ⛔ WHY ANY OF THIS EXISTS: `Room.disconnect()` IS NOT A HANG-UP. It removes this
/// device from the room and leaves the SIP participant in it, so the telephone at
/// the far end goes on ringing or talking to an empty room and the carrier goes on
/// billing. Measured: two calls the operator ended in under a second each billed
/// roughly 90 seconds at Twilio, with nothing failing and nothing logged.
extension DialerModel {
    /// ⛔ IN ORDER AND SEQUENTIALLY, because the order is part of
    /// ``SoftphoneCommand``'s contract: the report goes before the disconnect, and
    /// the carrier request goes last so that nothing local can ever wait on a
    /// network round trip.
    func perform(_ commands: [SoftphoneCommand]) async {
        for command in commands {
            switch command {
            case let .engine(engineCommand):
                await calls.perform(engineCommand)
            case .reportCallEnded:
                reportEnded()
            case let .requestServerHangUp(callId):
                requestServerHangUp(callId: callId)
            }
        }
    }

    /// Ask the server to end the carrier leg. ⛔ Fire and forget.
    ///
    /// ⛔ IT IS NOT `await`ED AND MUST NEVER BECOME SO. Every caller reaches here
    /// from ``perform(_:)``, which runs inside ``apply(_:)`` while a hang-up is
    /// being torn down; awaiting a network round trip there would hold the ended
    /// state — and with it the call summary and the release of the CallKit claim —
    /// for the length of a timeout on a call the operator has already finished with.
    /// The reducer emits this command LAST for the same reason, which is the belt to
    /// this brace.
    ///
    /// ⛔ THE TWO VALUES ARE READ OUT BEFORE THE TASK, WHICH IS THE WHOLE POINT OF
    /// THE SHAPE. The request has to outlive this model: ``release()`` drops the
    /// container's only strong reference on the same teardown that produced this
    /// command, so a closure that reached `self` for the repository would find nil
    /// on precisely the path this exists for and send nothing. `self` is captured
    /// weakly and used only to record a diagnostic afterwards; the request itself
    /// depends on nothing that can die.
    ///
    /// ⚠️ AN UNSTRUCTURED `Task` RATHER THAN ONE OF THE THREE ``release()`` CANCELS,
    /// deliberately. It is stored in no property, so nothing cancels it, which is
    /// the correct lifetime for a request whose whole job is to survive the teardown
    /// that issued it.
    ///
    /// ⚠️ NO RETRY. The route is idempotent, so a retry would be SAFE — and it would
    /// still be wrong: it would spend requests on behalf of a call nobody is on, and
    /// the failures that reach here are offline and signed-out, neither of which a
    /// second immediate attempt fixes.
    func requestServerHangUp(callId: String) {
        let repository = dial
        let workspace = workspaceId
        Task { [weak self] in
            let outcome = await repository.hangUp(workspaceId: workspace, callId: callId)
            // ⛔ A REFUSAL IS NOT A FAILURE HERE. `alreadyEnded`, `notFound` and
            // `notDirectCall` are all `.success`, because by the time this is sent
            // the call is over locally and there is nothing for any of them to
            // change. See ``HangUpOutcome``.
            guard case let .failure(error) = outcome else { return }
            // ⚠️ RECORDED, NEVER SHOWN. See ``DialerModel/lastServerHangUpFailure``.
            self?.lastServerHangUpFailure = String(describing: error)
        }
    }

    /// The dial came back after the call was already torn down locally.
    ///
    /// ⛔ THIS IS THE CASE THE WHOLE DESIGN IS SHAPED AROUND, AND IT IS THE COMMON
    /// ONE. `POST /api/district/calls/dial` writes the `Call` row and instructs the
    /// carrier BEFORE it answers, so a response that has not arrived may already be
    /// ringing somebody; an operator who mis-dials hangs up in well under a second.
    /// Measured: `CXEndCallAction` at +0.7s, the server's leg placed at +3s.
    /// Discarding this body throws away the only `callId` this client will ever hold.
    ///
    /// ⛔ THE REDUCER IS ASKED FIRST, AND THE DIRECT SEND IS THE FALLBACK RATHER THAN
    /// THE RULE. ``SoftphoneSession`` latches
    /// ``SoftphoneState/serverHangUpRequested``, so feeding it the credential is what
    /// makes "exactly once" hold when the ending already spent the id. The two
    /// branches are mutually exclusive on one `if`, and this method runs once per
    /// dial, so at most one request leaves either way.
    ///
    /// ⚠️ THE `nil` BRANCH IS REACHABLE AND IS NOT DEFENSIVE PADDING. ``call`` is
    /// cleared by ``dismissEndedCall()`` and by ``refuse(_:)``, so an operator who
    /// taps away from the summary inside the response window leaves no session to
    /// feed — and the carrier leg is exactly as live as it was a moment earlier.
    ///
    /// ⚠️ ONLY ``DialOutcome/placed(_:)`` CARRIES AN ID. The three refusals mean no
    /// call was placed at the carrier, so there is nothing to end.
    func abandonPlacedCall(_ outcome: Result<DialOutcome, ApiError>) async {
        guard case let .success(.placed(response)) = outcome else { return }
        if call == nil {
            requestServerHangUp(callId: response.callId)
        } else {
            await apply(.dialAccepted(response))
        }
    }
}
