@testable import DistrictAI
import DistrictModel
import XCTest

/// ``ContainerWatchLiveSources`` over a real signed-in container answering from the service's
/// recorded responses: the live list, the call card, the whisper's error mapping and the
/// transcript feed it hands the Watch. ⚠️ `listenForReceipt` opens a real socket and is not
/// exercised here.
final class WatchLiveSourcesPlatformMarginTests: ScreenSnapshotTestCase {
    private static let workspaceId = "ws-contract-viewer"
    private static let callId = "call_contract_answered"
    private static let detail = "/api/district/calls/\(callId)"
    private static let refused = FixtureTransport.Reply.json(#"{"error":"Internal error"}"#, status: 500)
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        try await super.setUp()
        WorkspaceSelectionStore().setSelectedWorkspaceId(nil)
    }

    private func makeSources(
        _ replies: [String: FixtureTransport.Reply] = [:],
        whisper: RecordingWhisperSender = RecordingWhisperSender(.success(()))
    ) async throws -> (ContainerWatchLiveSources, AppContainer) {
        let container = try await container(FixtureTransport(replies))
        return (ContainerWatchLiveSources(container: container, whisper: whisper), container)
    }

    // MARK: - The live list

    /// ⛔ The recorded log holds only finished, missed and busy calls: nothing is live.
    func testARecordedLogOfFinishedCallsIsAnEmptyLiveList() async throws {
        let (sources, container) = try await makeSources()
        let live = try await (sources.liveCalls(workspaceId: Self.workspaceId, now: Self.now)).get()
        XCTAssertEqual(live, [])
        withExtendedLifetime(container) {}
    }

    func testAnUnreadableCallLogIsAFailureSentence() async throws {
        let (sources, container) = try await makeSources(["/api/district/calls": Self.refused])
        let result = await sources.liveCalls(workspaceId: Self.workspaceId, now: Self.now)
        guard case let .failure(failure) = result else { return XCTFail("a 500 must fail, got \(result)") }
        XCTAssertFalse(failure.sentence.isEmpty)
        withExtendedLifetime(container) {}
    }

    /// A workspace list that cannot be read does not hide the calls: the role only steers.
    func testAnUnreadableWorkspaceListStillListsTheCalls() async throws {
        let (sources, container) = try await makeSources(["/api/district/workspace/list": Self.refused])
        let result = await sources.liveCalls(workspaceId: Self.workspaceId, now: Self.now)
        XCTAssertEqual(try result.get(), [])
        withExtendedLifetime(container) {}
    }

    // MARK: - The card

    func testTheCardIsTheRecordedCallDetail() async throws {
        let (sources, container) = try await makeSources([Self.detail: .fixture("district-call-detail")])
        let card = try await (sources.card(workspaceId: Self.workspaceId, callId: Self.callId, now: Self.now)).get()
        XCTAssertEqual(card.callId, Self.callId)
        XCTAssertEqual(card.workspaceId, Self.workspaceId)
        XCTAssertEqual(card.summary, "Caller booked an appointment for Thursday.")
        XCTAssertFalse(card.summaryPending)
        XCTAssertEqual(card.actionItems, ["confirm the slot"])
        XCTAssertFalse(card.inProgress)
        XCTAssertTrue(card.canCallBack, "an inbound call from a real number can be called back")
        withExtendedLifetime(container) {}
    }

    func testAMissingCallIsSaidAsNotAvailable() async throws {
        let (sources, container) = try await makeSources([
            Self.detail: .json(#"{"error":"Call not found"}"#, status: 404),
        ])
        let result = await sources.card(workspaceId: Self.workspaceId, callId: Self.callId, now: Self.now)
        guard case let .failure(failure) = result else { return XCTFail("a 404 must fail, got \(result)") }
        XCTAssertEqual(failure.sentence, CallsCopy.callNotAvailable)
        withExtendedLifetime(container) {}
    }

    func testAServerErrorOnTheCardIsNotSaidAsNotAvailable() async throws {
        let (sources, container) = try await makeSources([Self.detail: Self.refused])
        let result = await sources.card(workspaceId: Self.workspaceId, callId: Self.callId, now: Self.now)
        guard case let .failure(failure) = result else { return XCTFail("a 500 must fail, got \(result)") }
        XCTAssertNotEqual(failure.sentence, CallsCopy.callNotAvailable)
        XCTAssertFalse(failure.sentence.isEmpty)
        withExtendedLifetime(container) {}
    }

    // MARK: - The whisper

    func testAWhisperIsSentAsWrittenToTheCallAskedFor() async throws {
        let sender = RecordingWhisperSender(.success(()))
        let (sources, container) = try await makeSources(whisper: sender)
        let text = "  Offer Thursday at 3 — ou vendredi?  "
        let result = await sources.whisper(workspaceId: Self.workspaceId, callId: Self.callId, text: text)
        XCTAssertNoThrow(try result.get())
        XCTAssertEqual(sender.sent.map(\.workspaceId), [Self.workspaceId])
        XCTAssertEqual(sender.sent.map(\.callId), [Self.callId])
        XCTAssertEqual(sender.sent.map(\.text), [text])
        withExtendedLifetime(container) {}
    }

    func testAWhisperToAnEndedCallSaysTheCallEnded() async throws {
        let sender = RecordingWhisperSender(.failure(.http(status: 400, message: nil, code: "call_not_in_progress")))
        let (sources, container) = try await makeSources(whisper: sender)
        let result = await sources.whisper(workspaceId: Self.workspaceId, callId: Self.callId, text: "hi")
        guard case let .failure(failure) = result else { return XCTFail("an ended call must fail, got \(result)") }
        XCTAssertEqual(failure.sentence, WatchBridgeCopy.whisperCallEnded)
        withExtendedLifetime(container) {}
    }

    func testAnOfflineWhisperIsNotSaidAsAnEndedCall() async throws {
        let sender = RecordingWhisperSender(.failure(.transport("offline")))
        let (sources, container) = try await makeSources(whisper: sender)
        let result = await sources.whisper(workspaceId: Self.workspaceId, callId: Self.callId, text: "hi")
        guard case let .failure(failure) = result else { return XCTFail("offline must fail, got \(result)") }
        XCTAssertNotEqual(failure.sentence, WatchBridgeCopy.whisperCallEnded)
        withExtendedLifetime(container) {}
    }

    // MARK: - The feed

    /// The feed is a transcript model for the call asked for, not yet connected: the Watch
    /// activates it when its screen appears.
    func testTheFeedIsAnIdleTranscriptModelForTheCall() async throws {
        let (sources, container) = try await makeSources()
        let feed = sources.feed(workspaceId: Self.workspaceId, callId: Self.callId)
        let model = try XCTUnwrap(feed as? LiveTranscriptModel)
        XCTAssertEqual(model.workspaceId, Self.workspaceId)
        XCTAssertEqual(model.callId, Self.callId)
        XCTAssertEqual(feed.connection, .idle)
        XCTAssertEqual(feed.lines, [])
        XCTAssertNotNil(model.onPublish, "a published transcript reaches the Live Activity")
        withExtendedLifetime(container) {}
    }

    func testEachFeedIsItsOwnModel() async throws {
        let (sources, container) = try await makeSources()
        let first = sources.feed(workspaceId: Self.workspaceId, callId: "call_a")
        let second = sources.feed(workspaceId: Self.workspaceId, callId: "call_b")
        XCTAssertFalse(first === second)
        XCTAssertEqual((second as? LiveTranscriptModel)?.callId, "call_b")
        withExtendedLifetime(container) {}
    }
}

/// A ``WhisperSending`` that answers one scripted result and records what it was asked to send.
final class RecordingWhisperSender: WhisperSending, @unchecked Sendable {
    struct Sent {
        let workspaceId: String
        let callId: String
        let text: String
    }

    private let lock = NSLock()
    private let result: Result<Void, ApiError>
    private var recorded: [Sent] = []

    init(_ result: Result<Void, ApiError>) {
        self.result = result
    }

    var sent: [Sent] {
        lock.withLock { recorded }
    }

    func whisper(workspaceId: String, callId: String, text: String) async -> Result<Void, ApiError> {
        lock.withLock { recorded.append(Sent(workspaceId: workspaceId, callId: callId, text: text)) }
        return result
    }
}
