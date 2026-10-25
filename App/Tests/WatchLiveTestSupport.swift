@testable import DistrictAI
import DistrictLive
import DistrictModel
import Foundation

/// A transcript feed the test drives: what a socket open brings is ``onActivate``.
@MainActor
final class FakeLiveFeed: WatchLiveTranscriptFeed {
    var lines: [TranscriptSegment] = []
    var phase: LiveTranscriptPhase = .subscribing
    var complete = true
    var connection: LiveTranscriptModel.Connection = .idle
    var fallsBack = false
    var snapshotsReceived = 0
    private(set) var activations = 0
    private(set) var deactivations = 0
    private(set) var inProgressSignals = 0
    /// Run on each activation, after the socket "opened": a snapshot, a refusal, or nothing.
    var onActivate: (@MainActor (FakeLiveFeed) -> Void)?

    func activate() {
        activations += 1
        connection = .open
        onActivate?(self)
    }

    func deactivate() {
        deactivations += 1
        if connection != .failed {
            connection = .idle
        }
    }

    func callShownInProgress() {
        inProgressSignals += 1
    }

    /// A whole snapshot landed.
    func snapshot(_ lines: [TranscriptSegment], phase: LiveTranscriptPhase = .live) {
        self.lines = lines
        self.phase = phase
        snapshotsReceived += 1
    }

    /// The server refused the socket for good.
    func refuse() {
        connection = .failed
        fallsBack = true
    }
}

/// The relay's reads and writes, answered as the test says.
@MainActor
final class FakeLiveSources: WatchLiveSourcing {
    let feed: FakeLiveFeed
    var liveCallsResult: Result<[WatchLiveCall], WatchActionFailure> = .success([])
    var cardResult: Result<WatchCallCard, WatchActionFailure> = .failure(WatchActionFailure(sentence: "No card."))
    var whisperResult: Result<Void, WatchActionFailure> = .success(())
    private(set) var whispered: [String] = []
    private(set) var feedsMade = 0
    private(set) var activationsPrepared = 0

    init(feed: FakeLiveFeed? = nil) {
        self.feed = feed ?? FakeLiveFeed()
    }

    func liveCalls(workspaceId _: String, now _: Date) async -> Result<[WatchLiveCall], WatchActionFailure> {
        liveCallsResult
    }

    func card(workspaceId _: String, callId _: String, now _: Date) async -> Result<WatchCallCard, WatchActionFailure> {
        cardResult
    }

    func whisper(workspaceId _: String, callId _: String, text: String) async -> Result<Void, WatchActionFailure> {
        whispered.append(text)
        return whisperResult
    }

    func feed(workspaceId _: String, callId _: String) -> any WatchLiveTranscriptFeed {
        feedsMade += 1
        return feed
    }

    func willActivate() async {
        activationsPrepared += 1
    }
}

/// Cursors `cursor-1`, `cursor-2`, … in order.
final class CursorCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> String {
        lock.withLock {
            count += 1
            return "cursor-\(count)"
        }
    }
}

enum LiveFixtures {
    static let workspaceId = "ws_1"
    static let callId = "call_1"

    static func segment(
        _ id: String,
        index: Int,
        final: Bool = true,
        speaker: TranscriptSpeaker = .caller,
        speakerName: String? = nil,
        text: String = "Hello."
    ) -> TranscriptSegment {
        TranscriptSegment(
            segmentId: id,
            index: index,
            epoch: 1,
            seq: index + 1,
            rev: 0,
            speaker: speaker,
            speakerName: speakerName,
            text: text,
            final: final,
            interrupted: false,
            language: "en",
            startedAt: "2026-10-24T18:00:00.000Z",
            endedAt: final ? "2026-10-24T18:00:02.000Z" : nil
        )
    }

    /// A call-log row, as the feed and the detail route answer it.
    static func call(
        status: String = "completed",
        direction: String = "inbound",
        number: String = "Marie Tremblay",
        from: String = "+15555550100",
        aiSummary: String = "Wants a visit tomorrow.",
        actionItems: [String]? = nil
    ) throws -> CallSummary {
        let analysis = actionItems.map { items in
            let list = items.map { #""\#($0)""# }.joined(separator: ",")
            return #","analysis":{"actionItems":[\#(list)]}"#
        } ?? ""
        let json = """
        {"id":"call_1","type":"\(direction)","number":"\(number)","status":"\(status)","duration":"1m 5s",\
        "time":"t","aiSummary":"\(aiSummary)","transcript":"","callerName":"","summary":"",\
        "from":"\(from)","direction":"\(direction)","durationRaw":65,\
        "createdAt":"2026-10-24T18:00:00.000Z"\(analysis)}
        """
        return try JSONDecoder().decode(CallSummary.self, from: Data(json.utf8))
    }

    static func card(pending: Bool = false, summary: String? = "Wants a visit.") -> WatchCallCard {
        WatchCallCard(
            callId: callId,
            workspaceId: workspaceId,
            caller: "Marie Tremblay",
            outcome: "Completed",
            time: "Oct 24, 2026",
            summary: summary,
            summaryPending: pending,
            summaryNote: nil,
            actionItems: [],
            inProgress: false,
            canCallBack: true
        )
    }

    /// A diagnostics log that records, in memory only, under its own defaults.
    @MainActor
    static func diagnostics() -> WatchRelayDiagnostics {
        let defaults = UserDefaults(suiteName: "watch-live-tests-\(UUID().uuidString)") ?? .standard
        let log = WatchRelayDiagnostics(defaults: defaults, fileURL: nil)
        log.recording = true
        return log
    }
}
