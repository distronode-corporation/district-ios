import Foundation

/// Every sentence the rooms lobby and the live room say.
///
/// ⚠️ ITS OWN FILE RATHER THAN AN EXTENSION AT THE BOTTOM OF A MODEL, the same call
/// ``DialerCopy`` makes and for the same reason: `swiftlint --strict` promotes the
/// `file_length` warning at 500 lines to an error, and two screens' worth of copy in
/// with either model crosses it.
///
/// ⛔ NOTHING HERE SAYS "VIDEO CALL". A `meet_` room is multi-party and the video is
/// optional, so calling it a video call sets an expectation the camera-denied path
/// cannot meet. The Android strings carry the same ⛔ over the same block.
///
/// ⛔ AND NOTHING HERE PROMISES PLAYBACK. `MeetingResponses.swift` says it outright:
/// the `Meeting` model has no recording column, neither meetings route has a
/// recording sibling, and nothing on this API is recorded at all. The artefacts are
/// the minutes and the transcript, and the copy offers exactly those.
///
/// ⛔ THE COMPANION IS NAMED BEFORE ANYBODY JOINS, NOT AFTER. It is dispatched into
/// every `meet_` room and transcribes what is said; being told afterwards is being
/// told too late.
enum RoomsCopy {
    // MARK: - The lobby

    /// ⚠️ The server's own string for a running meeting; the column carries no enum.
    static let statusInProgress = "in-progress"

    // MARK: - Before the join

    /// ⛔ NOT A RETRYABLE FAILURE AND NOT A PERMISSION ONE. See the ⛔ on
    /// ``ActiveRoomModel/join()``: one process owns one `AVAudioSession`, the
    /// softphone's coordinator owns it while a telephone call is up, and a room that
    /// joined underneath one would take the call's audio route away mid-conversation.
    ///
    /// ⚠️ THE GUARD BEHIND IT MUST NOT TEST ``CallStack/engine``, which does not exist
    /// until MEDIA time: the promise would then hold for a connected call and not for
    /// the 30 seconds of ringing before one. ``DialerCopy/inRoom`` is the other half of
    /// the pair.
    static var busyWithCall: FailureText {
        FailureText(message: busyWithCallMessage, action: .none)
    }

    /// ⛔ ONE ROOM AT A TIME, FOR THE SAME AUDIO REASON AND ONE LIFETIME REASON ON TOP.
    /// ``CallStack`` holds the live room so that it survives a screen being destroyed;
    /// a second claim would drop the first model's only reference and strand a
    /// publishing microphone with nobody left to stop it.
    ///
    /// ⚠️ REACHABLE FROM A DEEP LINK OR A RESTORED PATH RATHER THAN FROM TAPPING
    /// AROUND: the room screen hides its own back button while a room is live, so the
    /// ordinary way out is Leave.
    static var busyWithRoom: FailureText {
        FailureText(message: busyWithRoomMessage, action: .none)
    }

    /// ⛔ THE NAME COULD NOT BE MADE INTO A ROOM, which is a client-side refusal and
    /// never a server one. `meet_<ws>_` fails the route's own regex and comes back as
    /// a 400 that reads as a fault; refusing here lets the screen say this instead.
    static var unusableName: FailureText {
        FailureText(message: unusableNameMessage, action: .none)
    }
}
