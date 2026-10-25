@testable import DistrictAI
import DistrictLive
import DistrictModel
import Foundation
import XCTest

/// ⛔ THE WATCH'S LIVE TRANSCRIPT, RELAYED BY THE PHONE: a snapshot per keepalive by default,
/// only what the watch has not had, and an end on its own when the call ends, the watch
/// unsubscribes, or the keepalives stop.
@MainActor
final class WatchLiveRelayTests: XCTestCase {
    private let clock = ManualLiveClock()
    private let tasks = FakeBackgroundTasks()
    private let cursors = CursorCounter()

    private func makeRelay(
        _ sources: any WatchLiveSourcing,
        mode: WatchLiveRelay.Mode = .snapshot,
        diagnostics: WatchRelayDiagnostics? = nil
    ) -> WatchLiveRelay {
        let cursors = cursors
        return WatchLiveRelay(
            sources: sources,
            clock: clock,
            backgroundTasks: tasks,
            diagnostics: diagnostics ?? LiveFixtures.diagnostics(),
            mode: { mode },
            appState: { "background" },
            makeCursor: { cursors.next() }
        )
    }

    private let subscribe = WatchAction.liveSubscribe(
        workspaceId: LiveFixtures.workspaceId,
        callId: LiveFixtures.callId
    )

    private func keepalive(_ cursor: String?, roundTrip: Int? = nil) -> WatchAction {
        .liveKeepalive(
            workspaceId: LiveFixtures.workspaceId,
            callId: LiveFixtures.callId,
            cursor: cursor,
            roundTripMilliseconds: roundTrip
        )
    }

    // MARK: - Snapshot mode (the default)

    /// ⛔ A SOCKET PER REQUEST: opened, its snapshot taken, closed, and the lines answered.
    func testSnapshotModeOpensTakesTheSnapshotAndCloses() async {
        let sources = FakeLiveSources()
        sources.feed.onActivate = { feed in
            feed.snapshot([
                LiveFixtures.segment("a", index: 0, speaker: .agent, speakerName: "Ava", text: "Good afternoon."),
                LiveFixtures.segment("b", index: 1, final: false, text: "My water…"),
            ])
        }
        let relay = makeRelay(sources)

        let reply = await relay.answer(subscribe)

        XCTAssertTrue(reply.ok)
        let update = try? XCTUnwrap(reply.live)
        XCTAssertEqual(update?.reset, true)
        XCTAssertEqual(update?.cursor, "cursor-1")
        XCTAssertEqual(update?.phase, .live)
        XCTAssertEqual(update?.lines.map(\.id), ["a"])
        XCTAssertEqual(update?.lines.first?.speaker, "Ava")
        XCTAssertEqual(update?.lines.first?.fromCaller, false)
        XCTAssertEqual(update?.interim?.id, "b")
        XCTAssertEqual(sources.feed.activations, 1)
        XCTAssertEqual(sources.feed.deactivations, 1)
        XCTAssertEqual(sources.activationsPrepared, 1)
        XCTAssertNotNil(relay.session)
        // ⚠️ No background task of its own in this mode: the request's lease covers it.
        XCTAssertTrue(tasks.begun.isEmpty)
    }

    /// ⛔ ONLY WHAT IS NEW, AGAINST THE CURSOR: a line already sent is not sent again, a line
    /// finalised late (a lower index) still arrives, and an erased line is named.
    func testSnapshotModeCursoringSendsOnlyWhatIsNew() async {
        let sources = FakeLiveSources()
        let lineA = LiveFixtures.segment("a", index: 1)
        sources.feed.onActivate = { $0.snapshot([lineA]) }
        let relay = makeRelay(sources)
        _ = await relay.answer(subscribe)

        let early = LiveFixtures.segment("early", index: 0)
        let lineB = LiveFixtures.segment("b", index: 2)
        sources.feed.onActivate = { $0.snapshot([early, lineA, lineB]) }
        let second = await relay.answer(keepalive("cursor-1", roundTrip: 180))

        XCTAssertEqual(second.live?.reset, false)
        XCTAssertEqual(second.live?.cursor, "cursor-1")
        XCTAssertEqual(second.live?.lines.map(\.id), ["early", "b"])
        XCTAssertEqual(second.live?.retracted, [])

        sources.feed.onActivate = { $0.snapshot([early, lineB]) }
        let third = await relay.answer(keepalive("cursor-1"))

        XCTAssertEqual(third.live?.lines, [])
        XCTAssertEqual(third.live?.retracted, ["a"])
        XCTAssertEqual(sources.feedsMade, 1)
        XCTAssertEqual(sources.feed.activations, 3)
        XCTAssertEqual(sources.feed.deactivations, 3)
    }

    /// A cursor the relay does not hold (it ended, or the phone relaunched) starts over: a new
    /// cursor, `reset`, and every line again.
    func testAStaleCursorStartsOverWithEverything() async {
        let sources = FakeLiveSources()
        sources.feed.onActivate = { $0.snapshot([LiveFixtures.segment("a", index: 0)]) }
        let relay = makeRelay(sources)
        _ = await relay.answer(subscribe)

        let reply = await relay.answer(keepalive("from-before-a-relaunch"))

        XCTAssertEqual(reply.live?.reset, true)
        XCTAssertEqual(reply.live?.cursor, "cursor-2")
        XCTAssertEqual(reply.live?.lines.map(\.id), ["a"])
    }

    /// ⛔ THE CALL'S END ENDS THE RELAY, and the watch is told so it can show the card.
    func testTheCallEndingEndsTheRelay() async {
        let sources = FakeLiveSources()
        sources.feed.onActivate = { $0.snapshot([LiveFixtures.segment("a", index: 0)], phase: .ended(.callEnded)) }
        let diagnostics = LiveFixtures.diagnostics()
        let relay = makeRelay(sources, diagnostics: diagnostics)

        let reply = await relay.answer(subscribe)

        XCTAssertEqual(reply.live?.phase, .ended)
        XCTAssertNil(relay.session)
        XCTAssertTrue(diagnostics.entries.contains { $0.event == .sessionEnded && $0.detail.contains("call ended") })
    }

    /// ⛔ NO KEEPALIVE FOR 20 s AND THE RELAY STOPS: a watch that walked away sends no
    /// unsubscribe.
    func testTwentySecondsWithoutAKeepaliveEndsTheRelay() async {
        let sources = FakeLiveSources()
        sources.feed.onActivate = { $0.snapshot([]) }
        let diagnostics = LiveFixtures.diagnostics()
        let relay = makeRelay(sources, diagnostics: diagnostics)
        _ = await relay.answer(subscribe)
        await waitUntilAsleep(clock, count: 1)

        clock.advance(by: WatchLiveRelay.keepaliveTimeoutMilliseconds - 1)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertNotNil(relay.session)

        clock.advance(by: 1)
        await waitUntil(state: "session=\(String(describing: relay.session))") { relay.session == nil }
        XCTAssertTrue(diagnostics.entries.contains { $0.event == .sessionEnded && $0.detail.contains("no keepalive") })
    }

    /// A keepalive pushes the timeout back.
    func testAKeepaliveRestartsTheTimeout() async {
        let sources = FakeLiveSources()
        sources.feed.onActivate = { $0.snapshot([]) }
        let relay = makeRelay(sources)
        _ = await relay.answer(subscribe)
        await waitUntilAsleep(clock, count: 1)
        clock.advance(by: 15000)

        _ = await relay.answer(keepalive("cursor-1"))
        await waitUntilAsleep(clock, count: 1)
        clock.advance(by: 15000)
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(relay.session?.cursor, "cursor-1")
    }

    /// ⛔ A REFUSED SOCKET IS SAID: the watch shows "no live transcript", not silence.
    func testARefusedSocketAnswersUnavailable() async {
        let sources = FakeLiveSources()
        sources.feed.onActivate = { $0.refuse() }
        let relay = makeRelay(sources)

        let reply = await relay.answer(subscribe)

        XCTAssertEqual(reply.live?.phase, .unavailable)
        XCTAssertNotNil(relay.session, "kept: the watch keeps asking while it shows the call")
    }

    /// ⚠️ `not_live` IS FINAL FOR ITS SUBSCRIBE, so the next keepalive is the call-status signal
    /// that asks again.
    func testNotLiveAsksAgainOnTheNextKeepalive() async {
        let sources = FakeLiveSources()
        sources.feed.onActivate = { feed in
            feed.phase = .unavailable(.notLive)
            feed.fallsBack = true
        }
        let relay = makeRelay(sources)
        _ = await relay.answer(subscribe)
        XCTAssertEqual(sources.feed.inProgressSignals, 0)

        _ = await relay.answer(keepalive("cursor-1"))

        XCTAssertEqual(sources.feed.inProgressSignals, 1)
    }

    /// A snapshot that does not come in time: the answer says so (connecting) rather than wait.
    func testASnapshotThatDoesNotComeIsAnsweredAfterTheWait() async {
        let sources = FakeLiveSources()
        let relay = makeRelay(sources)
        let holder = ReplyHolder()

        let task = Task { holder.reply = await relay.answer(subscribe) }
        // The watchdog and the poll.
        await waitUntilAsleep(clock, count: 2)
        clock.advance(by: WatchLiveRelay.snapshotWaitMilliseconds)
        await task.value

        XCTAssertEqual(holder.reply?.live?.phase, .connecting)
        XCTAssertEqual(holder.reply?.live?.lines, [])
        XCTAssertEqual(sources.feed.deactivations, 1)
    }

    /// The watch closed the screen: the relay stops at once.
    func testUnsubscribeEndsTheRelay() async {
        let sources = FakeLiveSources()
        sources.feed.onActivate = { $0.snapshot([]) }
        let relay = makeRelay(sources)
        _ = await relay.answer(subscribe)

        let reply = await relay.answer(.liveUnsubscribe(
            workspaceId: LiveFixtures.workspaceId,
            callId: LiveFixtures.callId
        ))

        XCTAssertTrue(reply.ok)
        XCTAssertNil(relay.session)
    }

    // MARK: - Socket mode (the spike's)

    /// The socket is held, under a background task, while keepalives arrive; the answers come
    /// from what it holds.
    func testSocketModeHoldsTheSocketBetweenKeepalives() async {
        let sources = FakeLiveSources()
        sources.feed.onActivate = { $0.snapshot([LiveFixtures.segment("a", index: 0)]) }
        let diagnostics = LiveFixtures.diagnostics()
        let relay = makeRelay(sources, mode: .socket, diagnostics: diagnostics)

        _ = await relay.answer(subscribe)
        sources.feed.lines.append(LiveFixtures.segment("b", index: 1))
        let reply = await relay.answer(keepalive("cursor-1"))

        XCTAssertEqual(reply.live?.lines.map(\.id), ["b"])
        XCTAssertEqual(sources.feed.activations, 1)
        XCTAssertEqual(sources.feed.deactivations, 0)
        XCTAssertEqual(tasks.begun.count, 1)
        XCTAssertTrue(diagnostics.entries.contains { $0.event == .socketOpened })

        _ = await relay.answer(.liveUnsubscribe(workspaceId: LiveFixtures.workspaceId, callId: LiveFixtures.callId))

        XCTAssertEqual(sources.feed.deactivations, 1)
        XCTAssertEqual(tasks.ended, tasks.begun)
    }

    /// ⛔ THE BACKGROUND TIME RUNNING OUT ENDS THE SOCKET, and the log says when.
    func testSocketModeEndsWhenTheBackgroundTimeExpires() async {
        let sources = FakeLiveSources()
        sources.feed.onActivate = { $0.snapshot([]) }
        let diagnostics = LiveFixtures.diagnostics()
        let relay = makeRelay(sources, mode: .socket, diagnostics: diagnostics)
        _ = await relay.answer(subscribe)

        tasks.expireAll()

        XCTAssertNil(relay.session)
        XCTAssertEqual(sources.feed.deactivations, 1)
        XCTAssertEqual(tasks.ended, tasks.begun)
        XCTAssertTrue(diagnostics.entries.contains { $0.event == .backgroundExpired })
    }

    /// The W0 measure: a held socket found closed is logged with how long it lived.
    func testSocketModeLogsADroppedSocket() async {
        let sources = FakeLiveSources()
        sources.feed.onActivate = { $0.snapshot([]) }
        let diagnostics = LiveFixtures.diagnostics()
        let relay = makeRelay(sources, mode: .socket, diagnostics: diagnostics)
        _ = await relay.answer(subscribe)
        await waitUntilAsleep(clock, count: 1)
        clock.advance(by: 4000)
        sources.feed.connection = .connecting

        let task = Task { _ = await relay.answer(keepalive("cursor-1")) }
        await waitUntilAsleep(clock, count: 2)
        clock.advance(by: WatchLiveRelay.snapshotWaitMilliseconds)
        await task.value

        let dropped = diagnostics.entries.first { $0.event == .socketDropped }
        XCTAssertEqual(dropped?.detail, "lived=7500ms state=background")
    }

    // MARK: - End to end, on the real model and socket adapter

    /// ⛔ THE CALL SCREEN'S OWN MODEL, OVER THE REAL ADAPTER: the relay opens a socket, the
    /// subscribe's snapshot answers it, and the socket is closed again.
    func testSnapshotModeOnTheRealModel() async throws {
        let script = SocketScript()
        let minter = ScriptedMinter(clock: clock)
        let model = LiveTranscriptModel(
            workspaceId: TranscriptWire.workspaceId,
            callId: TranscriptWire.callId,
            dependencies: LiveTranscriptModel.Dependencies(
                minter: minter,
                transport: script.transport(clock: clock),
                clock: clock,
                jitter: { 0 },
                fetchTranscript: { .success("") }
            )
        )
        let relay = makeRelay(ModelSources(model: model))
        let holder = ReplyHolder()

        let task = Task {
            holder.reply = await relay.answer(.liveSubscribe(workspaceId: "ws_1", callId: TranscriptWire.callId))
        }
        await waitUntil(state: "sockets=\(script.tasks.count)") { script.tasks.first?.sent.count == 2 }
        script.tasks.first?.deliver(TranscriptWire.snapshot([TranscriptWire.greeting], lastSeq: 1))
        await waitUntil(state: "snapshots=\(model.snapshotsReceived)") { model.snapshotsReceived == 1 }
        // The relay's poll is asleep on the manual clock: one step wakes it to the snapshot.
        clock.advance(by: WatchLiveRelay.pollMilliseconds)
        await task.value

        let update = try XCTUnwrap(holder.reply?.live)
        XCTAssertEqual(update.lines.map(\.text), ["Good afternoon."])
        XCTAssertEqual(update.lines.first?.speaker, "Ava")
        XCTAssertEqual(update.phase, .live)
        XCTAssertEqual(model.snapshotsReceived, 1)
        await waitUntil(state: "closed=\(script.tasks.first?.cancelCodes ?? [])") {
            script.tasks.first?.cancelCodes.isEmpty == false
        }
        XCTAssertEqual(minter.count, 1)
    }
}

// MARK: - Helpers

@MainActor
final class ReplyHolder {
    var reply: WatchReply?
}

/// The real model as the relay's feed.
@MainActor
private final class ModelSources: WatchLiveSourcing {
    let model: LiveTranscriptModel

    init(model: LiveTranscriptModel) {
        self.model = model
    }

    func liveCalls(workspaceId _: String, now _: Date) async -> Result<[WatchLiveCall], WatchActionFailure> {
        .success([])
    }

    func card(workspaceId _: String, callId _: String, now _: Date) async -> Result<WatchCallCard, WatchActionFailure> {
        .failure(WatchActionFailure(sentence: ""))
    }

    func whisper(workspaceId _: String, callId _: String, text _: String) async -> Result<Void, WatchActionFailure> {
        .success(())
    }

    func feed(workspaceId _: String, callId _: String) -> any WatchLiveTranscriptFeed {
        model
    }

    func willActivate() async {}
}
