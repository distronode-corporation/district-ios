@testable import DistrictModel
import XCTest

/// The one place a raw push `data` map becomes something this app acts on.
///
/// ⛔ THIS IS THE ONLY PART OF THE PUSH PATH THAT CAN BE TESTED WITHOUT A DEVICE.
/// Delivery, background wake and token acquisition are all real-device work,
/// and this is where every hostile-payload decision lives. Every case below is
/// ported from the Android client's `PushPayloadTest.kt`.
///
/// ⛔ THE MAP IS THE LEAST TRUSTWORTHY INPUT IN THE APP. The data payload has
/// exactly one type (string), every value is chosen by the sender, and a
/// malformed payload is indistinguishable from a malicious one. Every assertion
/// is about the same rule: anything this build cannot act on is DROPPED, never
/// defaulted.
final class PushPayloadTests: XCTestCase {
    private func parse(_ pairs: [String: String]) -> PushEvent? {
        PushPayload.parse(pairs)
    }

    func testAMessagePayloadParsesToItsTwoIds() {
        let event = parse([
            PushPayload.keyType: PushPayload.typeMessage,
            PushPayload.keyWorkspaceId: "ws-1",
            PushPayload.keyMessageId: "msg-1",
        ])

        XCTAssertEqual(event, .message(workspaceId: "ws-1", messageId: "msg-1"))
    }

    func testAnIncomingCallPayloadParsesToItsTwoIds() {
        let event = parse([
            PushPayload.keyType: PushPayload.typeIncomingCall,
            PushPayload.keyWorkspaceId: "ws-1",
            PushPayload.keyCallId: "CA1",
        ])

        XCTAssertEqual(event, .incomingCall(workspaceId: "ws-1", callId: "CA1"))
    }

    func testAnUnknownTypeIsDroppedSilentlyWhichIsForwardCompatibility() {
        // ⛔ THE SERVER MAY SHIP A PUSH TYPE BEFORE THIS BUILD IS ON EVERY
        // HANDSET, which is the ordinary state of a shipped app rather than an
        // exception. Surfacing it would show users a notification about a
        // feature they do not have.
        XCTAssertNil(parse([
            PushPayload.keyType: "voicemail",
            PushPayload.keyWorkspaceId: "ws-1",
            PushPayload.keyMessageId: "msg-1",
        ]))
    }

    func testAPayloadWithNoTypeAtAllIsDropped() {
        XCTAssertNil(parse([
            PushPayload.keyWorkspaceId: "ws-1",
            PushPayload.keyMessageId: "m",
        ]))
    }

    func testAnEmptyPayloadIsDropped() {
        XCTAssertNil(parse([:]))
    }

    func testAMessageWithNoWorkspaceIsDroppedRatherThanNotifiedAboutNothing() {
        XCTAssertNil(parse([
            PushPayload.keyType: PushPayload.typeMessage,
            PushPayload.keyMessageId: "msg-1",
        ]))
    }

    func testAMessageWithNoMessageIdIsDropped() {
        XCTAssertNil(parse([
            PushPayload.keyType: PushPayload.typeMessage,
            PushPayload.keyWorkspaceId: "ws-1",
        ]))
    }

    func testACallWithNoCallIdIsDroppedBecauseItsAnswerButtonCouldOnly404() {
        // ⛔ THE SHARPEST OF THE DROPS. A ringing screen whose Answer button
        // cannot name a call is worse than no ring: the user answers, the
        // request 404s, and the caller, whom the server is holding for
        // twenty-five seconds, reaches nobody while the app says it tried.
        XCTAssertNil(parse([
            PushPayload.keyType: PushPayload.typeIncomingCall,
            PushPayload.keyWorkspaceId: "ws-1",
        ]))
    }

    func testBlankAndWhitespaceOnlyIdsAreTreatedAsAbsent() {
        // ⚠️ THE DATA PAYLOAD HAS EXACTLY ONE TYPE, so "no id" and "an empty id"
        // are the same wire shape, and a whitespace-only value is what a
        // mis-templated sender produces.
        XCTAssertNil(parse([
            PushPayload.keyType: PushPayload.typeIncomingCall,
            PushPayload.keyWorkspaceId: "  ",
            PushPayload.keyCallId: "CA1",
        ]))
        XCTAssertNil(parse([
            PushPayload.keyType: PushPayload.typeIncomingCall,
            PushPayload.keyWorkspaceId: "ws-1",
            PushPayload.keyCallId: "",
        ]))
    }

    func testABlankTypeIsTreatedAsAbsent() {
        XCTAssertNil(parse([
            PushPayload.keyType: "   ",
            PushPayload.keyWorkspaceId: "ws-1",
            PushPayload.keyMessageId: "msg-1",
        ]))
    }

    func testIdsAreTrimmedSoAPaddedValueIsStillUsable() {
        XCTAssertEqual(
            parse([
                PushPayload.keyType: PushPayload.typeIncomingCall,
                PushPayload.keyWorkspaceId: " ws-1 ",
                PushPayload.keyCallId: "\tCA1\n",
            ]),
            .incomingCall(workspaceId: "ws-1", callId: "CA1")
        )
    }

    func testTheTypeIsMatchedExactlyNotCaseInsensitivelyOrByPrefix() {
        // ⚠️ THE SERVER SENDS THESE TWO LITERALS AND NOTHING ELSE. Loosening the
        // match would mean a future `incoming_call_v2` silently taking the old
        // branch, which on this path means ringing a phone with a payload this
        // build cannot fully read.
        XCTAssertNil(parse([
            PushPayload.keyType: "Incoming_Call",
            PushPayload.keyWorkspaceId: "ws-1",
            PushPayload.keyCallId: "CA1",
        ]))
        XCTAssertNil(parse([
            PushPayload.keyType: "incoming_call_v2",
            PushPayload.keyWorkspaceId: "ws-1",
            PushPayload.keyCallId: "CA1",
        ]))
    }

    func testExtraKeysAreIgnoredRatherThanRejected() {
        // ⚠️ THE OPPOSITE OF THE CONTRACT FIXTURES' STRICTNESS, AND DELIBERATELY
        // SO: those pin what the server sends so drift reds CI, while the
        // SHIPPED parser must degrade to "ignored" on an already-installed build
        // rather than dropping every push after a server change.
        XCTAssertEqual(
            parse([
                PushPayload.keyType: PushPayload.typeMessage,
                PushPayload.keyWorkspaceId: "ws-1",
                PushPayload.keyMessageId: "msg-1",
                "somethingNew": "value",
            ]),
            .message(workspaceId: "ws-1", messageId: "msg-1")
        )
    }

    func testTheWireKeysAreTheServersVerbatim() {
        // ⚠️ PINNED AS LITERALS RATHER THAN REFERENCED, so a rename of a
        // constant that silently changed the wire name would red this rather
        // than pass by construction. The names are the server push sender's.
        XCTAssertEqual(PushPayload.keyType, "type")
        XCTAssertEqual(PushPayload.keyWorkspaceId, "workspaceId")
        XCTAssertEqual(PushPayload.keyMessageId, "messageId")
        XCTAssertEqual(PushPayload.keyCallId, "callId")
        XCTAssertEqual(PushPayload.typeMessage, "message")
        XCTAssertEqual(PushPayload.typeIncomingCall, "incoming_call")
    }

    // MARK: - The userInfo overload

    func testUserInfoFlattensTopLevelStringsAndIgnoresAps() {
        // ⚠️ FCM PLACES THE `data` KEYS AT THE TOP LEVEL, alongside `aps`,
        // rather than nesting them under a `data` key.
        let event = PushPayload.parse(userInfo: [
            "aps": ["alert": ["title": "District"], "sound": "default"] as [String: Any],
            PushPayload.keyType: PushPayload.typeMessage,
            PushPayload.keyWorkspaceId: "ws-1",
            PushPayload.keyMessageId: "msg-1",
        ])

        XCTAssertEqual(event, .message(workspaceId: "ws-1", messageId: "msg-1"))
    }

    func testUserInfoIgnoresNonStringValuesRatherThanCoercingThem() {
        // ⛔ A `description` OF A NON-STRING WOULD LET `1` AND `"1"` MEAN THE
        // SAME THING on a path where the ids are compared for equality. The
        // numeric callId is discarded, so the call is dropped for want of one.
        XCTAssertNil(PushPayload.parse(userInfo: [
            PushPayload.keyType: PushPayload.typeIncomingCall,
            PushPayload.keyWorkspaceId: "ws-1",
            PushPayload.keyCallId: 1 as Int,
        ]))
    }

    func testUserInfoIgnoresNonStringKeys() {
        // ⚠️ A plist dictionary may be keyed by anything hashable. A non-string
        // key cannot be one of the server's four names, so it is skipped rather
        // than stringified.
        XCTAssertEqual(
            PushPayload.parse(userInfo: [
                7 as Int: "ignored",
                PushPayload.keyType: PushPayload.typeIncomingCall,
                PushPayload.keyWorkspaceId: "ws-1",
                PushPayload.keyCallId: "CA1",
            ]),
            .incomingCall(workspaceId: "ws-1", callId: "CA1")
        )
    }

    func testAUserInfoWithNothingOfOursIsDropped() {
        XCTAssertNil(PushPayload.parse(userInfo: [
            "aps": ["content-available": 1] as [String: Any],
        ]))
    }

    // MARK: - The workspace accessor

    func testWorkspaceIdIsReadableFromEitherCase() {
        XCTAssertEqual(PushEvent.message(workspaceId: "ws-1", messageId: "m").workspaceId, "ws-1")
        XCTAssertEqual(PushEvent.incomingCall(workspaceId: "ws-2", callId: "CA1").workspaceId, "ws-2")
    }

    func testEquatableDistinguishesTheTwoCasesAndTheirIds() {
        XCTAssertEqual(
            PushEvent.message(workspaceId: "ws-1", messageId: "m"),
            .message(workspaceId: "ws-1", messageId: "m")
        )
        XCTAssertNotEqual(
            PushEvent.message(workspaceId: "ws-1", messageId: "m"),
            .message(workspaceId: "ws-1", messageId: "n")
        )
    }
}
