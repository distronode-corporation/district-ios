/// Where the room session is.
///
/// ⛔ FILE SCOPE, NOT NESTED, for the reason `AnalyticsModel.swift` records.
///
/// ⛔ SPLIT OUT OF `ActiveRoomModel.swift` BECAUSE OF THE 500-LINE `file_length`
/// CEILING, exactly as `RoomsCopy.swift` is. Nothing here is a separate concern.
///
/// ⛔ FOUR NON-LIVE CASES RATHER THAN TWO, AND THE THREE THAT ARE NOT ``left`` ARE
/// THE POINT. A `disconnected(reason: nil)` must NOT map to ``left``, which renders
/// "You have left this room." — that event is reachable ONLY when the operator did
/// NOT leave, because ``ActiveRoomModel/leave()`` cancels the event pump before it
/// disconnects and sets ``left`` itself. Mapping it there would report being removed
/// by the SFU, having the room deleted, a token expiring or a duplicate identity
/// evicting you as the operator's own act, with the grid replaced and nothing
/// offered. The two call reducers next door map the identical event to
/// ``CallEndReason/remoteEnded(reason:)``; this is the same rule.
enum RoomPhase: Equatable {
    /// Nothing has been joined. ⛔ THE STATE THIS SCREEN IS ENTERED IN, ALWAYS.
    case idle
    case joining
    case connected
    /// ⛔ RENDERED, NEVER BRANCHED TO AN ERROR. See ``RoomEngineEvent/reconnecting``.
    case reconnecting
    /// ⛔ THE OPERATOR PRESSED LEAVE, AND NOTHING ELSE REACHES THIS. It is set
    /// directly by ``ActiveRoomModel/leave()``, never by the reducer.
    case left
    /// The room ended without this device asking.
    ///
    /// ⚠️ THE REASON IS nil FOR A CLEAN DISCONNECT, which is the common shape: an
    /// SFU removing a participant, a room being deleted and a duplicate identity
    /// evicting the older session all arrive with no error attached. nil therefore
    /// means "we were disconnected and were not told why", never "this was fine".
    case droppedRemotely(reason: String?)
    /// A telephone call, a sign-out or a workspace switch took the audio.
    ///
    /// ⛔ ITS OWN CASE RATHER THAN ``left``, BECAUSE THE OPERATOR DID NOT DO IT AND
    /// WILL WANT BACK IN. See ``RoomAudioYield``.
    case yielded(RoomAudioYield)
    case failed(message: String?)
}

extension RoomPhase {
    /// Whether the room is up, or on its way up.
    ///
    /// ⚠️ HERE RATHER THAN IN THE VIEW, so the controls, the hidden back button and
    /// the model all read one exhaustive switch. A `default` is deliberately absent:
    /// a new case must be classified rather than silently counted as not-live.
    var isLive: Bool {
        switch self {
        case .connected, .reconnecting, .joining:
            true
        case .idle, .left, .droppedRemotely, .yielded, .failed:
            false
        }
    }

    /// Whether ``ActiveRoomModel/join()`` may run from here.
    ///
    /// ⛔ EVERY DEAD-BUT-NOT-LEFT STATE SAYS YES, AND THAT IS THE OTHER HALF OF THE
    /// SAME RULE. Telling somebody they were dropped and then offering no way
    /// back is the same failure rendered as an absence; a `Room` cannot be
    /// reconnected, but a fresh engine can, and ``ActiveRoomModel/join()`` builds one
    /// per join already.
    ///
    /// ⛔ ``left`` SAYS NO. The operator asked to leave and the screen pops behind
    /// them; a Rejoin control on the way out would be an invitation nobody wanted.
    /// The lobby's own Rejoin entry is how somebody goes back deliberately.
    var canJoin: Bool {
        switch self {
        case .idle, .droppedRemotely, .yielded, .failed:
            true
        case .joining, .connected, .reconnecting, .left:
            false
        }
    }
}

/// What the OS has granted, as far as this screen knows.
///
/// ⛔ THE TWO PERMISSIONS ARE NOT EQUIVALENT AND MUST NOT BE ASKED FOR AS A PAIR THAT
/// EITHER SUCCEEDS OR FAILS. A denied CAMERA is a normal way to attend a meeting:
/// audio-only, and the room is fully usable. A denied MICROPHONE is not the same
/// thing, but it is still not a reason to refuse the join: a viewer never publishes
/// anyway, and somebody who only wants to watch and read the minutes is doing
/// something legitimate. So the screen degrades in two directions rather than gating
/// on one boolean.
///
/// ⚠️ ``requested`` IS "WE HAVE ASKED", NOT "WE HAVE BEEN GRANTED". Before the first
/// request both flags are false and mean nothing; rendering a "microphone blocked"
/// warning in that window would tell somebody something untrue about their own
/// device.
struct RoomPermissions: Equatable {
    var requested = false
    var microphoneGranted = false
    var cameraGranted = false
}
