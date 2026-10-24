@testable import DistrictAI
import DistrictLive
import DistrictModel
import Foundation
import XCTest

/// The relay's other answers: steering, the list of calls in progress, the card, and the
/// timings it logs.
@MainActor
final class WatchLiveRequestTests: XCTestCase {
    private let clock = ManualLiveClock()
    private let tasks = FakeBackgroundTasks()
    private let cursors = CursorCounter()

    private func makeRelay(
        _ sources: FakeLiveSources,
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

    // MARK: - Steering

    func testAWhisperIsSentTrimmed() async {
        let sources = FakeLiveSources()
        let relay = makeRelay(sources)

        let reply = await relay.answer(.whisper(
            workspaceId: "ws_1",
            callId: "call_1",
            text: "  Ask what the call is about.\n"
        ))

        XCTAssertEqual(reply, .success)
        XCTAssertEqual(sources.whispered, ["Ask what the call is about."])
    }

    func testAFailedWhisperCarriesItsSentence() async {
        let sources = FakeLiveSources()
        sources.whisperResult = .failure(WatchActionFailure(sentence: "The call has ended."))
        let relay = makeRelay(sources)

        let reply = await relay.answer(.whisper(workspaceId: "ws_1", callId: "call_1", text: "Hello"))

        XCTAssertEqual(reply, .failure("The call has ended."))
    }

    /// ⛔ NOTHING EMPTY AND NOTHING THE SERVER WOULD REFUSE IS SENT.
    func testABlankOrOverlongWhisperIsRefusedUnsent() async {
        let sources = FakeLiveSources()
        let relay = makeRelay(sources)

        let blank = await relay.answer(.whisper(workspaceId: "ws_1", callId: "call_1", text: " \n "))
        let long = await relay.answer(.whisper(
            workspaceId: "ws_1",
            callId: "call_1",
            text: String(repeating: "a", count: WatchLiveComposer.whisperLimit + 1)
        ))
        let atTheLimit = await relay.answer(.whisper(
            workspaceId: "ws_1",
            callId: "call_1",
            text: String(repeating: "a", count: WatchLiveComposer.whisperLimit)
        ))

        XCTAssertEqual(blank, .failure(WatchBridgeCopy.whisperEmpty))
        XCTAssertEqual(long, .failure(WatchBridgeCopy.whisperTooLong))
        XCTAssertEqual(atTheLimit, .success)
        XCTAssertEqual(sources.whispered.count, 1)
    }

    // MARK: - Lists and cards

    func testTheListAndTheCardAreTheSourcesAnswers() async {
        let sources = FakeLiveSources()
        let call = WatchLiveCall(
            id: "call_1",
            workspaceId: "ws_1",
            caller: "••• 0100",
            startedAt: nil,
            canWhisper: false
        )
        sources.liveCallsResult = .success([call])
        sources.cardResult = .success(LiveFixtures.card())
        let relay = makeRelay(sources)

        let list = await relay.answer(.liveList(workspaceId: "ws_1"))
        let card = await relay.answer(.callDetail(workspaceId: "ws_1", callId: "call_1"))

        XCTAssertEqual(list.liveCalls, [call])
        XCTAssertEqual(card.card, LiveFixtures.card())
    }

    func testAFailedCardOrListCarriesItsSentence() async {
        let sources = FakeLiveSources()
        sources.liveCallsResult = .failure(WatchActionFailure(sentence: "Offline."))
        let relay = makeRelay(sources)

        let list = await relay.answer(.liveList(workspaceId: "ws_1"))
        let card = await relay.answer(.callDetail(workspaceId: "ws_1", callId: "call_1"))

        XCTAssertEqual(list, .failure("Offline."))
        XCTAssertNil(list.liveCalls)
        XCTAssertEqual(card, .failure("No card."))
    }

    /// ⛔ TIMINGS, NEVER CONTENT: the request and the reply are logged by kind and duration.
    func testRequestsAreLoggedByKindAndDuration() async {
        let sources = FakeLiveSources()
        sources.feed.onActivate = { $0.snapshot([LiveFixtures.segment("a", index: 0, text: "My number is 555")]) }
        let diagnostics = LiveFixtures.diagnostics()
        let relay = makeRelay(sources, diagnostics: diagnostics)

        _ = await relay.answer(keepalive(nil, roundTrip: 240))

        let events = diagnostics.entries.map(\.event)
        XCTAssertEqual(events, [.request, .watchRoundTrip, .sessionStarted, .reply])
        XCTAssertTrue(diagnostics.entries[0].detail.hasPrefix("liveKeepalive call=call_1 state=background age="))
        XCTAssertEqual(diagnostics.entries[1].detail, "240ms")
        XCTAssertEqual(diagnostics.entries[3].detail, "liveKeepalive call=call_1 ok=true took=0ms")
        XCTAssertFalse(diagnostics.export(header: []).contains("555"))
    }
}

// MARK: - The bridge service hands live requests over

/// ⛔ A PHONE WITHOUT THE RELAY ANSWERS AS AN OLDER ONE DOES, and no live request builds a
/// snapshot (a keepalive every 5 s would cost four reads each).
@MainActor
final class WatchBridgeLiveRoutingTests: XCTestCase {
    func testWithoutARelayALiveRequestIsAnsweredUpdateBothApps() async throws {
        let rig = LiveServiceRig(live: nil)

        let reply = try await rig.handle(.liveList(workspaceId: "ws_1"))

        XCTAssertEqual(reply, .failure(WatchBridgeCopy.updateBothApps))
        XCTAssertEqual(rig.source.builds, 0)
        XCTAssertEqual(rig.tasks.ended, rig.tasks.begun)
    }

    func testALiveRequestGoesToTheRelayAndBuildsNoSnapshot() async throws {
        let sources = FakeLiveSources()
        let call = WatchLiveCall(id: "call_1", workspaceId: "ws_1", caller: "Marie", startedAt: nil, canWhisper: true)
        sources.liveCallsResult = .success([call])
        let rig = LiveServiceRig(live: WatchLiveRelay(
            sources: sources,
            clock: ManualLiveClock(),
            backgroundTasks: FakeBackgroundTasks(),
            diagnostics: LiveFixtures.diagnostics(),
            mode: { .snapshot },
            appState: { "active" }
        ))

        let reply = try await rig.handle(.liveList(workspaceId: "ws_1"))

        XCTAssertEqual(reply.liveCalls, [call])
        XCTAssertEqual(rig.source.builds, 0)
    }
}

@MainActor
private final class CountingSnapshotSource: WatchSnapshotSourcing {
    private(set) var builds = 0

    func snapshot(at _: Date) async -> WatchSnapshot? {
        builds += 1
        return nil
    }
}

@MainActor
private final class InstalledLink: WatchSessionLinking {
    let isCompanionInstalled = true

    func activate(
        onReady _: @escaping @MainActor @Sendable () -> Void,
        onRequest _: @escaping @MainActor @Sendable (Data, @escaping @Sendable ([String: Any]) -> Void) -> Void
    ) {}

    func publish(_: [String: Any]) throws {}
}

@MainActor
private struct NoWrites: WatchActionPerforming {
    func perform(_: WatchAction) async -> Result<Void, WatchActionFailure> {
        .success(())
    }

    func threadKey(workspaceId _: String, messageId _: String) async -> Result<String, WatchActionFailure> {
        .failure(WatchActionFailure(sentence: ""))
    }
}

private final class RepliesBox: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [WatchReply] = []

    var all: [WatchReply] {
        lock.withLock { received }
    }

    func record(_ message: [String: Any]) {
        lock.withLock { received.append(WatchReply.read(message) ?? .failure("unreadable")) }
    }
}

@MainActor
private struct LiveServiceRig {
    let source = CountingSnapshotSource()
    let tasks = FakeBackgroundTasks()
    let service: WatchBridgeService

    init(live: (any WatchLiveHandling)?) {
        service = WatchBridgeService(
            link: InstalledLink(),
            source: source,
            actions: NoWrites(),
            live: live,
            backgroundTasks: tasks
        )
    }

    func handle(_ action: WatchAction) async throws -> WatchReply {
        let box = RepliesBox()
        try await service.handle(
            requestData: WatchWire.encoder.encode(WatchRequest(action: action)),
            reply: { box.record($0) }
        )
        return try XCTUnwrap(box.all.first)
    }
}
