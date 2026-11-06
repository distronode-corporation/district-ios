@testable import DistrictAI
import DistrictData
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

    /// ⛔ A READ ASKED FOR WHILE ONE IS ON ITS WAY RUNS AFTER IT, ONCE (Seer, PR #101): the read
    /// on its way may predate the call that started.
    func testAReadAskedForDuringAReadRunsAfterIt() async throws {
        let gate = ReadGate()
        let first = try rows()
        let second = try [LiveFixtures.call(id: "cmh1late", status: "in-progress")] + first
        let model = LiveCallsModel(
            workspaceId: SuperviseFixtures.workspaceId,
            events: LiveEventFeed(
                workspaceId: SuperviseFixtures.workspaceId,
                dependencies: SuperviseFixtures.feedDependencies()
            ),
            read: { await gate.next(first: first, then: second) },
            sleep: { _ in }
        )
        let loading = Task { await model.load() }
        await waitUntil { gate.waiting }
        await model.load()
        await model.load()
        gate.open()
        await loading.value

        XCTAssertEqual(gate.reads, 2, "one more read, not one per request")
        XCTAssertEqual(model.calls.map(\.id), ["cmh1late", "cmh1live"])
    }

    /// ⛔ A READ ANSWERED BEFORE A CALL ENDED DOES NOT PUT IT BACK (Seer, PR #101).
    func testACallThatEndedDuringAReadStaysOff() async throws {
        let gate = ReadGate()
        let rows = try rows()
        let model = LiveCallsModel(
            workspaceId: SuperviseFixtures.workspaceId,
            events: LiveEventFeed(
                workspaceId: SuperviseFixtures.workspaceId,
                dependencies: SuperviseFixtures.feedDependencies()
            ),
            read: { await gate.next(first: rows, then: rows) },
            sleep: { _ in }
        )
        let loading = Task { await model.load() }
        await waitUntil { gate.waiting }
        model.events.onEvent?(SuperviseFixtures.envelope(.callEnded, .object([:]), callId: "cmh1live"))
        gate.open()
        await loading.value
        await model.load()

        XCTAssertEqual(model.calls.map(\.id), [], "the stale read and the next one both leave it off")
    }

    /// ⛔ A CALL STILL RINGING IS NOT REMEMBERED AS ENDED (Seer, PR #101): it comes back with
    /// the next read once it is answered; a terminal status keeps it off.
    func testARingingUpdateIsNotAnEnding() async throws {
        let ringing = try [LiveFixtures.call(id: "cmh1ring2", status: "ringing")]
        let answered = try [LiveFixtures.call(id: "cmh1ring2", status: "in-progress")]
        let model = try makeModel(Reads([.success(ringing), .success(answered), .success(answered)]))
        await model.load()
        model.events.onEvent?(SuperviseFixtures.envelope(
            .callUpdated,
            .object(["status": .string("ringing")]),
            callId: "cmh1ring2"
        ))
        await model.load()
        XCTAssertEqual(model.calls.map(\.id), ["cmh1ring2"], "answered after ringing: listed")

        model.events.onEvent?(SuperviseFixtures.envelope(
            .callUpdated,
            .object(["status": .string("completed")]),
            callId: "cmh1ring2"
        ))
        await model.load()
        XCTAssertEqual(model.calls.map(\.id), [], "completed: off, and kept off")
    }

    func testOnlyATerminalStatusHasEnded() {
        XCTAssertFalse(CallWire.hasEnded("in-progress"))
        XCTAssertFalse(CallWire.hasEnded("ringing"))
        XCTAssertFalse(CallWire.hasEnded("queued"))
        XCTAssertFalse(CallWire.hasEnded("initiated"))
        XCTAssertTrue(CallWire.hasEnded("completed"))
        XCTAssertTrue(CallWire.hasEnded("no-answer"))
        XCTAssertTrue(CallWire.hasEnded("failed"))
    }

    // MARK: - Reading past the first page (xhigh review, item 10)

    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func row(_ id: String, status: String, minutesAgo: Double) throws -> CallSummary {
        let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-minutesAgo * 60))
        return try LiveFixtures.call(id: id, status: status, createdAt: stamp)
    }

    /// A pager over fixed pages, counting the reads.
    private final class Pages: @unchecked Sendable {
        private let lock = NSLock()
        private let pages: [[CallSummary]]
        private var asked = 0

        init(_ pages: [[CallSummary]]) {
            self.pages = pages
        }

        var reads: Int {
            lock.withLock { asked }
        }

        func pager() -> OffsetPager<CallSummary> {
            OffsetPager(identify: { $0.id }, fetch: { limit, offset in
                let index = offset / limit
                let page: [CallSummary] = self.lock.withLock {
                    self.asked += 1
                    return index < self.pages.count ? self.pages[index] : []
                }
                return .success(OffsetPage(items: page))
            })
        }
    }

    private func page(_ prefix: String, status: String = "completed", minutesAgo: Double) throws -> [CallSummary] {
        try (0 ..< LiveCallsModel.pageLimit).map { try row("\(prefix)\($0)", status: status, minutesAgo: minutesAgo) }
    }

    /// ⛔ A LIVE CALL BEHIND FIFTY NEWER ONES IS STILL LISTED.
    func testALiveCallOnTheSecondPageIsRead() async throws {
        let pages = try Pages([
            page("new", minutesAgo: 5),
            [row("cmh1second", status: "in-progress", minutesAgo: 30)] + page("old", minutesAgo: 600),
        ])

        let rows = try await LiveCallsModel.readLive(pager: pages.pager(), now: now).get()

        XCTAssertTrue(rows.contains { $0.id == "cmh1second" })
    }

    /// Reading stops at the first page that ends older than any live call can be.
    func testReadingStopsOncePagesAreOlderThanAnyLiveCall() async throws {
        let pages = try Pages([
            page("new", minutesAgo: 5),
            page("old", minutesAgo: 300),
            page("older", minutesAgo: 900),
        ])

        _ = await LiveCallsModel.readLive(pager: pages.pager(), now: now)

        XCTAssertEqual(pages.reads, 2)
    }

    /// And at the end of the log, and never past the page cap.
    func testReadingStopsAtTheEndAndAtTheCap() async throws {
        let short = try Pages([page("new", minutesAgo: 5), [row("last", status: "completed", minutesAgo: 6)]])
        _ = await LiveCallsModel.readLive(pager: short.pager(), now: now)
        XCTAssertEqual(short.reads, 2)

        let endless = try Pages((0 ..< 20).map { try page("p\($0)-", minutesAgo: 5) })
        _ = await LiveCallsModel.readLive(pager: endless.pager(), now: now)
        XCTAssertEqual(endless.reads, LiveCallsModel.maxPages)
    }

    /// A first page that fails is a failure; a later one keeps what was read.
    func testAFailedFirstPageFailsAndALaterOneKeepsTheRows() async throws {
        let failing = OffsetPager<CallSummary>(identify: { $0.id }, fetch: { _, _ in .failure(.transport("offline")) })
        if case .success = await LiveCallsModel.readLive(pager: failing, now: now) {
            XCTFail("expected a failure")
        }
        let first = try page("new", minutesAgo: 5)
        let later = OffsetPager<CallSummary>(identify: { $0.id }, fetch: { limit, offset in
            offset == 0 ? .success(OffsetPage(items: Array(first.prefix(limit)))) : .failure(.transport("offline"))
        })
        let rows = try await LiveCallsModel.readLive(pager: later, now: now).get()
        XCTAssertEqual(rows.count, LiveCallsModel.pageLimit)
    }

    /// ⚠️ ONLY AN UPDATE THAT CAN ADD A ROW RE-READS (max review, item 12): an in-progress one does;
    /// a completed or ringing one takes the row off without reading ten pages again.
    func testOnlyAnInProgressUpdateReReads() async throws {
        let reads = try Reads([.success(rows())])
        let model = makeModel(reads)
        await model.load()

        model.events.onEvent?(SuperviseFixtures.envelope(
            .callUpdated,
            .object(["status": .string("completed")]),
            callId: "cmh1live"
        ))
        model.events.onEvent?(SuperviseFixtures.envelope(
            .callUpdated,
            .object(["status": .string("ringing")]),
            callId: "cmh1ring"
        ))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(reads.count, 1)

        model.events.onEvent?(SuperviseFixtures.envelope(
            .callUpdated,
            .object(["status": .string("in-progress")]),
            callId: "cmh1ring"
        ))
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

/// A read cancelled part way (Seer, district-macos PR #98).
extension LiveCallsModelTests {
    /// ⛔ A READ CANCELLED PART WAY IS A FAILURE, NOT THE PAGES IT REACHED (Seer, district-macos
    /// PR #98): the later page fails because the task was cancelled, as `ApiClient` answers a
    /// cancelled request, and the list on screen is kept.
    func testACancelledReadIsAFailureNotAPartialList() async throws {
        let first = try page("new", minutesAgo: 5)
        let cancelling = OffsetPager<CallSummary>(identify: { $0.id }, fetch: { limit, offset in
            guard offset == 0 else {
                withUnsafeCurrentTask { $0?.cancel() }
                return .failure(.transport("cancelled"))
            }
            return .success(OffsetPage(items: Array(first.prefix(limit))))
        })
        let now = now
        let result = await Task { await LiveCallsModel.readLive(pager: cancelling, now: now) }.value
        if case .success = result {
            XCTFail("a cancelled read must not hand back a partial list")
        }
    }

    /// ⛔ AND THROUGH THE MODEL: the next event cancels the re-read on its way, and the live call
    /// on the second page stays listed.
    func testAReReadCancelledByTheNextEventKeepsTheList() async throws {
        let log = try CancellableLog(
            first: [row("cmh1first", status: "in-progress", minutesAgo: 2)] + page("new", minutesAgo: 5).dropFirst(),
            second: [row("cmh1second", status: "in-progress", minutesAgo: 30)] + page("old", minutesAgo: 600)
        )
        let now = now
        let model = LiveCallsModel(
            workspaceId: SuperviseFixtures.workspaceId,
            events: LiveEventFeed(
                workspaceId: SuperviseFixtures.workspaceId,
                dependencies: SuperviseFixtures.feedDependencies()
            ),
            read: { await LiveCallsModel.readLive(pager: log.pager(), now: now) },
            sleep: { _ in }
        )
        await model.load()
        XCTAssertEqual(model.calls.map(\.id), ["cmh1first", "cmh1second"])

        model.events.onEvent?(SuperviseFixtures.envelope(.callStarted, .object([:]), callId: "cmh1new"))
        await waitUntil(state: "reads \(log.reads)") { log.waiting }
        model.events.onEvent?(SuperviseFixtures.envelope(.callStarted, .object([:]), callId: "cmh1new2"))
        await waitUntil(state: "reads \(log.reads)") { log.reads == 3 }

        XCTAssertEqual(model.calls.map(\.id), ["cmh1first", "cmh1second"])
    }

    /// ⛔ A READ QUEUED BEHIND THE CANCELLED ONE STILL LANDS (Sean, 2026-11-06): it runs in a
    /// fresh task, where its request is not refused, and the list takes the call it brings.
    func testAReadQueuedBehindACancelledReadLands() async throws {
        let live = try row("cmh1first", status: "in-progress", minutesAgo: 2)
        let first = try [live] + page("new", minutesAgo: 5).dropFirst()
        let log = try CancellableLog(
            first: first,
            second: [row("cmh1second", status: "in-progress", minutesAgo: 30)] + page("old", minutesAgo: 600),
            later: [row("cmh1third", status: "in-progress", minutesAgo: 1), live]
        )
        let delays = Delays()
        let now = now
        let model = LiveCallsModel(
            workspaceId: SuperviseFixtures.workspaceId,
            events: LiveEventFeed(
                workspaceId: SuperviseFixtures.workspaceId,
                dependencies: SuperviseFixtures.feedDependencies()
            ),
            read: { await LiveCallsModel.readLive(pager: log.pager(), now: now) },
            sleep: { _ in try await delays.sleep() }
        )
        await model.load()

        model.events.onEvent?(SuperviseFixtures.envelope(.callStarted, .object([:]), callId: "cmh1new"))
        await waitUntil(state: "reads \(log.reads)") { log.waiting }
        // A pull to refresh while the re-read is on its way queues one more read behind it.
        await model.load()
        // The next event cancels the re-read on its way; its own re-read is still in its delay.
        model.events.onEvent?(SuperviseFixtures.envelope(.callStarted, .object([:]), callId: "cmh1third"))

        await waitUntil(state: "\(model.calls.map(\.id)), reads \(log.reads)") {
            model.calls.map(\.id).contains("cmh1third")
        }
        XCTAssertEqual(log.reads, 3)
    }

    /// The model's re-read delay: the first passes at once, every later one outlasts the test.
    private final class Delays: @unchecked Sendable {
        private let lock = NSLock()
        private var made = 0

        func sleep() async throws {
            let first = lock.withLock {
                made += 1
                return made == 1
            }
            guard !first else { return }
            try await Task.sleep(for: .seconds(30))
        }
    }

    /// The call log for the cancelled re-reads: the first read answers both pages; the second
    /// holds its second page until its task is cancelled and then fails; a later read answers
    /// `later` as one page, or fails as offline. ⚠️ A request from a task already cancelled fails
    /// at once, as `URLSession` refuses it and `ApiClient` reports a transport failure.
    private final class CancellableLog: @unchecked Sendable {
        private let lock = NSLock()
        private let first: [CallSummary]
        private let second: [CallSummary]
        private let later: [CallSummary]?
        private var made = 0
        private var held = false

        init(first: [CallSummary], second: [CallSummary], later: [CallSummary]? = nil) {
            self.first = first
            self.second = second
            self.later = later
        }

        var reads: Int {
            lock.withLock { made }
        }

        var waiting: Bool {
            lock.withLock { held }
        }

        func pager() -> OffsetPager<CallSummary> {
            let read = lock.withLock {
                made += 1
                return made
            }
            return OffsetPager(identify: { $0.id }, fetch: { [self] _, offset in
                guard !Task.isCancelled else {
                    return .failure(.transport("cancelled"))
                }
                switch (read, offset) {
                case (1, 0), (2, 0):
                    return .success(OffsetPage(items: first))
                case (1, _):
                    return .success(OffsetPage(items: second))
                case (2, _):
                    lock.withLock { held = true }
                    try? await Task.sleep(for: .seconds(30))
                    return .failure(.transport("cancelled"))
                default:
                    guard let later else {
                        return .failure(.transport("offline"))
                    }
                    return .success(OffsetPage(items: later))
                }
            })
        }
    }
}

/// Holds the first read until the test opens it; later reads answer at once.
private final class ReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var gate: CheckedContinuation<Void, Never>?
    private var count = 0

    var reads: Int {
        lock.withLock { count }
    }

    var waiting: Bool {
        lock.withLock { gate != nil }
    }

    func open() {
        let held: CheckedContinuation<Void, Never>? = lock.withLock {
            defer { gate = nil }
            return gate
        }
        held?.resume()
    }

    func next(first: [CallSummary], then later: [CallSummary]) async -> Result<[CallSummary], ApiError> {
        let isFirst: Bool = lock.withLock {
            count += 1
            return count == 1
        }
        guard isFirst else { return .success(later) }
        await withCheckedContinuation { continuation in
            lock.withLock { gate = continuation }
        }
        return .success(first)
    }
}
