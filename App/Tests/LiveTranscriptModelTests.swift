@testable import DistrictAI
import DistrictLive
import DistrictModel
import XCTest

/// ⛔ THE CALL SCREEN'S LIVE TRANSCRIPT, END TO END ON THE REAL CORE AND THE REAL ADAPTER.
///
/// `TelemetryConnectionRunner` and `TranscriptReducer` are district-core-swift's and tested
/// there; what is this app's is the socket adapter (`URLSessionTelemetrySocket`, over a fake
/// task here), the model that opens and closes a socket for the screen, and the wiring
/// between them. Every socket below is the real adapter over a ``FakeWebSocketTask``, and the
/// clock is manual, so a fifteen-minute renewal takes no time.
@MainActor
final class LiveTranscriptModelTests: XCTestCase {
    private let clock = ManualLiveClock()
    private let script = SocketScript()

    private func makeModel(
        minter: ScriptedMinter? = nil,
        transcripts: ScriptedTranscripts = ScriptedTranscripts([.success("")])
    ) -> LiveTranscriptModel {
        LiveTranscriptModel(
            workspaceId: TranscriptWire.workspaceId,
            callId: TranscriptWire.callId,
            dependencies: LiveTranscriptModel.Dependencies(
                minter: minter ?? ScriptedMinter(clock: clock),
                transport: script.transport(clock: clock),
                clock: clock,
                jitter: { 0 },
                fetchTranscript: { transcripts.next() }
            )
        )
    }

    /// Activate, and wait for the socket to be open with its two ops sent.
    private func open(_ model: LiveTranscriptModel) async -> FakeWebSocketTask? {
        model.activate()
        await waitUntil(state: "sockets=\(script.tasks.count)") {
            self.script.tasks.first?.sent.count == 2 && model.connection == .open
        }
        return script.tasks.first
    }

    /// Move the manual clock forward in `step`s until `condition` holds, giving the tasks
    /// woken by each step a moment to run. ⚠️ Steps, not one jump: a wait that starts after a
    /// jump would be timed from after it and never come due.
    private func advance(
        by step: Int64,
        upTo limit: Int64,
        file: StaticString = #filePath,
        line: UInt = #line,
        until condition: () -> Bool
    ) async {
        var moved: Int64 = 0
        while !condition(), moved < limit {
            clock.advance(by: step)
            moved += step
            try? await Task.sleep(for: .milliseconds(5))
        }
        await waitUntil(timeout: 2, file: file, line: line, condition)
    }

    // MARK: - The socket

    /// ⛔ THE HANDSHAKE AND THE FIRST TWO FRAMES: the version first and the credential second
    /// in `Sec-WebSocket-Protocol`, the workspace in the URL, then `socket.mode` (this socket
    /// wants no workspace relay) and the subscribe, in that order.
    func test_IOS_LIVE_01_activateOffersTheSubprotocolsThenSendsTheModeAndTheSubscribe() async {
        let model = makeModel()
        let task = await open(model)

        XCTAssertEqual(script.protocols, [["distronode.telemetry.v1", "distronode.token.a.b.c"]])
        XCTAssertEqual(script.urls.first?.absoluteString, "wss://telemetry.example.test/ws/telemetry?workspaceId=ws_1")
        XCTAssertEqual(task?.sent, [TranscriptWire.mode, TranscriptWire.subscribe])
        model.deactivate()
    }

    /// ⛔ A SUBSCRIPTION IS PER SOCKET: the socket that replaces the old one a minute before
    /// its credential expires is subscribed again, on a fresh credential.
    func test_IOS_LIVE_02_theRenewalsSocketIsSubscribedAgain() async {
        let minter = ScriptedMinter(clock: clock)
        let model = makeModel(minter: minter)
        let first = await open(model)

        await advance(by: 10000, upTo: 15 * 60 * 1000) {
            self.script.tasks.count == 2 && self.script.tasks[1].sent.count == 2
        }

        XCTAssertEqual(first?.cancelCodes.first, .normalClosure, "the old socket is closed")
        XCTAssertEqual(minter.count, 2, "on a fresh credential")
        XCTAssertEqual(script.tasks.last?.sent, [TranscriptWire.mode, TranscriptWire.subscribe])
        model.deactivate()
    }

    /// ⛔ 4401: MINT AGAIN, REOPEN, SUBSCRIBE AGAIN.
    func test_IOS_LIVE_03_a4401MintsAgainAndSubscribesAgain() async {
        let minter = ScriptedMinter(clock: clock)
        let model = makeModel(minter: minter)
        let first = await open(model)

        first?.serverClosed(code: 4401, reason: "Session expired")
        await advance(by: 250, upTo: 5000) {
            self.script.tasks.count == 2 && self.script.tasks[1].sent.count == 2
        }

        XCTAssertEqual(minter.count, 2)
        XCTAssertEqual(script.tasks.last?.sent, [TranscriptWire.mode, TranscriptWire.subscribe])
        XCTAssertFalse(model.fallsBack)
        model.deactivate()
    }

    /// ⛔ 4403: THE MEMBER MAY NOT WATCH THIS WORKSPACE. A new credential changes nothing, so
    /// nothing reconnects, and the screen falls back to the transcript after the call.
    func test_IOS_LIVE_04_a4403StopsAndFallsBack() async {
        let model = makeModel()
        let first = await open(model)

        first?.serverClosed(code: 4403, reason: "Access denied to workspace")
        await waitUntil { model.connection == .failed }
        for _ in 0 ..< 12 {
            clock.advance(by: 10000)
            try? await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertTrue(model.fallsBack)
        XCTAssertEqual(script.tasks.count, 1, "nothing reconnects after 4403")
    }

    /// Any other close (1011, a server restart): back off, then reopen on the same credential
    /// and subscribe again.
    func test_IOS_LIVE_05_anyOtherCloseBacksOffThenSubscribesAgain() async {
        let minter = ScriptedMinter(clock: clock)
        let model = makeModel(minter: minter)
        let first = await open(model)

        first?.serverClosed(code: 1011, reason: "restart")
        await waitUntil { model.connection == .connecting }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(script.tasks.count, 1, "not before the backoff")
        await advance(by: 250, upTo: 5000) {
            self.script.tasks.count == 2 && self.script.tasks[1].sent.count == 2
        }

        XCTAssertEqual(minter.count, 1, "the credential still had time, so it is reused")
        XCTAssertEqual(script.tasks.last?.sent, [TranscriptWire.mode, TranscriptWire.subscribe])
        model.deactivate()
    }

    // MARK: - The transcript

    /// The snapshot, then a live line; ⛔ D3's note when the snapshot does not reach back to
    /// the first line.
    func test_IOS_LIVE_06_framesBecomeLinesAndAnIncompleteSnapshotSaysSo() async {
        let model = makeModel()
        let task = await open(model)
        let greeting = TranscriptWire.segment("item_a1", index: 0, seq: 1, speaker: "agent", text: "Good afternoon.")
        let booking = TranscriptWire.segment("item_b2", index: 1, seq: 2, text: "A cleaning, please.")

        task?.deliver(TranscriptWire.snapshot([greeting, booking], lastSeq: 2, complete: false))
        await waitUntil { model.lines.count == 2 }
        XCTAssertFalse(model.complete)
        XCTAssertEqual(model.phase, .live)
        XCTAssertEqual(LiveTranscriptCopy.status(phase: model.phase, connection: model.connection), "Live")
        XCTAssertEqual(model.lines.map(LiveTranscriptCopy.speaker), ["Ava", "Caller"])

        let cut = TranscriptWire.segment(
            "item_c3",
            index: 2,
            seq: 3,
            speaker: "agent",
            text: "Of course",
            interrupted: true
        )
        task?.deliver(TranscriptWire.live(cut))
        await waitUntil { model.lines.count == 3 }
        XCTAssertTrue(model.lines[2].interrupted)
        model.deactivate()
    }

    /// ⛔ THE END: THE FULL TRANSCRIPT IS FETCHED, AND FETCHED AGAIN WHILE IT IS STILL EMPTY
    /// (it is written only after the call's session closes). Once it is in, the socket is
    /// closed, which ends its subscription on the server.
    func test_IOS_LIVE_07_theEndFetchesTheFullTranscriptUntilItIsWritten() async {
        let transcripts = ScriptedTranscripts([.success(""), .success("Ava: Good afternoon.")])
        let model = makeModel(transcripts: transcripts)
        let task = await open(model)
        task?.deliver(TranscriptWire.snapshot([], lastSeq: 0))
        await waitUntil { model.phase == .live }

        task?.deliver(TranscriptWire.ended(seq: 1))
        await waitUntil { model.phase == .ended(.callEnded) }
        XCTAssertEqual(LiveTranscriptCopy.status(phase: model.phase, connection: model.connection), "Call ended")
        XCTAssertEqual(model.finalTranscript, .fetching(attempt: 1))
        await advance(by: 500, upTo: 10000) { model.finalTranscript == .loaded("Ava: Good afternoon.") }

        XCTAssertEqual(transcripts.count, 2, "an empty answer is asked again")
        await waitUntil { task?.cancelCodes.first == .normalClosure }
        model.activate()
        XCTAssertEqual(script.tasks.count, 1, "a finished transcript opens no socket")
    }

    /// ⛔ `not_live`: THE SERVER HAS NO LIVE TRANSCRIPT FOR THE CALL, so the screen offers the
    /// transcript after the call and the socket is let go.
    func test_IOS_LIVE_08_notLiveFallsBackAndClosesTheSocket() async {
        let model = makeModel()
        let task = await open(model)

        task?.deliver(TranscriptWire.error("not_live"))
        await waitUntil { model.fallsBack }

        await waitUntil { task?.cancelCodes.first == .normalClosure }
    }

    // MARK: - The screen's lifecycle

    /// ⛔ THE BACKGROUND CLOSES THE SOCKET AND THE FOREGROUND OPENS A NEW ONE, subscribed
    /// again; the lines stay on screen in between.
    func test_IOS_LIVE_09_backgroundClosesTheSocketAndActiveOpensANewOne() async {
        let model = makeModel()
        let first = await open(model)
        first?.deliver(TranscriptWire.snapshot(
            [TranscriptWire.segment("item_a1", index: 0, seq: 1, text: "Hello")],
            lastSeq: 1
        ))
        await waitUntil { model.lines.count == 1 }

        model.deactivate()
        await waitUntil { first?.cancelCodes.first == .normalClosure }
        XCTAssertEqual(model.connection, .idle)
        XCTAssertEqual(model.lines.count, 1, "the screen keeps its lines")

        model.activate()
        await waitUntil { self.script.tasks.count == 2 && self.script.tasks[1].sent.count == 2 }
        XCTAssertEqual(script.tasks[1].sent, [TranscriptWire.mode, TranscriptWire.subscribe])
        model.activate()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(script.tasks.count, 2, "activating twice opens one socket")
        model.deactivate()
    }

    // MARK: - The pieces around it

    /// ⛔ THE REAL `URLSessionWebSocketTask` CARRIES THE OFFER AS ONE HEADER, IN ORDER: the
    /// version first, so a server that selects the first offer never echoes the credential.
    func test_IOS_LIVE_10_urlSessionPutsTheSubprotocolsInOneHeaderInOrder() throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = try XCTUnwrap(URL(string: "wss://telemetry.example.test/ws/telemetry?workspaceId=ws_1"))

        let task = session.webSocketTask(with: url, protocols: TelemetryProtocol.offeredSubprotocols(token: "a.b.c"))

        XCTAssertEqual(
            task.originalRequest?.value(forHTTPHeaderField: "Sec-WebSocket-Protocol"),
            "distronode.telemetry.v1, distronode.token.a.b.c"
        )
        // ⚠️ URLSession keeps the request as `https`; what matters is that the URL carries the
        // workspace and not the credential.
        XCTAssertEqual(task.originalRequest?.url?.query, "workspaceId=ws_1")
        XCTAssertFalse(task.originalRequest?.url?.absoluteString.contains("a.b.c") ?? true)
    }

    func test_IOS_LIVE_11_theSpeakerIsWordedFromItsRole() {
        func line(_ speaker: TranscriptSpeaker, _ name: String?) -> TranscriptSegment {
            TranscriptSegment(
                segmentId: "s", index: 0, epoch: 1, seq: 1, rev: 0, speaker: speaker, speakerName: name, text: "x",
                final: true, interrupted: false, language: nil, startedAt: "t", endedAt: nil
            )
        }
        XCTAssertEqual(LiveTranscriptCopy.speaker(line(.caller, nil)), "Caller")
        XCTAssertEqual(LiveTranscriptCopy.speaker(line(.agent, "Ava")), "Ava")
        XCTAssertEqual(LiveTranscriptCopy.speaker(line(.agent, nil)), "Assistant")
        XCTAssertEqual(LiveTranscriptCopy.speaker(line(.agent, "")), "Assistant")
        XCTAssertEqual(LiveTranscriptCopy.speaker(line(.other("supervisor"), nil)), "Other speaker")
        XCTAssertEqual(LiveTranscriptCopy.status(phase: .subscribing, connection: .connecting), "Connecting…")
        XCTAssertEqual(LiveTranscriptCopy.status(phase: .live, connection: .connecting), "Connecting…")
    }

    /// Only a call in progress is watched live: not a ringing one (nothing said yet) and not
    /// a finished one.
    func test_IOS_LIVE_12_onlyACallInProgressIsWatchedLive() throws {
        func call(_ status: String) throws -> CallSummary {
            try JSONDecoder().decode(CallSummary.self, from: Data("""
            {"id":"call_1","type":"inbound","number":"+15555550100","status":"\(status)","duration":"0s",\
            "time":"t","aiSummary":"s","transcript":"","callerName":"","summary":"",\
            "createdAt":"2026-10-06T14:30:00.000Z"}
            """.utf8))
        }
        XCTAssertTrue(try CallDisplay(call("in-progress")).transcribesLive)
        XCTAssertFalse(try CallDisplay(call("ringing")).transcribesLive)
        XCTAssertFalse(try CallDisplay(call("completed")).transcribesLive)
    }
}
