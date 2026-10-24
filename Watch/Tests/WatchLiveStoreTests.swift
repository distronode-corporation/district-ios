@testable import DistrictAIWatch
import XCTest

/// The wrist's live surfaces: Live hidden for an older phone, a transcript merged by cursor
/// and held in memory, an explicit failure when the phone is out of reach, steering only for
/// those who may, and a card that asks again while its summary is on its way.
@MainActor
final class WatchLiveStoreTests: XCTestCase {
    private let call = WatchLiveCall(
        id: "call_1",
        workspaceId: "ws_1",
        caller: "Marie Tremblay",
        startedAt: nil,
        canWhisper: true
    )

    // MARK: - The calls in progress

    /// ⛔ AN OLDER PHONE ANSWERS "update both apps", AND THE WATCH HIDES LIVE.
    func testAnOlderPhoneHidesLive() async {
        let link = ScriptedLink { _ in .reply(.failure("Update District AI on your iPhone and your Apple Watch.")) }
        let live = WatchLiveStore(link: link)

        await live.loadCalls(workspaceId: "ws_1")

        XCTAssertFalse(live.liveSupported)
        XCTAssertEqual(live.calls, [])
        XCTAssertEqual(link.sent, [.liveList(workspaceId: "ws_1")])
    }

    func testThePhonesListIsShownForItsWorkspace() async {
        let other = WatchLiveCall(id: "call_2", workspaceId: "ws_2", caller: "X", startedAt: nil, canWhisper: true)
        let link = ScriptedLink { [call] _ in .reply(.liveCalls([call, other])) }
        let live = WatchLiveStore(link: link)

        await live.loadCalls(workspaceId: "ws_1")

        XCTAssertTrue(live.liveSupported)
        XCTAssertEqual(live.calls, [call])
    }

    /// ⚠️ OUT OF REACH SAYS NOTHING ABOUT THE CALLS: what was shown stays, and nothing is sent.
    func testAnUnreachablePhoneLeavesTheListAlone() async {
        let link = ScriptedLink { [call] _ in .reply(.liveCalls([call])) }
        let live = WatchLiveStore(link: link)
        await live.loadCalls(workspaceId: "ws_1")
        link.isReachable = false

        await live.loadCalls(workspaceId: "ws_1")

        XCTAssertEqual(live.calls, [call])
        XCTAssertEqual(link.sent.count, 1)
    }

    // MARK: - The transcript

    /// ⛔ MERGED BY CURSOR: new lines appended in order, erased ones removed, a new cursor
    /// replaces everything.
    func testUpdatesMergeByCursor() {
        let live = WatchLiveStore(link: ScriptedLink { _ in .noAnswer })
        live.open(call)

        live.apply(update(cursor: "c1", reset: true, lines: [line("b", 1)], interim: line("x", 9)))
        live.apply(update(cursor: "c1", lines: [line("a", 0), line("c", 2), line("b", 1)]))
        XCTAssertEqual(live.transcript?.lines.map(\.id), ["a", "b", "c"])
        XCTAssertNil(live.transcript?.interim)

        live.apply(update(cursor: "c1", retracted: ["b"]))
        XCTAssertEqual(live.transcript?.lines.map(\.id), ["a", "c"])

        live.apply(update(cursor: "c2", reset: true, lines: [line("z", 0)]))
        XCTAssertEqual(live.transcript?.lines.map(\.id), ["z"])
        XCTAssertEqual(live.transcript?.cursor, "c2")

        live.apply(update(callId: "another", cursor: "c2", lines: [line("q", 5)]))
        XCTAssertEqual(live.transcript?.lines.map(\.id), ["z"], "another call's answer changes nothing")
        live.close()
    }

    /// The subscribe, then a keepalive carrying the cursor and the last round trip.
    func testTheKeepaliveCarriesTheCursorAndTheRoundTrip() async {
        let link = ScriptedLink { [self] action in
            if case .liveSubscribe = action {
                return .reply(.live(update(cursor: "c1", reset: true, lines: [line("a", 0)])))
            }
            return .reply(.live(update(cursor: "c1", lines: [line("b", 1)])))
        }
        let live = WatchLiveStore(link: link, sleep: { _ in try await Task.sleep(for: .seconds(3600)) })

        live.open(call)
        await waitFor { live.transcript?.cursor == "c1" }
        await live.keepalive()

        XCTAssertEqual(live.transcript?.lines.map(\.id), ["a", "b"])
        guard case let .liveKeepalive(_, callId, cursor, roundTrip) = link.sent.last else {
            return XCTFail("expected a keepalive, sent \(link.sent)")
        }
        XCTAssertEqual(callId, "call_1")
        XCTAssertEqual(cursor, "c1")
        XCTAssertNotNil(roundTrip)
        live.close()
    }

    /// ⛔ AN UNREACHABLE PHONE IS SAID, NEVER SHOWN AS A TRANSCRIPT THAT STOPPED.
    func testAnUnreachablePhoneIsSaid() async {
        let link = ScriptedLink { _ in .unreachable }
        let live = WatchLiveStore(link: link, sleep: { _ in try await Task.sleep(for: .seconds(3600)) })

        live.open(call)
        await waitFor { live.transcript?.failure != nil }
        XCTAssertEqual(live.transcript?.failure, WatchCopy.iphoneNotReachable)

        link.isReachable = false
        await live.keepalive()
        XCTAssertEqual(live.transcript?.failure, WatchCopy.iphoneNotReachable)
        live.close()
    }

    /// ⛔ AN OLDER PHONE'S "update both apps" IS SHOWN AS ITS SENTENCE, and a silent phone as
    /// "did not answer".
    func testARefusalOrSilenceIsSaid() async {
        let refusing = WatchLiveStore(link: ScriptedLink { _ in .reply(.failure("Update both apps.")) })
        refusing.open(call)
        await waitFor { refusing.transcript?.failure != nil }
        XCTAssertEqual(refusing.transcript?.failure, "Update both apps.")
        refusing.close()

        let silent = WatchLiveStore(link: ScriptedLink { _ in .noAnswer })
        silent.open(call)
        await waitFor { silent.transcript?.failure != nil }
        XCTAssertEqual(silent.transcript?.failure, WatchCopy.iphoneDidNotAnswer)
        silent.close()
    }

    /// ⛔ CLOSING TELLS THE PHONE AND FORGETS THE LINES.
    func testClosingUnsubscribesAndForgets() async {
        let link = ScriptedLink { _ in .reply(.success) }
        let live = WatchLiveStore(link: link)
        live.open(call)
        live.apply(update(cursor: "c1", reset: true, lines: [line("a", 0)]))

        live.close()

        XCTAssertNil(live.transcript)
        await waitFor { link.sent.contains(.liveUnsubscribe(workspaceId: "ws_1", callId: "call_1")) }
    }

    /// ⛔ A WATCHED CALL THAT ENDS BECOMES ITS CARD, IN PLACE.
    func testAnEndedCallBecomesItsCard() {
        let rig = StoreRig()
        rig.store.path = [.live(call)]
        rig.store.live.open(call)

        rig.store.live.apply(update(cursor: "c1", reset: true, phase: .ended))

        XCTAssertEqual(rig.store.path, [.callCard(workspaceId: "ws_1", callId: "call_1")])
    }

    // MARK: - The card

    /// ⛔ "SUMMARY ON ITS WAY", ASKED AGAIN AT 10, 30 AND 60 s, AND NO MORE.
    func testAPendingSummaryIsAskedForAgainThreeTimes() async {
        let pending = card(pending: true)
        let link = ScriptedLink { _ in .reply(.card(pending)) }
        let waits = WaitLog()
        let live = WatchLiveStore(link: link, sleep: { waits.record($0) })

        await live.loadCard(workspaceId: "ws_1", callId: "call_1")

        XCTAssertEqual(link.sent.count, 4)
        XCTAssertEqual(waits.all, [.seconds(10), .seconds(20), .seconds(30)])
        XCTAssertEqual(live.cards["call_1"], .card(card(pending: true), asking: false))
    }

    func testTheCardStopsAskingOnceTheSummaryArrives() async {
        let answers = AnswerQueue([.reply(.card(card(pending: true))), .reply(.card(card(pending: false)))])
        let link = ScriptedLink { _ in answers.next() }
        let live = WatchLiveStore(link: link, sleep: { _ in })

        await live.loadCard(workspaceId: "ws_1", callId: "call_1")

        XCTAssertEqual(link.sent.count, 2)
        XCTAssertEqual(live.cards["call_1"], .card(card(pending: false), asking: false))
    }

    /// ⛔ A CARD ALREADY SHOWN IS NOT UNSAID BY A RE-ASK THAT FAILED; one never shown says why.
    func testAFailedAskKeepsTheCardOrSaysWhy() async {
        let answers = AnswerQueue([.reply(.card(card(pending: true))), .unreachable])
        let live = WatchLiveStore(link: ScriptedLink { _ in answers.next() }, sleep: { _ in })
        await live.loadCard(workspaceId: "ws_1", callId: "call_1")
        XCTAssertEqual(live.cards["call_1"], .card(card(pending: true), asking: false))

        let old = WatchLiveStore(link: ScriptedLink { _ in .reply(.failure("Update both apps.")) })
        await old.loadCard(workspaceId: "ws_1", callId: "call_1")
        XCTAssertEqual(old.cards["call_1"], .failed("Update both apps."))

        let silent = WatchLiveStore(link: ScriptedLink { _ in .noAnswer })
        await silent.loadCard(workspaceId: "ws_1", callId: "call_1")
        XCTAssertEqual(silent.cards["call_1"], .failed(WatchCopy.iphoneDidNotAnswer))

        let link = ScriptedLink { _ in .noAnswer }
        link.isReachable = false
        let away = WatchLiveStore(link: link)
        await away.loadCard(workspaceId: "ws_1", callId: "call_1")
        XCTAssertEqual(away.cards["call_1"], .failed(WatchCopy.iphoneNotReachable))
        XCTAssertTrue(link.sent.isEmpty)
    }

    // MARK: - Steering

    func testAWhisperIsSentAndSaidSent() async {
        let rig = StoreRig { _ in .reply(.success) }

        await rig.store.whisper("  Ask what the call is about. ", on: call)

        XCTAssertEqual(
            rig.link.sent,
            [.whisper(workspaceId: "ws_1", callId: "call_1", text: "Ask what the call is about.")]
        )
        XCTAssertEqual(rig.store.writes[WriteKey.whisper("call_1")], .succeeded(WatchCopy.whisperSent))
    }

    /// ⛔ AN UNREACHABLE PHONE IS THE EXPLICIT FAILURE STATE, AND THE PHONE'S REFUSAL ITS SENTENCE.
    func testAWhisperThatCannotGoSaysWhy() async {
        let rig = StoreRig { _ in .reply(.failure("The call has ended.")) }
        await rig.store.whisper("Hello", on: call)
        XCTAssertEqual(
            rig.store.writes[WriteKey.whisper("call_1")],
            .failed(title: WatchCopy.whisperNotSent, reason: "The call has ended.")
        )

        rig.link.isReachable = false
        rig.store.dismissWrite(WriteKey.whisper("call_1"))
        await rig.store.whisper("Hello", on: call)
        XCTAssertEqual(rig.store.writes[WriteKey.whisper("call_1")], .unreachable)
        XCTAssertEqual(rig.link.sent.count, 1)
    }

    /// ⛔ NOTHING FOR A VIEWER, NOTHING EMPTY, NOTHING OVER THE SERVER'S LIMIT.
    func testAViewerABlankLineOrAnOverlongOneSendsNothing() async {
        let rig = StoreRig { _ in .reply(.success) }
        var viewer = call
        viewer.canWhisper = false

        await rig.store.whisper("Hello", on: viewer)
        await rig.store.whisper("   ", on: call)
        await rig.store.whisper(String(repeating: "a", count: WatchStore.whisperLimit + 1), on: call)

        XCTAssertTrue(rig.link.sent.isEmpty)
    }

    // MARK: - Notifications and sign-out

    /// A tapped call alert opens the call's card over Recent calls, in the snapshot's workspace only.
    func testATappedCallAlertOpensItsCard() async {
        let rig = StoreRig()

        await rig.store.open(["type": "incoming_call", "workspaceId": "ws_1", "callId": "call_9"])
        XCTAssertEqual(rig.store.path, [.calls, .callCard(workspaceId: "ws_1", callId: "call_9")])

        await rig.store.open(["type": "incoming_call", "workspaceId": "ws_other", "callId": "call_9"])
        XCTAssertEqual(rig.store.path, [])
    }

    /// ⛔ NOTHING OF THE LAST ACCOUNT SURVIVES A SIGN-OUT, live state included.
    func testSignOutForgetsEverythingLive() async {
        let rig = StoreRig { [call] _ in .reply(.liveCalls([call])) }
        await rig.store.live.loadCalls(workspaceId: "ws_1")
        rig.store.live.open(call)
        rig.store.live.apply(update(cursor: "c1", reset: true, lines: [line("a", 0)]))

        rig.store.apply(.snapshot(.signedOut(at: Date(), language: "en")))

        XCTAssertFalse(rig.store.live.liveSupported)
        XCTAssertEqual(rig.store.live.calls, [])
        XCTAssertNil(rig.store.live.transcript)
        XCTAssertEqual(rig.store.live.cards, [:])
    }

    // MARK: - Helpers

    private func line(_ id: String, _ index: Int) -> WatchLiveLine {
        WatchLiveLine(id: id, epoch: 1, index: index, speaker: "Caller", fromCaller: true, text: "Line \(id)")
    }

    private func update(
        callId: String = "call_1",
        cursor: String,
        reset: Bool = false,
        lines: [WatchLiveLine] = [],
        retracted: [String] = [],
        interim: WatchLiveLine? = nil,
        phase: WatchLivePhase = .live
    ) -> WatchLiveUpdate {
        WatchLiveUpdate(
            callId: callId,
            cursor: cursor,
            reset: reset,
            lines: lines,
            retracted: retracted,
            interim: interim,
            phase: phase,
            complete: true
        )
    }

    private func card(pending: Bool) -> WatchCallCard {
        WatchCallCard(
            callId: "call_1",
            workspaceId: "ws_1",
            caller: "Marie Tremblay",
            outcome: "Completed",
            time: "Oct 24",
            summary: pending ? nil : "Wants a visit.",
            summaryPending: pending,
            summaryNote: nil,
            actionItems: [],
            inProgress: false,
            canCallBack: true
        )
    }

    private func waitFor(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out", file: file, line: line) }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// A phone that answers each request with what the test says.
@MainActor
private final class ScriptedLink: PhoneLinking {
    var isReachable = true
    private(set) var sent: [WatchAction] = []
    private let answer: @MainActor (WatchAction) -> PhoneAnswer

    init(_ answer: @escaping @MainActor (WatchAction) -> PhoneAnswer) {
        self.answer = answer
    }

    func activate(
        onReading _: @escaping @MainActor @Sendable (WatchSnapshotReading) -> Void,
        onReachable _: @escaping @MainActor @Sendable () -> Void
    ) {}

    func send(_ request: WatchRequest) async -> PhoneAnswer {
        sent.append(request.action)
        return answer(request.action)
    }
}

/// Answers in order; the last repeats.
@MainActor
private final class AnswerQueue {
    private var answers: [PhoneAnswer]

    init(_ answers: [PhoneAnswer]) {
        self.answers = answers
    }

    func next() -> PhoneAnswer {
        answers.count > 1 ? answers.removeFirst() : answers[0]
    }
}

/// Every wait asked for, returning at once.
private final class WaitLog: @unchecked Sendable {
    private let lock = NSLock()
    private var waits: [Duration] = []

    var all: [Duration] {
        lock.withLock { waits }
    }

    func record(_ wait: Duration) {
        lock.withLock { waits.append(wait) }
    }
}

@MainActor
private final class NoPersistence: SnapshotPersisting {
    func load() -> Data? {
        nil
    }

    func save(_: Data) {}
}

@MainActor
private final class NoComplication: ComplicationPublishing {
    func publish(_: ComplicationState) {}
}

/// A signed-in store on workspace `ws_1`, over a scripted phone.
@MainActor
private struct StoreRig {
    let link: ScriptedLink
    let store: WatchStore

    init(_ answer: @escaping @MainActor (WatchAction) -> PhoneAnswer = { _ in .noAnswer }) {
        link = ScriptedLink(answer)
        store = WatchStore(link: link, persistence: NoPersistence(), complication: NoComplication())
        store.apply(.snapshot(WatchSnapshot(
            protocolVersion: WatchSnapshot.currentProtocolVersion,
            generatedAt: Date(),
            language: "en",
            signedIn: true,
            workspace: .init(id: "ws_1", name: "Plomberie"),
            availability: nil,
            unreadCount: nil,
            calls: [],
            conversations: []
        )))
    }
}
