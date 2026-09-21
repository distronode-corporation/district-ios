@testable import DistrictNetwork
import Foundation
import XCTest

/// ⛔ THE `video_` GUARD, ASSERTED RATHER THAN DOCUMENTED. `video_` is one
/// character from `meet_` in the same server-side `startsWith` chain and silently
/// starts a billable Tavus avatar whose default concurrency ceiling is 1 — so the
/// first accidental one is both a charge and an outage of the avatar feature for
/// every other room.
final class RoomNameTests: XCTestCase {
    func testAVideoRoomCannotBeConstructed() {
        XCTAssertNil(RoomName("video_standup"))
        XCTAssertNil(RoomName(RoomName.billableAvatarPrefix + "ws1-demo"))
    }

    /// ⛔ A BARE `Call.id` IS REFUSED TOO, and that closes the SUPERVISOR case.
    /// `calls/token` stamps `role: "supervisor"` for anything that is not a
    /// `meet_`/`video_` room, whereupon the voice agent unsubscribes the caller's
    /// microphone — the AI then greets a human it cannot hear.
    func testACallIdCannotBeConstructed() {
        XCTAssertNil(RoomName("cln7x9q2h0000abcd"))
        XCTAssertNil(RoomName("call_123"))
    }

    func testAMeetingRoomIsAccepted() {
        XCTAssertEqual(RoomName("meet_standup")?.value, "meet_standup")
        XCTAssertEqual(RoomName("meet_ws1-demo-2")?.value, "meet_ws1-demo-2")
    }

    /// ⚠️ The server restricts room suffixes to `[a-zA-Z0-9-]`. Mirrored here
    /// because the value also reaches a LiveKit room join, where a separator
    /// would be a different room.
    func testASuffixWithASeparatorIsRefused() {
        XCTAssertNil(RoomName("meet_a/b"))
        XCTAssertNil(RoomName("meet_a b"))
        XCTAssertNil(RoomName("meet_a_b"))
        XCTAssertNil(RoomName("meet_café"))
    }

    func testAnEmptySuffixIsRefused() {
        XCTAssertNil(RoomName("meet_"))
        XCTAssertNil(RoomName(""))
    }

    // MARK: - Minting a name

    /// ⛔ THE MINTED NAME CARRIES THE WORKSPACE, WHICH MEANS IT CARRIES A SECOND
    /// UNDERSCORE — so it is deliberately NOT a value ``RoomName/init(_:)`` would
    /// accept. See `testASuffixWithASeparatorIsRefused` above, which pins the other
    /// half of the same decision. The two initialisers answer different questions.
    func testAMintedNameJoinsTheWorkspaceAndTheNormalisedSuffix() {
        XCTAssertEqual(RoomName(workspaceId: "ws-1", suffix: "Weekly Review")?.value, "meet_ws-1_weekly-review")
        XCTAssertNil(RoomName("meet_ws-1_weekly-review"), "the minting rule and the typing rule differ")
    }

    /// ⛔ THE PREFIX IS WRITTEN BY THE TYPE AND CANNOT BE SUPPLIED, which is the
    /// `video_` guard restated for the minting direction: no input can produce a
    /// billable avatar room.
    func testNoInputCanMintAnAvatarRoom() {
        let sneaky = RoomName(workspaceId: "ws-1", suffix: "video_demo")
        XCTAssertEqual(sneaky?.value, "meet_ws-1_videodemo")
        XCTAssertFalse(sneaky?.value.contains(RoomName.billableAvatarPrefix) ?? true)
    }

    /// ⛔ nil RATHER THAN `meet_<ws>_`. That tail fails the route's own
    /// `^(meet|video)_([a-zA-Z0-9-]+)_(.+)$` and answers 400 "Invalid meeting room
    /// format", which reads as a server fault for what is really an empty field.
    func testASuffixThatNormalisesToNothingMintsNoName() {
        XCTAssertNil(RoomName(workspaceId: "ws-1", suffix: ""))
        XCTAssertNil(RoomName(workspaceId: "ws-1", suffix: "   "))
        XCTAssertNil(RoomName(workspaceId: "ws-1", suffix: "///"))
        XCTAssertNil(RoomName(workspaceId: "ws-1", suffix: "--"))
    }

    /// ⚠️ THE WORKSPACE HALF IS THE REGEX'S FIRST GROUP, `[a-zA-Z0-9-]+`, so a
    /// blank or separator-carrying id mints nothing rather than a name the route
    /// would refuse.
    func testAWorkspaceIdTheRouteWouldRefuseMintsNoName() {
        XCTAssertNil(RoomName(workspaceId: "", suffix: "standup"))
        XCTAssertNil(RoomName(workspaceId: "  ", suffix: "standup"))
        XCTAssertNil(RoomName(workspaceId: "ws_1", suffix: "standup"), "the id half admits no separator")
        XCTAssertNil(RoomName(workspaceId: "ws/1", suffix: "standup"))
    }

    // MARK: - Rejoining a name the server wrote

    /// ⛔ A STORED `Meeting.roomName` CARRIES THE WORKSPACE SEPARATOR AND MUST STILL
    /// BE JOINABLE. The server's own regex ends in `.+`, so refusing these would
    /// make the Rejoin control unable to rejoin anything.
    func testAServerWrittenNameIsJoinable() {
        XCTAssertEqual(RoomName(joining: "meet_ws-contract-test_standup")?.value, "meet_ws-contract-test_standup")
        XCTAssertEqual(RoomName(joining: "meet_ws_1_weekly_review")?.value, "meet_ws_1_weekly_review")
    }

    /// ⛔ THE `video_` GUARD AND THE SUPERVISOR GUARD ARE UNCHANGED ON THIS PATH.
    /// What ``RoomName/init(joining:)`` relaxes is the tail's character set, never
    /// the prefix.
    func testJoiningStillRefusesAnAvatarRoomACallIdAndASeparator() {
        XCTAssertNil(RoomName(joining: "video_ws-1_demo"))
        XCTAssertNil(RoomName(joining: "cln7x9q2h0000abcd"))
        XCTAssertNil(RoomName(joining: "meet_a/b"))
        XCTAssertNil(RoomName(joining: "meet_a b"))
        XCTAssertNil(RoomName(joining: "meet_"))
    }

    // MARK: - Normalising and displaying

    /// ⚠️ THE VALUE A LOBBY SHOWS WHILE SOMEBODY TYPES. Two people who typed
    /// "Weekly Review" and "weekly review" are in the SAME room, and this is the
    /// only place that is visible before they find out the hard way.
    func testNormalisingLowercasesHyphenatesAndStripsTheRest() {
        XCTAssertEqual(RoomName.normalizeSuffix("  Weekly Review  "), "weekly-review")
        XCTAssertEqual(RoomName.normalizeSuffix("Café Sync!"), "caf-sync")
        XCTAssertEqual(RoomName.normalizeSuffix("--standup--"), "standup")
        XCTAssertEqual(RoomName.normalizeSuffix("standup_2"), "standup2")
        XCTAssertEqual(RoomName.normalizeSuffix(""), "")
    }

    /// ⚠️ `meet_<uuid>_standup` IS NOT A TITLE, and an empty line is not one either
    /// — anything without the three-part shape comes back unchanged rather than
    /// blanking a row.
    func testTheDisplayNameIsTheHumanHalfAndNeverBlanks() {
        XCTAssertEqual(RoomName.displayName("meet_ws-1_standup"), "standup")
        XCTAssertEqual(RoomName.displayName("meet_ws-1_weekly_review"), "weekly_review")
        XCTAssertEqual(RoomName.displayName("meet_ws-1_"), "meet_ws-1_")
        XCTAssertEqual(RoomName.displayName("meet_standup"), "meet_standup")
        XCTAssertEqual(RoomName.displayName("video_ws-1_demo"), "video_ws-1_demo")
        XCTAssertEqual(RoomName.displayName(""), "")
    }

    /// ⛔ THE IDENTITY IS A CONSTANT. The route REQUIRES the key (missing is a
    /// 400) and IGNORES the value — it derives a hashed identity from the session,
    /// because accepting a client-supplied one was an impersonation hole and a
    /// random one per join produced duplicate tiles.
    func testTheRoomIdentityIsAConstantAndNamesThisPlatform() {
        XCTAssertEqual(RoomIdentity.value, "ios")
    }

    /// ⛔ THE WIRE VALUE, NEVER THE CASE NAME. An unrecognised `timeRange` is not
    /// an error server-side: it silently serves 7d with a 200, so a wrong value is
    /// a week of data under a "90 days" heading with nothing reporting a problem.
    func testEveryAnalyticsRangeHasAWireValueTheServerRecognises() {
        XCTAssertEqual(AnalyticsRange.sevenDays.wire, "7d")
        XCTAssertEqual(AnalyticsRange.thirtyDays.wire, "30d")
        XCTAssertEqual(AnalyticsRange.ninetyDays.wire, "90d")
        XCTAssertEqual(AnalyticsRange.allCases.count, 3)
    }

    /// ⛔ `platform` IS SENT AND IT SAYS `ios`. The route's schema defaults the
    /// field to `"android"`, so omitting it labels every iOS row as an Android one
    /// — and the server's push sender selects the APNs payload from that column.
    func testThePushPlatformIsIos() {
        XCTAssertEqual(PushPlatform.ios, "ios")
    }
}
