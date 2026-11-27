@testable import DistrictAI
import DistrictLive
import DistrictModel
import XCTest

/// ``LiveTranscriptModel`` past LiveTranscriptModelTests: the state before any socket, the
/// call-row signals with no socket open, and a screen that comes back while the full
/// transcript was still being fetched, which resumes the fetch and opens no socket.
@MainActor
final class LiveTranscriptModelMarginTests: XCTestCase {
    private let clock = ManualLiveClock()
    private let script = SocketScript()

    private func makeModel(transcripts: ScriptedTranscripts? = nil) -> LiveTranscriptModel {
        let transcripts = transcripts ?? ScriptedTranscripts([.success("")])
        return LiveTranscriptModel(
            workspaceId: TranscriptWire.workspaceId,
            callId: TranscriptWire.callId,
            dependencies: LiveTranscriptModel.Dependencies(
                minter: ScriptedMinter(clock: clock),
                transport: script.transport(clock: clock),
                clock: clock,
                jitter: { 0 },
                fetchTranscript: { transcripts.next() }
            )
        )
    }

    /// Steps the manual clock until `condition` holds, letting woken tasks run between steps.
    private func advance(upTo limit: Int64, until condition: () -> Bool) async {
        var moved: Int64 = 0
        while !condition(), moved < limit {
            clock.advance(by: 500)
            moved += 500
            try? await Task.sleep(for: .milliseconds(5))
        }
        await waitUntil(timeout: 2, condition)
    }

    /// Before the screen is shown: no socket, nothing to fall back to, nothing fetched.
    func testANewModelHoldsNoSocketAndDoesNotFallBack() {
        let model = makeModel()
        XCTAssertEqual(model.connection, .idle)
        XCTAssertFalse(model.fallsBack)
        XCTAssertEqual(model.finalTranscript, .notRequested)
        XCTAssertTrue(model.lines.isEmpty)
        XCTAssertEqual(model.snapshotsReceived, 0)
        model.deactivate()
        XCTAssertEqual(model.connection, .idle, "deactivating with nothing open stays idle")
        XCTAssertTrue(script.tasks.isEmpty)
    }

    /// The call row's signals publish, but open nothing while the screen is not in front.
    func testCallRowSignalsPublishWithoutOpeningASocket() async {
        let model = makeModel()
        var published = 0
        model.onPublish = { _ in published += 1 }
        model.callShownInProgress()
        model.callEnded()
        XCTAssertEqual(published, 2)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(script.tasks.isEmpty, "an inactive screen holds no socket")
        XCTAssertEqual(model.connection, .idle)
    }

    /// ⛔ THE BACKGROUND STOPS THE FETCH AND THE FOREGROUND RESUMES IT. After the call ended the
    /// screen asks for the full transcript; leaving stops asking, and coming back asks again
    /// without reopening a socket for a call that is over.
    func testComingBackDuringTheFetchResumesItWithoutASocket() async {
        let transcripts = ScriptedTranscripts([.success(""), .success("Ava: Good afternoon.")])
        let model = makeModel(transcripts: transcripts)
        model.activate()
        await waitUntil(state: "sockets=\(script.tasks.count)") {
            self.script.tasks.first?.sent.count == 2 && model.connection == .open
        }
        let task = script.tasks.first
        task?.deliver(TranscriptWire.snapshot([TranscriptWire.greeting], lastSeq: 1))
        await waitUntil { model.phase == .live }
        task?.deliver(TranscriptWire.ended(seq: 2))
        await waitUntil { model.phase == .ended(.callEnded) }
        guard case .fetching = model.finalTranscript else {
            return XCTFail("expected a fetch after the end, got \(model.finalTranscript)")
        }

        model.deactivate()
        let asked = transcripts.count
        for _ in 0 ..< 40 {
            clock.advance(by: 500)
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(transcripts.count, asked, "a screen in the background fetches nothing")
        XCTAssertEqual(model.connection, .idle)

        model.activate()
        await advance(upTo: 20000) { model.finalTranscript == .loaded("Ava: Good afternoon.") }
        XCTAssertGreaterThan(transcripts.count, asked)
        XCTAssertEqual(script.tasks.count, 1, "a call that is over opens no new socket")
        model.deactivate()
    }
}
