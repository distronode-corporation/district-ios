@testable import DistrictAI
import DistrictCall
import DistrictLive
import DistrictModel
import Foundation
import XCTest

/// The call Live Activity's decisions (3.2): when one starts, how it moves, when it ends, and
/// that each push token reaches the server once. ActivityKit is faked behind
/// ``CallActivityHosting``, so these run on a simulator.
@MainActor
final class CallLiveActivitiesTests: XCTestCase {
    private let started = Date(timeIntervalSince1970: 1_793_000_000)
    private var host: FakeActivityHost!
    private var registrar: FakeRegistrar!
    private var clock: Date!

    override func setUp() async throws {
        host = FakeActivityHost()
        registrar = FakeRegistrar()
        clock = started
    }

    private func make() -> CallLiveActivities {
        CallLiveActivities(host: host, registrar: registrar, now: { [unowned self] in clock })
    }

    // MARK: - Starting

    func testARingStartsOneActivityRingingWithNoNameYet() throws {
        let activities = make()
        activities.rang(workspaceId: "ws_1", callId: "call_1")

        let activity = try XCTUnwrap(host.started.first)
        XCTAssertEqual(host.started.count, 1)
        XCTAssertEqual(activity.workspaceId, "ws_1")
        XCTAssertEqual(activity.callId, "call_1")
        XCTAssertEqual(host.attributes.first?.callerName, "")
        XCTAssertEqual(activity.state.phase, .ringing)
        XCTAssertEqual(activity.state.startedAt, "2026-10-26T07:33:20.000Z")
        XCTAssertEqual(activity.staleDates.last, started.addingTimeInterval(CallLiveActivities.staleAfter))
    }

    /// ⛔ NEVER TWO FOR ONE CALL, from a second ring, the call screen or the watch's list.
    func testASecondStartForTheSameCallStartsNothing() {
        let activities = make()
        activities.rang(workspaceId: "ws_1", callId: "call_1")
        activities.rang(workspaceId: "ws_1", callId: "call_1")
        activities.seenLive(workspaceId: "ws_1", callId: "call_1", callerName: "Marie", startedAt: nil)
        let listed = WatchLiveCall(id: "call_1", workspaceId: "ws_1", caller: "Marie", startedAt: nil, canWhisper: true)
        activities.observed([listed])

        XCTAssertEqual(host.started.count, 1)
        XCTAssertEqual(host.started.first?.state.phase, .aiAnswering, "seen live moves a ringing one on")
        XCTAssertEqual(host.started.first?.updates.count, 1, "and only once")
    }

    /// ⛔ AN ACTIVITY A PREVIOUS PROCESS STARTED IS ADOPTED, NOT DOUBLED, and its tokens are
    /// watched again.
    func testARunningActivityFromAnEarlierProcessIsAdopted() async {
        let survivor = FakeActivity(
            workspaceId: "ws_1",
            callId: "call_1",
            state: .init(phase: .aiAnswering, startedAt: "x")
        )
        host.alreadyRunning = [survivor]
        let activities = make()

        activities.seenLive(workspaceId: "ws_1", callId: "call_1", callerName: "Marie", startedAt: nil)
        survivor.send(Data([0xAB]))

        XCTAssertEqual(host.started.count, 0)
        XCTAssertEqual(activities.callIds, ["call_1"])
        await waitUntil { self.registrar.calls.count == 1 }
        XCTAssertEqual(registrar.calls.first?.token, "ab")
    }

    func testNothingStartsWhenLiveActivitiesAreOff() {
        host.enabled = false
        let activities = make()
        activities.rang(workspaceId: "ws_1", callId: "call_1")
        activities.seenLive(workspaceId: "ws_1", callId: "call_2", callerName: "Marie", startedAt: nil)
        XCTAssertEqual(host.started.count, 0)
        XCTAssertEqual(activities.callIds, [])
    }

    /// ⚠️ A REFUSED START (the app not in front) IS SILENT, and a later attempt may succeed.
    func testARefusedStartIsSilentAndALaterOneMayStart() {
        host.refuse = true
        let activities = make()
        activities.rang(workspaceId: "ws_1", callId: "call_1")
        XCTAssertEqual(activities.callIds, [])

        host.refuse = false
        activities.seenLive(workspaceId: "ws_1", callId: "call_1", callerName: "Marie", startedAt: started)
        XCTAssertEqual(activities.callIds, ["call_1"])
        XCTAssertEqual(host.started.first?.state.phase, .aiAnswering)
    }

    func testSeenLiveStartsAtTheCallsOwnStart() throws {
        let activities = make()
        let createdAt = started.addingTimeInterval(-90)
        activities.seenLive(workspaceId: "ws_1", callId: "call_1", callerName: "••• 0100", startedAt: createdAt)

        XCTAssertEqual(host.attributes.first?.callerName, "••• 0100")
        let state = try XCTUnwrap(host.started.first?.state)
        XCTAssertEqual(DistrictCallActivityTime.date(state.startedAt), createdAt)
    }

    // MARK: - Tokens

    /// ⛔ EACH NEW TOKEN IS SENT ONCE, AS LOWERCASE HEX; a repeat is not sent again, and a
    /// failure is not retried.
    func testEachNewTokenIsRegisteredOnceAndNeverRetried() async throws {
        registrar.result = .failure(.transport("offline"))
        let activities = make()
        activities.rang(workspaceId: "ws_1", callId: "call_1")
        let activity = try XCTUnwrap(host.started.first)

        activity.send(Data([0x0A, 0xFF]))
        activity.send(Data([0x0A, 0xFF]))
        activity.send(Data([0x01]))
        await waitUntil { self.registrar.calls.count == 2 }
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(registrar.calls.map(\.token), ["0aff", "01"])
        XCTAssertEqual(registrar.calls.map(\.callId), ["call_1", "call_1"])
        XCTAssertEqual(registrar.calls.map(\.workspaceId), ["ws_1", "ws_1"])
    }

    // MARK: - The ring

    func testTheNameArrivesAfterTheRing() {
        let activities = make()
        activities.rang(workspaceId: "ws_1", callId: "call_1")
        activities.named(callId: "call_1", callerName: "Marie Tremblay")
        activities.named(callId: "call_1", callerName: "Marie Tremblay")

        XCTAssertEqual(host.started.first?.state.callerName, "Marie Tremblay")
        XCTAssertEqual(host.started.first?.updates.count, 1, "the same name twice is one update")
    }

    func testEachRingOutcome() {
        let activities = make()
        for id in ["a", "d", "u", "w"] {
            activities.rang(workspaceId: "ws_1", callId: id)
        }
        activities.ringEnded(callId: "a", .answeredHere)
        activities.ringEnded(callId: "d", .declinedHere)
        activities.ringEnded(callId: "u", .unanswered)
        activities.ringEnded(callId: "w", .withdrawn)

        let byId = Dictionary(uniqueKeysWithValues: host.started.map { ($0.callId, $0) })
        XCTAssertEqual(byId["a"]?.ending, .immediate, "answered here: the call screen takes over")
        XCTAssertEqual(byId["d"]?.state.phase, .declined)
        XCTAssertNil(byId["d"]?.ending)
        XCTAssertEqual(byId["u"]?.state.phase, .aiAnswering)
        XCTAssertNil(byId["u"]?.ending)
        XCTAssertEqual(byId["w"]?.ending, .immediate, "nobody signed in: nothing stays")
        XCTAssertEqual(activities.callIds, ["d", "u"])
    }

    /// ⚠️ A RING ENDING UNANSWERED NEVER UNDOES A LATER PHASE.
    func testUnansweredLeavesAPhaseOtherThanRingingAlone() {
        let activities = make()
        activities.rang(workspaceId: "ws_1", callId: "call_1")
        activities.ringEnded(callId: "call_1", .declinedHere)
        activities.ringEnded(callId: "call_1", .unanswered)
        XCTAssertEqual(host.started.first?.state.phase, .declined)
        activities.ringEnded(callId: "nobody", .unanswered)
        XCTAssertEqual(host.started.count, 1)
    }

    /// ⛔ ONLY A PRESSED DECLINE IS A PERSON'S DECLINE, through the real reducer's phases.
    func testTheRingOutcomeFromTheReducer() {
        typealias Outcome = CallActivityRingOutcome
        let ended: IncomingCallPhase = .ended(.declined)
        XCTAssertEqual(CallLiveActivities.ringOutcome(.declinePressed, from: .ringing, to: ended), Outcome.declinedHere)
        XCTAssertEqual(CallLiveActivities.ringOutcome(.withdrawnLocally, from: .ringing, to: ended), Outcome.withdrawn)
        XCTAssertEqual(
            CallLiveActivities.ringOutcome(.ringTimedOut, from: .ringing, to: .ended(.ringTimedOut)),
            Outcome.unanswered
        )
        XCTAssertEqual(CallLiveActivities.ringOutcome(.answerPressed, from: .ringing, to: .answering), .answeredHere)
        XCTAssertNil(CallLiveActivities.ringOutcome(.answerPressed, from: .ringing, to: .ringing))
        XCTAssertNil(CallLiveActivities.ringOutcome(.hangUpPressed, from: .inCall, to: .ended(.hungUpLocally)))
        XCTAssertNil(CallLiveActivities.ringOutcome(.dismissed, from: .ringing, to: .idle))
    }

    func testTheModelsRingMoveReachesTheActivity() {
        var controller = IncomingCallController()
        _ = controller.handle(.ringing(workspace: WorkspaceID("ws_1"), call: CallID("call_1"), atMilliseconds: 0))
        let activities = make()
        activities.rang(workspaceId: "ws_1", callId: "call_1")

        let before = controller.state.phase
        _ = controller.handle(.declinePressed)
        activities.ring(.declinePressed, from: before, to: controller.state)

        XCTAssertEqual(host.started.first?.state.phase, .declined)
    }

    // MARK: - The transcript

    func testTheLatestFinalLineIsShownClippedAndInterimLinesNever() throws {
        let activities = make()
        activities.rang(workspaceId: "ws_1", callId: "call_1")
        let long = String(repeating: "word ", count: 40)
        activities.transcript(callId: "call_1", lines: [
            LiveFixtures.segment("s1", index: 0, speaker: .agent, text: "  Hello,\n  how can I help?  "),
            LiveFixtures.segment("s2", index: 1, final: false, text: "I would like"),
        ])
        let activity = try XCTUnwrap(host.started.first)
        XCTAssertEqual(activity.state.latestLine, "Hello, how can I help?")
        XCTAssertEqual(activity.state.latestSpeaker, .assistant)
        XCTAssertEqual(activity.state.phase, .aiAnswering, "a line means the assistant has the call")

        activities.transcript(callId: "call_1", lines: [LiveFixtures.segment("s3", index: 2, text: long)])
        let line = try XCTUnwrap(activity.state.latestLine)
        XCTAssertEqual(line.count, DistrictCallActivityLine.limit)
        XCTAssertTrue(line.hasSuffix("…"))
        XCTAssertEqual(activity.state.latestSpeaker, .caller)

        // ⚠️ THE WHOLE TRANSCRIPT ON EVERY PUBLISH, as the model sends it.
        let s3 = LiveFixtures.segment("s3", index: 2, text: long)
        let s4 = LiveFixtures.segment("s4", index: 3, final: false)
        let s5 = LiveFixtures.segment("s5", index: 4, text: "   ")
        let updates = activity.updates.count
        activities.transcript(callId: "call_1", lines: [s3])
        activities.transcript(callId: "call_1", lines: [s3, s4])
        activities.transcript(callId: "call_1", lines: [s3, s4, s5])
        XCTAssertEqual(activity.updates.count, updates, "the same line, an interim one or a blank one change nothing")
    }

    /// ⛔ A RETRACTED LINE LEAVES THE LOCK SCREEN. The transcript is published whole, so a
    /// transcript with no final line left is one whose lines were retracted.
    func testARetractionThatLeavesNoLineClearsTheExcerpt() throws {
        let activities = make()
        activities.rang(workspaceId: "ws_1", callId: "call_1")
        let activity = try XCTUnwrap(host.started.first)
        let s1 = LiveFixtures.segment("s1", index: 0, speaker: .agent, text: "Your card ends in 4242.")
        let s2 = LiveFixtures.segment("s2", index: 1, text: "Thanks.")

        activities.transcript(callId: "call_1", lines: [s1, s2])
        XCTAssertEqual(activity.state.latestLine, "Thanks.")

        activities.transcript(callId: "call_1", lines: [s1])
        XCTAssertEqual(activity.state.latestLine, "Your card ends in 4242.", "the line before it is the latest now")
        XCTAssertEqual(activity.state.latestSpeaker, .assistant)

        activities.transcript(callId: "call_1", lines: [LiveFixtures.segment("s3", index: 2, final: false)])
        XCTAssertNil(activity.state.latestLine)
        XCTAssertNil(activity.state.latestSpeaker)
        XCTAssertEqual(activity.updates.last?.latestLine, nil, "the clearing reached ActivityKit")

        let updates = activity.updates.count
        activities.transcript(callId: "call_1", lines: [])
        XCTAssertEqual(activity.updates.count, updates, "already clear: nothing to send")
    }

    /// ⚠️ A TRANSCRIPT NOT YET READ IS EMPTY BECAUSE IT IS UNREAD, NOT RETRACTED: a line the
    /// server pushed stays until this transcript has supplied one of its own.
    func testAnUnreadTranscriptLeavesAPushedLineAlone() {
        host.alreadyRunning = [FakeActivity(
            workspaceId: "ws_1",
            callId: "call_1",
            state: .init(phase: .aiAnswering, startedAt: "x", latestLine: "Pushed.", latestSpeaker: .caller)
        )]
        let activities = make()
        activities.transcript(callId: "call_1", lines: [])
        XCTAssertEqual(host.alreadyRunning.first?.state.latestLine, "Pushed.")
        XCTAssertEqual(host.alreadyRunning.first?.updates, [])
    }

    func testTheLineRules() {
        XCTAssertNil(DistrictCallActivityLine.clip(" \n\t "))
        XCTAssertEqual(DistrictCallActivityLine.clip("a  b"), "a b")
        let exact = String(repeating: "x", count: DistrictCallActivityLine.limit)
        XCTAssertEqual(DistrictCallActivityLine.clip(exact), exact)
        XCTAssertEqual(CallLiveActivities.speaker(.other("bot")), nil)
        XCTAssertEqual(CallLiveActivities.hex(Data([0, 1, 0xFE])), "0001fe")
    }

    // MARK: - Ending

    /// The call ended: the activity says so, with the end time, for a few minutes.
    func testAnEndedCallStaysForTheDismissalDelay() throws {
        let activities = make()
        activities.seenLive(workspaceId: "ws_1", callId: "call_1", callerName: "Marie", startedAt: started)
        clock = started.addingTimeInterval(300)
        activities.ended(callId: "call_1")

        let activity = try XCTUnwrap(host.started.first)
        XCTAssertEqual(activity.state.phase, .ended)
        XCTAssertEqual(DistrictCallActivityTime.date(activity.state.endedAt), clock)
        XCTAssertEqual(activity.ending, .after(clock.addingTimeInterval(CallLiveActivities.dismissalDelay)))
        XCTAssertEqual(activities.callIds, [])

        // Ended once: later signals reach nothing.
        activities.ended(callId: "call_1")
        activities.transcript(callId: "call_1", lines: [LiveFixtures.segment("s1", index: 0)])
        XCTAssertEqual(activity.endCount, 1)
    }

    /// ⚠️ A PHASE THAT SAYS HOW THE CALL ENDED IS KEPT.
    func testAnEndKeepsADeclinedPhase() {
        let activities = make()
        activities.rang(workspaceId: "ws_1", callId: "call_1")
        activities.ringEnded(callId: "call_1", .declinedHere)
        activities.ended(callId: "call_1")
        XCTAssertEqual(host.started.first?.state.phase, .declined)
    }

    /// ⛔ SIGN-OUT ENDS EVERY ACTIVITY AT ONCE, adopted ones included.
    func testSignOutEndsEverythingAtOnce() {
        let survivor = FakeActivity(
            workspaceId: "ws_9",
            callId: "old",
            state: .init(phase: .aiAnswering, startedAt: "x")
        )
        host.alreadyRunning = [survivor]
        let activities = make()
        activities.rang(workspaceId: "ws_1", callId: "call_1")
        activities.endAll()

        XCTAssertEqual(host.started.first?.ending, .immediate)
        XCTAssertEqual(survivor.ending, .immediate)
        XCTAssertEqual(activities.callIds, [])
    }

    /// ⛔ AND AN ENDED CALL STILL ON SCREEN GOES TOO. Its caller and its last line belong to
    /// the account that is leaving, so it does not wait out ``CallLiveActivities/dismissalDelay``.
    func testSignOutTakesDownAnEndedCallStillOnScreen() throws {
        let activities = make()
        activities.seenLive(workspaceId: "ws_1", callId: "call_1", callerName: "Marie", startedAt: started)
        let line = LiveFixtures.segment("s1", index: 0, text: "My account number is 1234.")
        activities.transcript(callId: "call_1", lines: [line])
        activities.ended(callId: "call_1")
        let activity = try XCTUnwrap(host.started.first)
        XCTAssertEqual(activity.ending, .after(clock.addingTimeInterval(CallLiveActivities.dismissalDelay)))

        clock = started.addingTimeInterval(60)
        activities.endAll()

        XCTAssertEqual(activity.ending, .immediate)
        XCTAssertEqual(activity.endCount, 2)
    }

    /// ⚠️ ONE ALREADY GONE IS LEFT ALONE: past its dismissal the system has removed it.
    func testSignOutLeavesAnEndedCallPastItsDismissal() throws {
        let activities = make()
        activities.seenLive(workspaceId: "ws_1", callId: "call_1", callerName: "Marie", startedAt: started)
        activities.ended(callId: "call_1")
        let activity = try XCTUnwrap(host.started.first)

        clock = started.addingTimeInterval(CallLiveActivities.dismissalDelay + 1)
        activities.endAll()

        XCTAssertEqual(activity.endCount, 1)
    }

    // MARK: - What the open app sees

    func testACallRowStartsWhenInProgressAndEndsWhenOver() throws {
        let activities = make()
        try activities.observed(LiveFixtures.call(status: "ringing"), workspaceId: "ws_1")
        XCTAssertEqual(host.started.count, 0, "ringing says nothing yet")

        try activities.observed(LiveFixtures.call(status: "in-progress"), workspaceId: "ws_1")
        XCTAssertEqual(host.attributes.first?.callerName, "Marie Tremblay")
        XCTAssertEqual(host.started.first?.state.startedAt, "2026-10-24T18:00:00.000Z")

        try activities.observed(LiveFixtures.call(status: "completed"), workspaceId: "ws_1")
        XCTAssertEqual(host.started.first?.state.phase, .ended)
    }

    /// ⛔ A BARE NUMBER IS MASKED, because the activity is on the wrist too.
    func testCallerNamesAreMaskedLikeTheWatch() throws {
        let display = try CallDisplay(LiveFixtures.call(number: "+15555550100"))
        XCTAssertEqual(CallLiveActivities.callerName(display), "••• 0100")
        let unknown = try CallDisplay(LiveFixtures.call(number: "Unknown"))
        XCTAssertEqual(CallLiveActivities.callerName(unknown), "")
    }

    func testAFeedThatEndedEndsTheActivity() {
        let activities = make()
        activities.rang(workspaceId: "ws_1", callId: "call_1")
        let feed = EndedFeed()
        activities.observed(feed, callId: "call_1")
        XCTAssertEqual(host.started.first?.state.latestLine, "Goodbye.")
        XCTAssertNotNil(host.started.first?.ending)
    }

    // MARK: - The wire shape

    /// ⛔ THE SERVER'S `content-state` DECODES, unknown values included, and encodes back to
    /// the same keys.
    func testTheContentStateWireShape() throws {
        let json = #"{"phase":"message_taken","startedAt":"2026-10-25T14:03:00.000Z","endedAt":null,"#
            + #""latestLine":"Bye.","latestSpeaker":"assistant","callerName":"Marie"}"#
        let state = try JSONDecoder().decode(DistrictCallActivityAttributes.ContentState.self, from: Data(json.utf8))
        XCTAssertEqual(state.phase, .messageTaken)
        XCTAssertEqual(state.latestSpeaker, .assistant)
        XCTAssertNil(state.endedAt)
        XCTAssertEqual(DistrictCallActivityTime.date(state.startedAt), Date(timeIntervalSince1970: 1_792_936_980))

        let odd = #"{"phase":"on_hold","startedAt":"2026-10-25T14:03:00Z","latestSpeaker":"robot"}"#
        let tolerant = try JSONDecoder().decode(DistrictCallActivityAttributes.ContentState.self, from: Data(odd.utf8))
        XCTAssertEqual(tolerant.phase, .aiAnswering)
        XCTAssertNil(tolerant.latestSpeaker)
        XCTAssertNotNil(DistrictCallActivityTime.date(tolerant.startedAt))
        XCTAssertNil(DistrictCallActivityTime.date("yesterday"))

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let back = try XCTUnwrap(String(bytes: encoder.encode(state), encoding: .utf8))
        XCTAssertEqual(
            back,
            #"{"callerName":"Marie","latestLine":"Bye.","latestSpeaker":"assistant","phase":"message_taken","#
                + #""startedAt":"2026-10-25T14:03:00.000Z"}"#
        )
        XCTAssertEqual(
            DistrictCallActivityPhase.allCases.filter(\.isOver),
            [.declined, .messageTaken, .transferred, .ended]
        )
    }
}
