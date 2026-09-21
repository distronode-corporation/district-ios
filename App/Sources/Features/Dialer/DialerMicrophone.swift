import Foundation

/// The microphone question an outbound call asks before anything else does.
///
/// ⛔ ITS OWN FILE FOR THE REASON `DialerTasks.swift` IS ONE: `DialerModel.swift` sits at the
/// ceiling and `swiftlint --strict` promotes the 500-line `file_length` warning to an error. It widens
/// nothing. Every member it touches (`calls`, `armStartWatchdog(uuid:)` and
/// `abandonStart(uuid:because:)`) is module-visible already.
extension DialerModel {
    /// Ask for the microphone, then hand the call to the OS.
    ///
    /// ⛔ ASKED BEFORE `CXStartCallAction`, AND SO BEFORE THE CARRIER, AND THE ORDER MATTERS. The
    /// media join publishes the microphone and the engine refuses to record without an existing
    /// grant, so a dial that asked nothing would fail only at the join: after
    /// `POST /api/district/calls/dial` had already rung the callee on a real, billed line. A refusal
    /// here places nothing at all: no system call, no dial, no carrier.
    ///
    /// ⚠️ THE CLAIM IS ALREADY HELD WHILE THE ALERT IS UP, so ``CallStack/hasLiveCall`` is true for
    /// those seconds: a room cannot be joined and an arriving ring falls back to the server's PSTN
    /// route. That is the interval a press on Call has always claimed; the alert only lengthens it,
    /// once per install.
    ///
    /// ⚠️ THE WATCHDOG IS ARMED AFTER THE ANSWER, NOT AT THE TAP, so somebody reading the alert is not
    /// timed out as a refused start. ⛔ And on the same main-actor turn as the request, so neither of
    /// the OS's answers (the action performed, or the start refused) can arrive before it exists.
    ///
    /// ⚠️ BOTH REFUSALS END THROUGH ``abandonStart(uuid:because:)`` BECAUSE IT IS THE ONE WRITER OF
    /// `refusal` OUTSIDE THE MODEL'S OWN FILE: the microphone's with its own sentence, and the OS's
    /// refusal of the start with the sentence the watchdog gives, as soon as iOS reports it. The
    /// belt-and-braces end request names a call the OS never started, so CallKit refuses it and
    /// ``CallKitBridge`` records that for diagnosis; nothing reaches the operator or the carrier.
    func startAfterMicrophone(uuid: UUID, handle: String) async {
        guard await calls.microphone.request() else {
            await abandonStart(uuid: uuid, because: Self.microphoneOff)
            return
        }
        calls.callKit.startOutgoingCall(uuid: uuid, handle: handle) { [weak self] in
            Task { await self?.abandonStart(uuid: uuid) }
        }
        armStartWatchdog(uuid: uuid)
    }
}
