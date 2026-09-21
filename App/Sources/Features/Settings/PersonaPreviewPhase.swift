import Foundation

/// Where one persona audition is.
///
/// ⛔ FILE SCOPE AND ITS OWN FILE, the split ``RoomPhase`` is and for the same lint
/// ceiling. It is deliberately NOT ``RoomPhase`` itself: a meeting has a lobby, a
/// rejoin and a camera, while an audition has a MINTING step that spends a rate-limit
/// slot and starts a charge, and a "connected but the agent has not arrived yet" state
/// that is the whole question the screen answers. Sharing an enum would mean every
/// reader of either screen deciding which cases apply to it.
enum PersonaPreviewPhase: Equatable {
    /// Nothing has been started. ⛔ THE STATE THE SHEET OPENS IN, ALWAYS — minting a
    /// token on appear would charge for a screen somebody merely looked at.
    case idle

    /// The credential is being minted.
    ///
    /// ⚠️ ITS OWN CASE BECAUSE IT IS THE STEP THAT IS NOT FREE AND NOT IDEMPOTENT. The
    /// route is capped at 10/min per workspace and nothing in this client retries it.
    case minting

    case connecting

    /// Joined, and the agent is not in the room yet.
    ///
    /// ⛔ NOT "live". The agent is dispatched to a `preview_*` room and takes a moment
    /// to arrive; telling somebody to start talking before it has would have them
    /// speak into a room that nothing is listening to, and then conclude the persona is
    /// broken.
    case waiting

    /// The agent is in the room.
    case live

    /// ⛔ RENDERED, NEVER BRANCHED TO AN ERROR. A phone handing over between wifi and
    /// its radio reconnects routinely and the SDK resumes the session itself.
    case reconnecting

    case ended(PersonaPreviewEnding)

    /// ⚠️ THE SENTENCE LIVES ON THE MODEL, NOT IN THE CASE. A ``FailureText`` carries an
    /// ACTION as well as a message and is not `Equatable`; keeping it out of here is
    /// what lets a test compare phases at all.
    case failed
}

/// Why an audition stopped.
///
/// ⛔ THREE ENDINGS, NOT ONE, BECAUSE THE OPERATOR DID ONLY THE FIRST OF THEM. A
/// session that was taken away by an arriving telephone call, or dropped by the server,
/// is not "you stopped it" — and on a screen whose next action costs money, telling
/// somebody they stopped something they did not is how a second billed session gets
/// started.
enum PersonaPreviewEnding: Equatable {
    case stopped
    /// ⚠️ nil IS THE COMMON SHAPE: an SFU removing a participant, a room being deleted
    /// and a token expiring all arrive with no reason attached.
    case droppedRemotely(reason: String?)
    /// A telephone call, a sign-out or a workspace switch took this device's audio.
    case yielded(RoomAudioYield)
}

extension PersonaPreviewPhase {
    /// Whether a session is up, or on its way up.
    ///
    /// ⚠️ AN EXHAUSTIVE SWITCH WITH NO `default`, so a new phase has to be classified
    /// rather than silently counted as not-live — which here would mean offering a
    /// second billed session on top of a running one.
    var isRunning: Bool {
        switch self {
        case .minting, .connecting, .waiting, .live, .reconnecting:
            true
        case .idle, .ended, .failed:
            false
        }
    }
}
