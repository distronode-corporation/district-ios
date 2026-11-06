@testable import DistrictAI
import DistrictModel
import XCTest

/// The Live list: the call log's first page filtered to calls in progress, a call ending taken
/// off at once, and a failure never shown as "no calls".
@MainActor
final class LiveCallsModelTests: XCTestCase {
    private final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [Result<[CallSummary], ApiError>]
        private var made = 0

        init(_ answers: [Result<[CallSummary], ApiError>]) {
            self.answers = answers
        }

        var count: Int {
            lock.withLock { made }
        }

        func next() -> Result<[CallSummary], ApiError> {
            lock.withLock {
                made += 1
                return answers.count > 1 ? answers.removeFirst() : answers[0]
            }
        }
    }

    private func makeModel(_ reads: Reads) -> LiveCallsModel {
        LiveCallsModel(
            workspaceId: SuperviseFixtures.workspaceId,
            events: LiveEventFeed(
                workspaceId: SuperviseFixtures.workspaceId,
                dependencies: SuperviseFixtures.feedDependencies()
            ),
            read: { reads.next() },
            sleep: { _ in }
        )
    }

    private func rows() throws -> [CallSummary] {
        try [
            LiveFixtures.call(id: "cmh1live", status: "in-progress"),
            LiveFixtures.call(id: "cmh1ring", status: "ringing"),
            LiveFixtures.call(id: "cmh1done", status: "completed"),
        ]
    }

    /// ⛔ THE PHONE'S ONE RULE FOR LIVE: in progress, not ringing, not ended.
    func testOnlyCallsInProgressAreListed() async throws {
        let model = try makeModel(Reads([.success(rows())]))
        await model.load()
        XCTAssertEqual(model.calls.map(\.id), ["cmh1live"])
    }

    /// ⛔ A FAILED READ IS A FAILURE, NEVER AN EMPTY LIST.
    func testAFailedFirstReadIsAFailureNotAnEmptyList() async {
        let model = makeModel(Reads([.failure(.transport("offline"))]))
        await model.load()
        guard case .failed = model.state else { return XCTFail("expected a failure, got \(model.state)") }
        XCTAssertEqual(model.calls.map(\.id), [])
    }

    /// A re-read that fails keeps the list it had.
    func testAFailedReReadKeepsTheList() async throws {
        let model = try makeModel(Reads([.success(rows()), .failure(.transport("offline"))]))
        await model.load()
        await model.load()
        XCTAssertEqual(model.calls.map(\.id), ["cmh1live"])
    }

    /// ⛔ A CALL ENDING COMES OFF AT ONCE; a call starting asks for the page again.
    func testTheEventsTakeAnEndedCallOffAndReReadOnAStart() async throws {
        let reads = try Reads([.success(rows())])
        let model = makeModel(reads)
        await model.load()

        model.events.onEvent?(SuperviseFixtures.envelope(.callEnded, .object([:]), callId: "cmh1live"))
        XCTAssertEqual(model.calls.map(\.id), [])

        model.events.onEvent?(SuperviseFixtures.envelope(.callStarted, .object([:]), callId: "cmh1new"))
        await waitUntil { reads.count == 2 }
    }

    /// A `call_updated` whose status left `in-progress` is an ending too.
    func testAnUpdateThatLeftInProgressTakesTheCallOff() async throws {
        let model = try makeModel(Reads([.success(rows())]))
        await model.load()
        model.events.onEvent?(SuperviseFixtures.envelope(
            .callUpdated,
            .object(["status": .string("completed")]),
            callId: "cmh1live"
        ))
        XCTAssertEqual(model.calls.map(\.id), [])
    }
}
