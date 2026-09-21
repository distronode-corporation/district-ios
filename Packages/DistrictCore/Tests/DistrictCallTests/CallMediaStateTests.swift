@testable import DistrictCall
import XCTest

/// The media half both machines share.
final class CallMediaStateTests: XCTestCase {
    func testAFreshCallIsUnmutedOnTheEarpieceWithNothingCounted() {
        let media = CallMediaState()
        // ⚠️ TRUE FROM THE START, unlike a meeting: a softphone that joined muted
        // would put the operator on a call the callee cannot hear.
        XCTAssertTrue(media.microphoneEnabled)
        XCTAssertFalse(media.speakerRequested)
        // ⚠️ nil IS "NOT YET TOLD", not `.earpiece`. A default here would state a
        // fact about hardware nobody has asked.
        XCTAssertNil(media.audioRoute)
        XCTAssertFalse(media.reconnecting)
        XCTAssertEqual(0, media.elapsedSeconds)
        XCTAssertEqual(0, media.remoteParticipants)
    }

    func testReconnectingIsRaisedAndClearedByTheConnectThatRecovers() {
        // ⚠️ A BANNER, NEVER A PHASE. `.connected` is also the recovery signal,
        // which is why it clears the flag rather than only being read on the
        // first connect.
        var media = CallMediaState()
        media.apply(.reconnecting)
        XCTAssertTrue(media.reconnecting)

        media.apply(.connected)
        XCTAssertFalse(media.reconnecting)
    }

    func testParticipantCountsRiseAndAreFlooredAtZero() {
        var media = CallMediaState()
        media.apply(.participantJoined(CallParticipant(identity: "a")))
        media.apply(.participantJoined(CallParticipant(identity: "b")))
        XCTAssertEqual(2, media.remoteParticipants)

        media.apply(.participantLeft(CallParticipant(identity: "a")))
        XCTAssertEqual(1, media.remoteParticipants)

        // ⚠️ FLOORED. The SDK can report a leave for a join this client never
        // saw, and a negative count would make "is the room empty" answer false
        // for ever — so an outbound call would never notice the callee hanging
        // up.
        media.apply(.participantLeft(CallParticipant(identity: "b")))
        media.apply(.participantLeft(CallParticipant(identity: "ghost")))
        XCTAssertEqual(0, media.remoteParticipants)
    }

    func testTheRouteIsRecordedAsReportedIncludingOneThisBuildDoesNotModel() {
        var media = CallMediaState()
        media.apply(.audioRouteChanged(.bluetooth))
        XCTAssertEqual(.bluetooth, media.audioRoute)

        media.apply(.audioRouteChanged(.unknown))
        XCTAssertEqual(.unknown, media.audioRoute)
    }

    func testTheMicrophoneFlagMirrorsTheEngineRatherThanTheCommand() {
        // ⛔ The command does not move the flag: a mute the SDK refuses must
        // leave the state saying the microphone is live, because the opposite
        // invites someone to speak on a line nobody can hear.
        var media = CallMediaState()
        XCTAssertEqual(CallCommand.setMuted(true), media.muteToggleCommand())
        XCTAssertTrue(media.microphoneEnabled, "the command alone changes nothing")

        media.apply(.microphoneChanged(enabled: false))
        XCTAssertFalse(media.microphoneEnabled)
        // ⚠️ THE POLARITY: unmuting is what a toggle does once the microphone is
        // off, and `setMuted` is the inverse of the Kotlin client's spelling.
        XCTAssertEqual(CallCommand.setMuted(false), media.muteToggleCommand())
    }

    func testTheSpeakerIsSetSynchronouslyBecauseThereIsNothingToMirror() {
        var media = CallMediaState()
        XCTAssertEqual(CallCommand.setSpeakerphone(true), media.toggleSpeaker())
        XCTAssertTrue(media.speakerRequested)

        XCTAssertEqual(CallCommand.setSpeakerphone(false), media.toggleSpeaker())
        XCTAssertFalse(media.speakerRequested)
        // ⚠️ AND IT NEVER TOUCHES THE REPORTED ROUTE. What was asked for and what
        // the device did are two facts, and this client holds both rather than
        // passing one off as the other.
        XCTAssertNil(media.audioRoute)
    }

    func testTheTerminalEventsChangeNothingHere() {
        // ⛔ ENDING A CALL IS A DECISION ABOUT THE PHASE and belongs to whichever
        // machine owns it — the two end for different reasons and emit different
        // commands. Reaching it here would let a media helper end a call.
        var media = CallMediaState()
        media.apply(.participantJoined(CallParticipant(identity: "a")))
        let before = media

        media.apply(.disconnected(reason: "carrier"))
        media.apply(.failed(message: "no route to host"))
        XCTAssertEqual(before, media)
    }
}
