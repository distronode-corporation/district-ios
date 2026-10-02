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
/// recording sibling, and the only recording surface on this API is a telephone
/// call's. The artefacts are the minutes and the transcript, and the copy offers
/// exactly those.
///
/// ⛔ THE COMPANION IS NAMED BEFORE ANYBODY JOINS, NOT AFTER. It is dispatched into
/// every `meet_` room and transcribes what is said; being told afterwards is being
/// told too late.
enum RoomsCopy {
    // MARK: - The lobby

    static let title = "Rooms"

    static let startLabel = "Start or join a room"

    static let nameLabel = "Room name"

    /// ⛔ SHOWN WHILE TYPING, NEVER APPLIED TO THE FIELD. The name is lower-cased and
    /// hyphenated before it reaches the server, and a field that rewrote itself would
    /// move the cursor and eat spaces mid-word. Two people who typed "Weekly Review"
    /// and "weekly review" are in the SAME room, and this is the only place that is
    /// visible before they find out the hard way.
    static func namePreview(_ normalized: String) -> String {
        "Everyone joining \u{201C}\(normalized)\u{201D} lands in the same room."
    }

    static let nameHint = "Name the room. Anyone in this workspace who types the same name joins you."

    static let join = "Join room"

    static let companionNotice = "The Companion joins every room and writes up the minutes."

    /// ⛔ PRESENCE RATHER THAN WORDING, matching ``DialerCopy/viewerNotice``: the
    /// control is gone and this says why. Creating a room is what the role gate
    /// covers; ATTENDING one is not, which is why a viewer still gets Rejoin below.
    static let viewerCannotStart = "You are in this workspace as a viewer, so you cannot start a room. "
        + "You can still join a meeting that is already running."

    static let historyLabel = "Recent meetings"

    static let emptyTitle = "No meetings yet"

    static let emptyBody = "Meetings appear here once one has been held, with the minutes the Companion wrote."

    /// ⛔ NAMED AS A PREVIEW, because the server truncates to 220 characters.
    /// Presenting two sentences as the minutes would quietly deliver a fraction of
    /// what was written.
    static func preview(_ text: String) -> String {
        "Preview: \(text)"
    }

    static let noMinutesYet = "Minutes are written when the meeting ends."

    static let noMinutes = "No minutes were saved for this meeting."

    static let openMeeting = "Read the minutes"

    static let rejoin = "Rejoin"

    /// ⚠️ The server's own string for a running meeting; the column carries no enum.
    static let statusInProgress = "in-progress"

    // MARK: - One meeting's record

    static let recordTitle = "Meeting record"

    static let recordMinutes = "Minutes"

    /// ⚠️ BEHIND ITS OWN LABEL AND NEVER FIRST. The transcript is every word
    /// everybody said, unredacted; the summary is what somebody opening this wants,
    /// and putting the raw conversation first would put the sensitive thing on screen
    /// before anyone decided to read it.
    static let recordTranscript = "Transcript"

    static let recordClose = "Close"

    static let recordFailed = "Could not open that meeting"

    // MARK: - The live room

    /// ⛔ WORDED AS A WAIT, NOT AS A FAILURE. A phone handing over between wifi and
    /// its radio does this routinely and the SDK recovers by itself; wording it as an
    /// error teaches people to hang up on something that was about to come back.
    static let stateReconnecting = "Reconnecting. Hold on, the meeting is still here."

    static let stateConnecting = "Connecting\u{2026}"

    /// ⛔ SAID ONLY WHEN THE OPERATOR PRESSED LEAVE, NEVER FOR A SERVER-SIDE
    /// DISCONNECT. See the ⛔ on ``RoomPhase``: telling somebody
    /// they did something they did not do is worse than saying nothing, because they
    /// stop looking for the cause.
    static let stateLeft = "You have left this room."

    /// ⛔ IT DOES NOT GUESS WHY, AND IT DOES NOT SAY THE MEETING IS OVER. Being removed
    /// by the media server, the room being deleted, a token expiring and a duplicate
    /// identity evicting this session all arrive the same way with no reason attached,
    /// and the meeting may well still be running for everybody else — which is why
    /// Rejoin sits beside this sentence rather than a full stop.
    static let stateDropped = "You were disconnected from this room."

    /// ⚠️ THE REASON WHEN THE SERVER SENT ONE, WHICH IS THE MINORITY CASE. A clean
    /// eviction carries nothing, so the bare sentence above is the usual one.
    ///
    /// ⚠️ NOT AN OVERLOAD OF ``stateDropped``. Swift resolves a property and a method
    /// by full name and would accept it; the name is different anyway, because a
    /// reader scanning for the sentence should find one declaration rather than two.
    static func stateDroppedBecause(_ reason: String) -> String {
        "\(stateDropped) (\(reason))"
    }

    /// ⛔ IT NAMES THE CALL, BECAUSE THE OPERATOR WAS ON THE PHONE AND WILL NOT
    /// OTHERWISE CONNECT THE TWO EVENTS. A meeting that vanished while they answered a
    /// customer, with the screen saying only "you left", is the same mislabel as a
    /// remote disconnect wearing a different hat. See the ⛔ on ``RoomAudioYield/telephoneCall``.
    static let stateYieldedToCall = "A phone call came in, so you were taken out of this room."

    static let stateYieldedToSession = "You were taken out of this room when the session ended."

    static let stateYieldedToWorkspace = "You were taken out of this room when the workspace changed."

    /// ⛔ OFFERED FROM EVERY ENDING BUT ``RoomPhase/left``. Telling somebody they were
    /// dropped and giving them no way back renders a failure as an absence, which is
    /// this client's own rule; ``RoomPhase/canJoin`` is where it is decided.
    static let rejoinRoom = "Rejoin this room"

    static let stateFailed = "The connection to this room was lost."

    static let joinFailed = "Could not join"

    /// ⛔ SAYS WHAT THE COMPANION IS DOING, not merely that it is present.
    /// "Companion" alone means nothing to somebody who did not build this.
    static let companionNotes = "Companion is taking notes."

    static let viewerNotice = "You are in this room as a viewer, so your microphone and camera stay off."

    static let noMicrophone = "Microphone access is off, so others cannot hear you. You can still listen."

    static let noCamera = "Camera access is off, so you are here without video."

    static let aloneTitle = "Nobody else here yet"

    static let aloneBody = "Share the invite, or wait for someone to join with the same room name."

    static let unnamedParticipant = "Someone"

    /// ⚠️ THE NAME FIRST, THE STATE AFTER. VoiceOver reads a grid tile by tile and a
    /// person listening for one name should not have to hear "muted" in front of
    /// every other one before reaching it.
    static func mutedParticipant(_ name: String) -> String {
        "\(name), muted"
    }

    static let micOn = "Mute"

    static let micOff = "Unmute"

    static let cameraOn = "Stop video"

    static let cameraOff = "Start video"

    static let flip = "Flip camera"

    /// ⛔ A NOTICE, NOT AN ERROR, AND IT SAYS WHAT IS STILL TRUE. The meeting is
    /// unaffected and one control did not do its job, so this is toned like the
    /// permission notices rather than like ``joinFailed``: a danger-coloured banner
    /// over a working room teaches somebody to leave a meeting that is fine.
    /// ⚠️ IT NAMES NO CAUSE. The SDK throws for several reasons and this client knows
    /// none of them, so inventing one ("the other camera is busy") would be saying
    /// more than we know, which is what the sentinel rules elsewhere in this app
    /// exist to prevent.
    static let flipFailed = "Could not switch cameras. You are still on the same one."

    static let speakerOn = "Speaker on"

    static let speakerOff = "Speaker off"

    static let leave = "Leave"

    /// ⚠️ "Guest" IS LOAD-BEARING: the link admits somebody who is NOT in this
    /// workspace, and it works for twelve hours for whoever holds it.
    static let shareInvite = "Share guest link"

    // MARK: - Before the join

    /// ⛔ THE ROOM IS NOT ENTERED BY ARRIVING AT THE SCREEN. See the ⛔ on
    /// ``ActiveRoomModel``: `Route.activeRoom` is restored from the navigation path
    /// after process death, so a join that ran as an effect would re-enter a room and
    /// re-dispatch its Companion with nobody having asked.
    static let readyTitle = "Ready to join"

    static func readyBody(_ displayName: String) -> String {
        "You are about to join \u{201C}\(displayName)\u{201D}. \(companionNotice)"
    }

    static let joinNow = "Join"

    /// ⛔ NOT A RETRYABLE FAILURE AND NOT A PERMISSION ONE. See the ⛔ on
    /// ``ActiveRoomModel/join()``: one process owns one `AVAudioSession`, the
    /// softphone's coordinator owns it while a telephone call is up, and a room that
    /// joined underneath one would take the call's audio route away mid-conversation.
    ///
    /// ⚠️ THE GUARD BEHIND IT MUST NOT TEST ``CallStack/engine``, which does not exist
    /// until MEDIA time: the promise would then hold for a connected call and not for
    /// the 30 seconds of ringing before one. ``DialerCopy/inRoom`` is the other half of
    /// the pair.
    static let busyWithCall = FailureText(
        message: "There is a call on this device. End it before joining a room.",
        action: .none
    )

    /// ⛔ ONE ROOM AT A TIME, FOR THE SAME AUDIO REASON AND ONE LIFETIME REASON ON TOP.
    /// ``CallStack`` holds the live room so that it survives a screen being destroyed;
    /// a second claim would drop the first model's only reference and strand a
    /// publishing microphone with nobody left to stop it.
    ///
    /// ⚠️ REACHABLE FROM A DEEP LINK OR A RESTORED PATH RATHER THAN FROM TAPPING
    /// AROUND: the room screen hides its own back button while a room is live, so the
    /// ordinary way out is Leave.
    static let busyWithRoom = FailureText(
        message: "You are already in a room on this device. Leave it before joining another.",
        action: .none
    )

    /// ⛔ THE NAME COULD NOT BE MADE INTO A ROOM, which is a client-side refusal and
    /// never a server one. `meet_<ws>_` fails the route's own regex and comes back as
    /// a 400 that reads as a fault; refusing here lets the screen say this instead.
    static let unusableName = FailureText(
        message: "That room name cannot be used. Try letters, numbers and hyphens.",
        action: .none
    )
}
