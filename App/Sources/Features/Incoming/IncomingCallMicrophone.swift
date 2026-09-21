import UIKit

/// The microphone question an inbound call asks at Answer.
///
/// ⛔ ITS OWN FILE FOR THE REASON `IncomingCallTasks.swift` IS ONE, the 500-line `file_length`
/// ceiling. It widens nothing: ``calls`` was already module-visible.
extension IncomingCallModel {
    /// Ask before the answer round trip, when asking is possible.
    ///
    /// ⛔ A REFUSAL STILL ANSWERS. The person pressed Answer, the agent's transfer is blocked on the
    /// rendezvous that round trip writes, and dropping a caller the platform has already put through
    /// is the worse outcome. ⚠️ Whether the join then succeeds is the engine's decision, not this
    /// one's: with no grant it refuses to record and the call ends as failed, the same outcome as
    /// an answer with no question asked at all.
    func prepareMicrophoneForAnswer() async {
        let active = UIApplication.shared.applicationState == .active
        _ = await Self.askAtAnswer(calls.microphone, appIsActive: active)
    }

    /// Whether to ask, and the asking. ⚠️ Static so it is testable without a ring.
    ///
    /// ⛔ ONLY IN THE FOREGROUND, AND ONLY WHEN NOBODY HAS ASKED. An answer from the lock screen, a
    /// car or a headset arrives with the app in the background, where the alert cannot be put in front
    /// of anybody, and waiting on one there would risk holding the answer past the server's 25-second
    /// rendezvous. That answer relies on the landing question instead; see
    /// ``MicrophoneAccess/askAtLanding()``. An answered question needs no trip to the OS at all.
    ///
    /// - Returns: whether the question was put to the OS.
    static func askAtAnswer(_ microphone: any MicrophoneAccess, appIsActive: Bool) async -> Bool {
        guard appIsActive, microphone.status == .notDetermined else { return false }
        _ = await microphone.request()
        return true
    }
}
