@testable import DistrictAIWatch
import Foundation
import XCTest

/// ``WatchLiveStore``'s branches the first file leaves: Home's poll and its end, a list kept
/// through silence, one subscription per call, the line limit, the keepalive chain stopping
/// at the end of the call, and a card whose re-ask was cancelled.
@MainActor
final class WatchLiveStoreBranchTests: XCTestCase {
    private let call = BranchFixtures.call

    // MARK: - The calls in progress

    /// Home's poll: asked at once, then every ``WatchLiveStore/listInterval``, until the wait
    /// is cancelled.
    func testThePollAsksAgainAfterEachIntervalAndStopsWhenCancelled() async {
        let link = BranchLink(answers: [.reply(.liveCalls([call]))])
        let waits = SleepScript(passes: 1)
        let live = WatchLiveStore(link: link, sleep: { try waits.sleep($0) })

        await live.pollCalls(workspaceId: "ws_1")

        XCTAssertEqual(link.sent, [.liveList(workspaceId: "ws_1"), .liveList(workspaceId: "ws_1")])
        XCTAssertEqual(waits.asked, [WatchLiveStore.listInterval, WatchLiveStore.listInterval])
        XCTAssertEqual(live.calls, [call])
    }

    /// ⚠️ SILENCE OR A PHONE GONE ON SEND SAYS NOTHING ABOUT THE CALLS: the list stays.
    func testSilenceKeepsTheList() async {
        let link = BranchLink(answers: [.reply(.liveCalls([call])), .noAnswer, .unreachable])
        let live = WatchLiveStore(link: link)

        await live.loadCalls(workspaceId: "ws_1")
        await live.loadCalls(workspaceId: "ws_1")
        await live.loadCalls(workspaceId: "ws_1")

        XCTAssertEqual(link.sent.count, 3)
        XCTAssertEqual(live.calls, [call])
        XCTAssertTrue(live.liveSupported)
    }

    /// ⛔ AN EMPTY LIST IS LIVE WITH NO CALLS, NOT AN OLDER PHONE.
    func testAnEmptyListIsSupportedAndEmpty() async {
        let live = WatchLiveStore(link: BranchLink(answers: [.reply(.liveCalls([]))]))

        await live.loadCalls(workspaceId: "ws_1")

        XCTAssertTrue(live.liveSupported)
        XCTAssertEqual(live.calls, [])
    }

    // MARK: - The transcript

    /// ⚠️ OPENING THE CALL ALREADY OPEN CHANGES NOTHING: one subscription, the lines kept.
    func testOpeningTheSameCallTwiceKeepsItsTranscript() async {
        let link = BranchLink()
        let live = WatchLiveStore(link: link, sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        live.open(call)
        await branchWait { link.sent.count == 1 }
        live.apply(BranchFixtures.update(cursor: "c1", reset: true, lines: [BranchFixtures.line("a", 0)]))

        live.open(call)

        XCTAssertEqual(live.transcript?.lines.map(\.id), ["a"])
        XCTAssertEqual(link.sent, [.liveSubscribe(workspaceId: "ws_1", callId: "call_1")])
        live.close()
    }

    /// Another call: the first is unsubscribed and forgotten, the second subscribed.
    func testOpeningAnotherCallLeavesTheFirst() async {
        let link = BranchLink()
        let live = WatchLiveStore(link: link, sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        let second = WatchLiveCall(id: "call_2", workspaceId: "ws_1", caller: "Luc", startedAt: nil, canWhisper: false)
        live.open(call)
        live.apply(BranchFixtures.update(cursor: "c1", reset: true, lines: [BranchFixtures.line("a", 0)]))

        live.open(second)

        XCTAssertEqual(live.transcript?.call, second)
        XCTAssertEqual(live.transcript?.lines, [])
        await branchWait {
            link.sent.contains(.liveUnsubscribe(workspaceId: "ws_1", callId: "call_1"))
                && link.sent.contains(.liveSubscribe(workspaceId: "ws_1", callId: "call_2"))
        }
        live.close()
    }

    /// ⚠️ A PHONE OUT OF REACH IS NOT TOLD THE SCREEN CLOSED, and nothing is held.
    func testClosingWithThePhoneAwaySendsNothing() async {
        let link = BranchLink(reachable: false)
        let live = WatchLiveStore(link: link, sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        live.open(call)
        await branchWait { live.transcript?.failure == WatchCopy.iphoneNotReachable }

        live.close()

        XCTAssertNil(live.transcript)
        XCTAssertTrue(link.sent.isEmpty)
    }

    /// Nothing open: a keepalive, a close and an update do nothing.
    func testNothingOpenAsksNothing() async {
        let link = BranchLink()
        let live = WatchLiveStore(link: link)

        await live.keepalive()
        live.close()
        live.apply(BranchFixtures.update(cursor: "c1", reset: true, lines: [BranchFixtures.line("a", 0)]))

        XCTAssertNil(live.transcript)
        XCTAssertTrue(link.sent.isEmpty)
    }

    /// ⚠️ A PHONE THAT SAYS OK WITH NO TRANSCRIPT DID NOT ANSWER the question asked.
    func testAnOkWithoutATranscriptIsDidNotAnswer() async {
        let live = WatchLiveStore(
            link: BranchLink(answers: [.reply(.success)]),
            sleep: { _ in try await Task.sleep(for: .seconds(3600)) }
        )

        live.open(call)

        await branchWait { live.transcript?.failure != nil }
        XCTAssertEqual(live.transcript?.failure, WatchCopy.iphoneDidNotAnswer)
        live.close()
    }

    /// ⛔ THE WRIST HOLDS AT MOST ``WatchLiveStore/lineLimit`` LINES, the oldest dropped first.
    func testTheOldestLinesGoPastTheLimit() {
        let live = WatchLiveStore(link: BranchLink(reachable: false))
        live.open(call)
        let lines = (0 ..< WatchLiveStore.lineLimit + 5).map { BranchFixtures.line("l\($0)", $0) }

        live.apply(BranchFixtures.update(cursor: "c1", reset: true, lines: lines))

        XCTAssertEqual(live.transcript?.lines.count, WatchLiveStore.lineLimit)
        XCTAssertEqual(live.transcript?.lines.first?.id, "l5")
        XCTAssertEqual(live.transcript?.lines.last?.id, "l\(WatchLiveStore.lineLimit + 4)")
        live.close()
    }

    /// ⛔ THE END OF THE CALL ENDS THE KEEPALIVES: subscribed, kept alive once, then told it
    /// ended, and asked nothing more.
    func testTheKeepaliveChainStopsWhenTheCallEnds() async {
        let link = BranchLink(answers: [
            .reply(.live(BranchFixtures.update(cursor: "c1", reset: true, lines: [BranchFixtures.line("a", 0)]))),
            .reply(.live(BranchFixtures.update(cursor: "c1", phase: .ended))),
        ])
        let ended = BranchProbe<String>()
        let live = WatchLiveStore(link: link, sleep: { _ in await Task.yield() })
        live.onCallEnded = { ended.values.append($0.id) }

        live.open(call)
        await branchWait { live.transcript?.phase == .ended }
        for _ in 0 ..< 20 {
            await Task.yield()
        }

        XCTAssertEqual(link.sent.count, 2)
        guard case let .liveKeepalive(_, callId, cursor, _) = link.sent.last else {
            return XCTFail("expected a keepalive, sent \(link.sent)")
        }
        XCTAssertEqual(callId, "call_1")
        XCTAssertEqual(cursor, "c1")
        XCTAssertEqual(ended.values, ["call_1"])
        XCTAssertEqual(live.transcript?.lines.map(\.id), ["a"])
    }

    // MARK: - The card

    /// ⚠️ A RE-ASK CANCELLED MID-WAIT (the card's screen closed) keeps what the phone said,
    /// still marked as asking.
    func testACancelledReAskKeepsThePendingCard() async {
        let link = BranchLink(answers: [.reply(.card(BranchFixtures.card(pending: true)))])
        let live = WatchLiveStore(link: link, sleep: { try SleepScript(passes: 0).sleep($0) })

        await live.loadCard(workspaceId: "ws_1", callId: "call_1")

        XCTAssertEqual(link.sent.count, 1)
        XCTAssertEqual(live.cards["call_1"], .card(BranchFixtures.card(pending: true), asking: true))
    }

    /// ⚠️ A CARD ALREADY HELD IS NOT BLANKED TO "loading" BY THE NEXT LOAD, nor unsaid when
    /// that load cannot reach the phone.
    func testASecondLoadKeepsTheHeldCard() async {
        let link = BranchLink(answers: [.reply(.card(BranchFixtures.card(pending: false)))])
        let live = WatchLiveStore(link: link)
        await live.loadCard(workspaceId: "ws_1", callId: "call_1")

        link.isReachable = false
        await live.loadCard(workspaceId: "ws_1", callId: "call_1")

        XCTAssertEqual(live.cards["call_1"], .card(BranchFixtures.card(pending: false), asking: false))
        XCTAssertEqual(link.sent.count, 1)
    }

    /// ⛔ A RESET FORGETS EVERY CARD AND STOPS THE KEEPALIVES.
    func testResetForgetsCardsAndTheTranscript() async {
        let link = BranchLink(answers: [.reply(.card(BranchFixtures.card(pending: false)))])
        let live = WatchLiveStore(link: link, sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        await live.loadCard(workspaceId: "ws_1", callId: "call_1")
        live.open(call)

        live.reset()

        XCTAssertEqual(live.cards, [:])
        XCTAssertNil(live.transcript)
        XCTAssertFalse(live.liveSupported)
    }
}

/// A sleep that returns `passes` times, then throws as a cancelled task's would.
private final class SleepScript: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private var waits: [Duration] = []

    init(passes: Int) {
        remaining = passes
    }

    var asked: [Duration] {
        lock.withLock { waits }
    }

    func sleep(_ duration: Duration) throws {
        let pass = lock.withLock { () -> Bool in
            waits.append(duration)
            remaining -= 1
            return remaining >= 0
        }
        guard pass else { throw CancellationError() }
    }
}
