@testable import DistrictAI
import DistrictLive
import DistrictModel
import Foundation
import XCTest

/// What the wrist is told about live calls and cards, in the phone's own words, and the
/// pieces the relay leans on: the credential cache, the reply size, the Handoff and the log.
@MainActor
final class WatchLiveComposerTests: XCTestCase {
    // MARK: - The calls in progress

    /// ⛔ ONLY A CALL IN PROGRESS IS LIVE, AND A VIEWER STEERS NOTHING.
    func testOnlyCallsInProgressAreListedAndAViewerCannotWhisper() throws {
        let rows = try [
            LiveFixtures.call(status: "in-progress", number: "+15555550100"),
            LiveFixtures.call(status: "ringing"),
            LiveFixtures.call(status: "completed"),
        ]

        let asViewer = WatchLiveComposer.liveCalls(rows, workspaceId: "ws_1", role: .viewer)
        let asClient = WatchLiveComposer.liveCalls(rows, workspaceId: "ws_1", role: .client)
        let unknown = WatchLiveComposer.liveCalls(rows, workspaceId: "ws_1", role: nil)

        XCTAssertEqual(asViewer.count, 1)
        XCTAssertEqual(asViewer.first?.caller, "••• 0100", "a number is masked on the wrist")
        XCTAssertEqual(asViewer.first?.workspaceId, "ws_1")
        XCTAssertNotNil(asViewer.first?.startedAt)
        XCTAssertEqual(asViewer.first?.canWhisper, false)
        XCTAssertEqual(asClient.first?.canWhisper, true)
        XCTAssertEqual(unknown.first?.canWhisper, false, "a role that could not be read steers nothing")
    }

    // MARK: - The card

    func testACardCarriesTheSummaryAndTheActionItems() throws {
        let row = try LiveFixtures.call(actionItems: ["Book the visit", "  "])

        let card = WatchLiveComposer.card(row, workspaceId: "ws_1", now: Date(), language: "en")

        XCTAssertEqual(card.caller, "Marie Tremblay")
        XCTAssertEqual(card.summary, "Wants a visit tomorrow.")
        XCTAssertFalse(card.summaryPending)
        XCTAssertNil(card.summaryNote)
        XCTAssertEqual(card.actionItems, ["Book the visit"])
        XCTAssertFalse(card.inProgress)
        XCTAssertTrue(card.canCallBack)
    }

    /// ⛔ A SUMMARY NOT YET WRITTEN IS ON ITS WAY; ONE THAT FAILED IS NOT, AND SAYS SO.
    func testAMissingSummaryIsPendingAndAFailedOneIsNot() throws {
        let missing = try WatchLiveComposer.card(
            LiveFixtures.call(status: "in-progress", aiSummary: "No summary available."),
            workspaceId: "ws_1",
            now: Date(),
            language: "en"
        )
        let failed = try WatchLiveComposer.card(
            LiveFixtures.call(aiSummary: "AI analysis failed to execute."),
            workspaceId: "ws_1",
            now: Date(),
            language: "en"
        )

        XCTAssertTrue(missing.summaryPending)
        XCTAssertNil(missing.summary)
        XCTAssertTrue(missing.inProgress)
        XCTAssertEqual(missing.summaryNote, CallsCopy.noAiSummaryCall)
        XCTAssertFalse(failed.summaryPending)
        XCTAssertEqual(failed.summaryNote, CallsCopy.callCouldNotSummarised)
    }

    /// ⛔ "CALL BACK" ONLY FOR AN INBOUND CALLER WITH A NUMBER: an outbound row's `from` is the
    /// workspace's own line, and a withheld caller's is a sentence.
    func testCallBackFollowsTheDiallersRule() throws {
        XCTAssertEqual(try WatchLiveComposer.callBackNumber(LiveFixtures.call()), "+15555550100")
        XCTAssertNil(try WatchLiveComposer.callBackNumber(LiveFixtures.call(direction: "outbound")))
        XCTAssertNil(try WatchLiveComposer.callBackNumber(LiveFixtures.call(from: "Inbound SIP Caller")))
        XCTAssertFalse(try WatchLiveComposer.card(
            LiveFixtures.call(direction: "outbound"),
            workspaceId: "ws_1",
            now: Date(),
            language: "en"
        ).canCallBack)
    }

    func testCardFailuresReadAsThePhoneSaysThem() {
        XCTAssertEqual(
            WatchLiveComposer.cardFailure(.http(status: 404, message: "Call not found")).sentence,
            CallsCopy.callNotAvailable
        )
        XCTAssertEqual(
            WatchLiveComposer.cardFailure(.transport("offline")).sentence,
            FailureText.from(.transport("offline")).message
        )
    }

    /// ⛔ A WHISPER AFTER THE CALL ENDED SAYS SO, and until 7.2.0 every whisper fails, plainly.
    func testWhisperFailuresReadAsTheyHappened() async {
        XCTAssertEqual(
            WatchLiveComposer.whisperFailure(.http(status: 404, message: nil, code: "call_not_found")).sentence,
            WatchBridgeCopy.whisperCallEnded
        )
        XCTAssertEqual(
            WatchLiveComposer.whisperFailure(.http(status: 400, message: nil, code: "call_not_in_progress")).sentence,
            WatchBridgeCopy.whisperCallEnded
        )
        XCTAssertEqual(
            WatchLiveComposer.whisperFailure(.transport("offline")).sentence,
            FailureText.from(.transport("offline")).message
        )
        let stub = await PendingCoreWhisper().whisper(workspaceId: "ws_1", callId: "call_1", text: "Hi")
        guard case let .failure(error) = stub else { return XCTFail("the stub must never succeed") }
        XCTAssertEqual(WatchLiveComposer.whisperFailure(error).sentence, WatchBridgeCopy.whisperUnavailable)
    }

    func testPhasesMapFromTheFeed() {
        let feed = FakeLiveFeed()
        let cases: [(LiveTranscriptPhase, WatchLivePhase)] = [
            (.subscribing, .connecting),
            (.live, .live),
            (.reconnecting, .live),
            (.ended(.callEnded), .ended),
            (.unavailable(.notLive), .unavailable),
        ]
        for (phase, expected) in cases {
            feed.phase = phase
            XCTAssertEqual(WatchLiveComposer.phase(of: feed), expected, "\(phase)")
        }
        feed.phase = .live
        feed.refuse()
        XCTAssertEqual(WatchLiveComposer.phase(of: feed), .unavailable)
    }

    // MARK: - Reply size

    /// ⛔ A REPLY ALWAYS FITS, AND THE OLDEST LINES GO FIRST.
    func testAnUpdateTooBigForAReplyLosesItsOldestLines() throws {
        let text = String(repeating: "word ", count: 400)
        let lines = (0 ..< 120).map { index in
            WatchLiveLine(id: "s\(index)", epoch: 1, index: index, speaker: "Caller", fromCaller: true, text: text)
        }
        let update = WatchLiveUpdate(
            callId: "call_1",
            cursor: "c",
            reset: true,
            lines: lines,
            retracted: [],
            interim: nil,
            phase: .live,
            complete: true
        )

        let (fitted, dropped) = update.fitted()

        XCTAssertLessThanOrEqual(try WatchWire.encoder.encode(fitted).count, WatchLiveUpdate.maximumEncodedBytes)
        XCTAssertEqual(fitted.lines.last?.id, "s119")
        XCTAssertEqual(dropped.first, "s0")
        XCTAssertEqual(dropped.count + fitted.lines.count, 120)
        XCTAssertEqual(fitted.lines.first?.text.count, WatchLiveUpdate.lineLimit + 1, "shortened, with an ellipsis")
    }

    func testACardIsTrimmedToWhatAWristReads() {
        var card = LiveFixtures.card(summary: String(repeating: "a", count: 5000))
        card.actionItems = (0 ..< 20).map { "Item \($0)" }

        let fitted = card.fitted()

        XCTAssertEqual(fitted.summary?.count, WatchCallCard.summaryLimit + 1)
        XCTAssertEqual(fitted.actionItems.count, WatchCallCard.actionItemLimit)
    }

    // MARK: - Handoff

    /// ⛔ THE ACTIVITY NAMES A CALL, AND ONLY A WHOLE ONE.
    func testTheHandoffCarriesTheCallAndNothingElse() {
        let info = CallBackHandoff.userInfo(workspaceId: "ws_1", callId: "call_1")

        XCTAssertEqual(info, ["workspaceId": "ws_1", "callId": "call_1"])
        XCTAssertEqual(CallBackHandoff.parse(info)?.callId, "call_1")
        XCTAssertEqual(CallBackHandoff.parse(info)?.workspaceId, "ws_1")
        XCTAssertNil(CallBackHandoff.parse(["workspaceId": "ws_1"]))
        XCTAssertNil(CallBackHandoff.parse(["workspaceId": " ", "callId": "call_1"]))
        XCTAssertNil(CallBackHandoff.parse(["workspaceId": "ws_1", "callId": 7]))
        XCTAssertNil(CallBackHandoff.parse(nil))
    }

    /// The dialler takes its own workspace's number once, and leaves another's alone.
    func testThePrefillIsTakenOnceByItsWorkspace() {
        let prefill = DialerPrefill()
        prefill.offer("+15555550100", workspaceId: "ws_1")

        XCTAssertNil(prefill.take(workspaceId: "ws_2"))
        XCTAssertEqual(prefill.take(workspaceId: "ws_1"), "+15555550100")
        XCTAssertNil(prefill.take(workspaceId: "ws_1"))
    }

    // MARK: - The credential cache

    /// ⛔ ONE MINT, REUSED ACROSS SHORT SOCKETS; A SECOND ASK IN ONE ACTIVATION GOES TO THE
    /// SERVER (it means the first was refused); A CREDENTIAL NEAR ITS END IS NOT REUSED.
    func testTheMinterReusesACredentialOncePerActivation() async throws {
        let clock = ManualLiveClock()
        let upstream = ScriptedMinter(clock: clock)
        let minter = CachingTelemetryMinter(upstream: upstream, clock: clock)

        await minter.beginActivation()
        _ = await minter.mintTelemetryToken(workspaceId: "ws_1")
        XCTAssertEqual(upstream.count, 1)

        await minter.beginActivation()
        let reused = try await minter.mintTelemetryToken(workspaceId: "ws_1").get()
        XCTAssertEqual(upstream.count, 1)
        XCTAssertEqual(reused.token, "a.b.c")

        _ = await minter.mintTelemetryToken(workspaceId: "ws_1")
        XCTAssertEqual(upstream.count, 2, "a second ask in one activation is a refused credential")

        clock.advance(by: 15 * 60 * 1000 - CachingTelemetryMinter.reuseMarginMilliseconds)
        await minter.beginActivation()
        _ = await minter.mintTelemetryToken(workspaceId: "ws_1")
        XCTAssertEqual(upstream.count, 3, "too close to its end to reuse")
    }

    func testAFailedMintIsNotCached() async {
        let clock = ManualLiveClock()
        let upstream = ScriptedMinter(clock: clock, scripted: [.failure(.transport("offline"))])
        let minter = CachingTelemetryMinter(upstream: upstream, clock: clock)

        await minter.beginActivation()
        _ = await minter.mintTelemetryToken(workspaceId: "ws_1")
        await minter.beginActivation()
        let second = await minter.mintTelemetryToken(workspaceId: "ws_1")

        XCTAssertEqual(upstream.count, 2)
        XCTAssertEqual(try? second.get().token, "a.b.c")
    }

    // MARK: - The diagnostics log

    /// ⛔ OFF BY DEFAULT, KEPT IN A FILE WHEN ON, AND CLEARED FOR GOOD.
    func testTheLogRecordsOnlyWhenOnAndSurvivesARelaunch() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "watch-diagnostics-\(UUID().uuidString)"))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        let log = WatchRelayDiagnostics(defaults: defaults, fileURL: file)

        log.record(.request, "ignored")
        XCTAssertTrue(log.entries.isEmpty)

        log.recording = true
        log.forceSocket = true
        log.record(.request, "liveKeepalive", at: Date(timeIntervalSince1970: 1_790_000_000))
        log.record(.reply, "took=40ms", at: Date(timeIntervalSince1970: 1_790_000_000.5))

        let relaunched = WatchRelayDiagnostics(defaults: defaults, fileURL: file)
        XCTAssertEqual(relaunched.entries.map(\.event), [.request, .reply])
        XCTAssertTrue(relaunched.recording)
        XCTAssertTrue(relaunched.forceSocket)
        XCTAssertEqual(
            relaunched.export(header: ["District AI"]),
            "District AI\n\n2026-09-21T14:13:20.000Z request liveKeepalive\n2026-09-21T14:13:20.500Z reply took=40ms\n"
        )

        relaunched.clear()
        XCTAssertTrue(relaunched.entries.isEmpty)
        XCTAssertTrue(WatchRelayDiagnostics(defaults: defaults, fileURL: file).entries.isEmpty)
    }

    func testTheLogTailsIdsAndFormatsSeconds() {
        XCTAssertEqual(WatchRelayDiagnostics.tail("cmh1abcdef123456"), "123456")
        XCTAssertEqual(WatchRelayDiagnostics.seconds(1.5), "1.500s")
    }

    /// ⛔ A DEBUG BUILD (WHICH TESTS ARE) MAY SEE THE SWITCH.
    func testTheSwitchIsAvailableInADebugBuild() async {
        let available = await WatchRelayDiagnostics.isAvailable()
        XCTAssertTrue(available)
    }
}
