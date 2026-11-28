@testable import DistrictAIWatch
import Foundation
import XCTest

// The fakes the branch tests share. The older test files keep theirs private, so these carry
// their own names.

/// A phone that answers in order (the last answer repeats) and can act while a request is on
/// its way, which is how a second tap, a newer notification or a sign-out lands mid-send.
@MainActor
final class BranchLink: PhoneLinking {
    var isReachable: Bool
    private(set) var sent: [WatchAction] = []
    private(set) var activations = 0
    private(set) var onReading: (@MainActor @Sendable (WatchSnapshotReading) -> Void)?
    private(set) var onReachable: (@MainActor @Sendable () -> Void)?
    /// Runs once per send, after the answer is taken and before it is returned.
    var onSend: (@MainActor (WatchAction) async -> Void)?
    private var answers: [PhoneAnswer]

    init(reachable: Bool = true, answers: [PhoneAnswer] = [.reply(.success)]) {
        isReachable = reachable
        self.answers = answers
    }

    func activate(
        onReading: @escaping @MainActor @Sendable (WatchSnapshotReading) -> Void,
        onReachable: @escaping @MainActor @Sendable () -> Void
    ) {
        activations += 1
        self.onReading = onReading
        self.onReachable = onReachable
    }

    func send(_ request: WatchRequest) async -> PhoneAnswer {
        sent.append(request.action)
        let answer = answers.count > 1 ? answers.removeFirst() : answers[0]
        if let onSend {
            await onSend(request.action)
        }
        return answer
    }
}

@MainActor
final class BranchPersistence: SnapshotPersisting {
    var saved: [Data] = []

    func load() -> Data? {
        saved.last
    }

    func save(_ data: Data) {
        saved.append(data)
    }
}

@MainActor
final class BranchComplication: ComplicationPublishing {
    private(set) var published: [ComplicationState] = []

    func publish(_ state: ComplicationState) {
        published.append(state)
    }
}

@MainActor
final class BranchClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
}

@MainActor
final class BranchRefresh: BackgroundRefreshScheduling {
    private(set) var scheduled = 0

    func scheduleNext() {
        scheduled += 1
    }

    func unreadComplicationIsOnAFace() async -> Bool {
        true
    }
}

/// What a hook saw, for the assertion after it.
@MainActor
final class BranchProbe<Value> {
    var values: [Value] = []
}

/// Values recorded from a `@Sendable` closure, on whatever queue calls it.
final class BranchLocked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Value] = []

    var all: [Value] {
        lock.withLock { stored }
    }

    func append(_ value: Value) {
        lock.withLock { stored.append(value) }
    }
}

/// A store over a ``BranchLink``, on a clock the test moves.
@MainActor
struct BranchRig {
    let link: BranchLink
    let persistence = BranchPersistence()
    let complication = BranchComplication()
    let clock: BranchClock
    let store: WatchStore

    init(reachable: Bool = true, answers: [PhoneAnswer] = [.reply(.success)], clock: BranchClock = BranchClock()) {
        link = BranchLink(reachable: reachable, answers: answers)
        self.clock = clock
        store = WatchStore(
            link: link,
            persistence: persistence,
            complication: complication,
            clock: { clock.now }
        )
    }
}

enum BranchFixtures {
    static let call = WatchLiveCall(
        id: "call_1",
        workspaceId: "ws_1",
        caller: "Marie Tremblay",
        startedAt: nil,
        canWhisper: true
    )

    static func line(_ id: String, _ index: Int) -> WatchLiveLine {
        WatchLiveLine(id: id, epoch: 1, index: index, speaker: "Caller", fromCaller: true, text: "Line \(id)")
    }

    static func update(
        callId: String = "call_1",
        cursor: String,
        reset: Bool = false,
        lines: [WatchLiveLine] = [],
        phase: WatchLivePhase = .live
    ) -> WatchLiveUpdate {
        WatchLiveUpdate(
            callId: callId,
            cursor: cursor,
            reset: reset,
            lines: lines,
            retracted: [],
            interim: nil,
            phase: phase,
            complete: true,
            receipt: nil
        )
    }

    static func card(pending: Bool) -> WatchCallCard {
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

    /// The second conversation a newer tap names.
    static let secondConversation = WatchSnapshot.Conversation(
        id: "contact:c_2",
        workspaceId: "ws_1",
        title: "Luc Gagnon",
        preview: "↓ Bonjour",
        unread: true,
        canReply: false
    )

    static func messageTap(_ messageId: String, workspaceId: String = "ws_1") -> [String: String] {
        ["type": "message", "workspaceId": workspaceId, "messageId": messageId]
    }
}

@MainActor
func branchWait(
    _ condition: () -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    let deadline = Date().addingTimeInterval(5)
    while !condition() {
        guard Date() < deadline else { return XCTFail("timed out", file: file, line: line) }
        try? await Task.sleep(for: .milliseconds(10))
    }
}
