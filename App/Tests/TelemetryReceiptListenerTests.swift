@testable import DistrictAI
import DistrictLive
import DistrictModel
import XCTest

/// The Watch receipt's real path (xhigh review of PR #101, items 2 and 9): its own broadcast
/// socket, open before the note goes, the call's receipt taken, anything else ignored, and a
/// bounded wait. The socket is the real adapter over a ``FakeWebSocketTask``, and the clock is
/// manual.
@MainActor
final class TelemetryReceiptListenerTests: XCTestCase {
    private let clock = ManualLiveClock()
    private let script = SocketScript()

    private func listener(callId: String = LiveFixtures.callId) -> TelemetryReceiptListener {
        TelemetryReceiptListener(
            runner: TelemetryConnectionRunner(
                workspaceId: LiveFixtures.workspaceId,
                broadcast: true,
                minter: ScriptedMinter(clock: clock),
                transport: script.transport(clock: clock),
                clock: clock,
                jitter: { 0 }
            ),
            callId: callId,
            clock: clock
        )
    }

    /// Move the manual clock in small steps until `task` is done, capped.
    private func drive<T>(_ task: Task<T, Never>, upTo limit: Int64 = 30000) async -> T {
        var moved: Int64 = 0
        let done = Done()
        let watched = Task { _ = await task.value; done.flag = true }
        while !done.flag, moved < limit {
            try? await Task.sleep(for: .milliseconds(5))
            clock.advance(by: TelemetryReceiptListener.pollMilliseconds)
            moved += TelemetryReceiptListener.pollMilliseconds
        }
        _ = await watched.value
        return await task.value
    }

    private final class Done: @unchecked Sendable {
        var flag = false
    }

    private func envelope(_ type: String, callId: String = LiveFixtures.callId, data: String) -> String {
        """
        {"workspaceId":"\(LiveFixtures.workspaceId)","callId":"\(callId)","eventType":"\(type)",\
        "data":\(data),"timestamp":"2026-11-06T04:00:00.000Z"}
        """
    }

    /// Open, and answer the transcript subscribe with a first server frame.
    private func opened() async -> (TelemetryReceiptListener, FakeWebSocketTask?) {
        let listener = listener()
        let opening = Task { await listener.open(within: 3000) }
        await waitUntil { self.script.tasks.first?.sent.contains { $0.contains("transcript.subscribe") } == true }
        script.tasks.first?.deliver(envelope("call_updated", callId: "another", data: #"{"status":"in-progress"}"#))
        _ = await drive(opening)
        return (listener, script.tasks.first)
    }

    /// ⛔ READY MEANS THE BROADCASTER IS RELAYING TO IT (max review, item 9): the first server
    /// frame after the transcript subscribe, not the handshake.
    func testOpenReturnsOnceTheFirstServerFrameArrives() async {
        let (listener, task) = await opened()
        XCTAssertTrue(listener.ready)
        XCTAssertNotNil(task)
        XCTAssertEqual(script.urls.count, 1)
    }

    /// A handshake alone is not ready: the open waits out its bound, and the note goes anyway.
    func testAHandshakeAloneIsNotReady() async {
        let listener = listener()
        let start = clock.nowMilliseconds()
        _ = await drive(Task { await listener.open(within: 3000) })
        XCTAssertFalse(listener.ready)
        XCTAssertGreaterThanOrEqual(clock.nowMilliseconds() - start, 3000)
    }

    func testTheCallsReceiptIsTaken() async {
        let (listener, task) = await opened()
        task?.deliver(envelope("whisper_applied", callId: "another", data: #"{"applied":true,"firstWords":"No."}"#))
        task?.deliver(envelope("whisper_applied", data: #"{"applied":false,"firstWords":"","reason":"transfer"}"#))

        let receipt = await drive(Task { await listener.receipt(within: 25000) })

        XCTAssertEqual(receipt, WhisperReceipt(applied: false, firstWords: "", reason: .transfer))
        XCTAssertTrue(listener.finished)
    }

    /// A receipt that lands before anyone asks for it is kept (the fast "not used" case).
    func testAReceiptThatLandsBeforeTheAskIsKept() async {
        let (listener, task) = await opened()
        task?.deliver(envelope("whisper_applied", data: #"{"applied":true,"firstWords":"Sure."}"#))
        await waitUntil { listener.found != nil }

        let receipt = await drive(Task { await listener.receipt(within: 25000) })

        XCTAssertEqual(receipt?.firstWords, "Sure.")
    }

    func testTheCallEndingEndsTheWaitWithNone() async {
        let (listener, task) = await opened()
        task?.deliver(envelope("call_ended", data: #"{"status":"completed"}"#))

        let receipt = await drive(Task { await listener.receipt(within: 25000) })

        XCTAssertNil(receipt)
    }

    /// ⛔ BOUNDED: none in time is nil, never a wait past the background budget.
    func testNoneInTimeIsNil() async {
        let (listener, _) = await opened()
        let start = clock.nowMilliseconds()

        let receipt = await drive(Task { await listener.receipt(within: 25000) }, upTo: 40000)

        XCTAssertNil(receipt)
        XCTAssertGreaterThanOrEqual(clock.nowMilliseconds() - start, 25000)
        XCTAssertLessThan(clock.nowMilliseconds() - start, 26000)
    }

    /// A cancelled wait (the note was refused) answers none at once.
    func testACancelledWaitAnswersNone() async {
        let (listener, _) = await opened()
        listener.cancel()
        let start = clock.nowMilliseconds()

        let receipt = await drive(Task { await listener.receipt(within: 25000) })

        XCTAssertNil(receipt)
        XCTAssertLessThan(clock.nowMilliseconds() - start, 1000)
    }
}
