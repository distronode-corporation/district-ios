@testable import DistrictModel
@testable import DistrictNetwork
import Foundation
import XCTest

/// The bound scheduling hand-off (S33), driven over a fake transport and a fake clock.
///
/// ⛔ EVERY TEST ALSO CHECKS WHAT REACHED THE LOG, because the log is this type's only
/// output and the one place a nonce or a state could leak from it.
final class SchedulingHandoffFlowTests: XCTestCase {
    private static let state = String(repeating: "s", count: 43)
    private static let nonce = String(repeating: "N", count: 43)
    private static let minted = #"{"url":"https://www.distronode.com/dashboard/handoff?code=c","expiresIn":60}"#

    private static func callback(state: String = state, nonce: String = nonce) -> URL {
        URL(string: "districtai://handoff?state=\(state)&nonce=\(nonce)")!
    }

    private static func mintedTransport(_ json: String = minted, status: Int = 200) -> TestTransport {
        TestTransport(json: json, status: status)
    }

    private static func flow(
        _ transport: TestTransport,
        log: LogLines,
        state: String = state,
        sleep: @escaping SchedulingHandoffFlow.Sleep = Holds.forever
    ) -> SchedulingHandoffFlow {
        SchedulingHandoffFlow(
            client: SchedulingHandoffClient(client: .test(transport)),
            newState: { state },
            sleep: sleep,
            log: log.append
        )
    }

    private static func noncePresent(in transport: TestTransport) -> Bool? {
        guard let body = transport.lastRequest?.body, case let .object(fields)? = JSONWire.decode(body) else {
            return nil
        }
        return fields["nonce"] != nil
    }

    /// ⛔ NEITHER SECRET MAY APPEAR IN ANY LINE, WHATEVER PATH WAS TAKEN.
    private func assertNoSecrets(_ log: LogLines, file: StaticString = #filePath, line: UInt = #line) {
        for entry in log.lines {
            XCTAssertFalse(entry.contains(Self.nonce), "the nonce reached the log: \(entry)", file: file, line: line)
            XCTAssertFalse(entry.contains(Self.state), "the state reached the log: \(entry)", file: file, line: line)
        }
    }

    // MARK: - The bound path

    /// ⛔ THE CALLBACK FOR THIS STATE, ARRIVING WHILE THE FLOW WAITS, MINTS WITH ITS
    /// NONCE. The default ten-second clock is used and cancelled, never waited out.
    func test_S33_01_aMatchingCallbackMintsBound() async throws {
        let transport = Self.mintedTransport()
        let log = LogLines()
        let flow = SchedulingHandoffFlow(
            client: SchedulingHandoffClient(client: .test(transport)),
            newState: { Self.state },
            log: log.append
        )
        let opened = Opened()
        let run = Task { await flow.run(workspaceId: "ws_1", open: opened.record) }
        await Self.untilWaiting(flow)
        await flow.receive(Self.callback())

        guard case let .minted(handoff) = await run.value else { return XCTFail("expected a mint") }
        XCTAssertEqual(handoff.expiresIn, 60)
        XCTAssertEqual(Self.noncePresent(in: transport), true)
        let body = try XCTUnwrap(JSONWire.decode(transport.lastRequest?.body))
        guard case let .object(fields) = body else { return XCTFail("not an object") }
        XCTAssertEqual(fields["nonce"], .string(Self.nonce))
        let leg1 = await opened.urls
        XCTAssertEqual(
            leg1.map(\.absoluteString),
            ["\(EndpointTable.host)/dashboard/handoff/start?state=\(Self.state)"]
        )
        XCTAssertEqual(log.lines, ["handoff path=bound"])
        assertNoSecrets(log)
    }

    /// ⚠️ THE CALLBACK CAN BEAT THE WAIT: it lands while the sheet is still being
    /// presented. The answer is kept rather than lost.
    func test_S33_02_aCallbackDuringOpenIsKept() async {
        let transport = Self.mintedTransport()
        let log = LogLines()
        let flow = Self.flow(transport, log: log)
        let outcome = await flow.run(workspaceId: "ws_1") { _, _ in
            await flow.receive(Self.callback())
        }
        guard case .minted = outcome else { return XCTFail("expected a mint, got \(outcome)") }
        XCTAssertEqual(Self.noncePresent(in: transport), true)
        XCTAssertEqual(log.lines, ["handoff path=bound"])
        assertNoSecrets(log)
    }

    // MARK: - Dropped callbacks

    /// ⛔ A CALLBACK CARRYING ANOTHER STATE IS DROPPED AND SPENDS NOTHING. The hand-off
    /// keeps waiting, and when its clock runs out it falls back WITHOUT that nonce.
    func test_S33_03_aMismatchedStateIsDropped() async {
        let transport = Self.mintedTransport()
        let log = LogLines()
        let gate = SleepGate()
        let flow = Self.flow(transport, log: log, sleep: gate.sleep)
        let foreign = Self.callback(state: String(repeating: "x", count: 43))
        let open: SchedulingHandoffFlow.Open = { _, _ in await flow.receive(foreign) }
        let run = Task { await flow.run(workspaceId: "ws_1", open: open) }
        await Self.untilWaiting(flow)
        XCTAssertTrue(transport.recorded.isEmpty, "a dropped callback must not mint")
        gate.fire()

        guard case .minted = await run.value else { return XCTFail("expected the fallback mint") }
        XCTAssertEqual(Self.noncePresent(in: transport), false)
        XCTAssertEqual(log.lines, ["handoff callback dropped", "handoff path=unbound-fallback"])
        assertNoSecrets(log)
    }

    /// ⛔ NOTHING PENDING, NOTHING SPENT. A callback out of nowhere is dropped.
    func test_S33_04_aCallbackWithNothingPendingIsDropped() async {
        let transport = Self.mintedTransport()
        let log = LogLines()
        let flow = Self.flow(transport, log: log)
        await flow.receive(Self.callback())
        XCTAssertTrue(transport.recorded.isEmpty)
        XCTAssertEqual(log.lines, ["handoff callback dropped"])
        assertNoSecrets(log)
    }

    /// A malformed callback (here a nonce of the wrong length) is dropped even with the
    /// right state, and the hand-off still waits.
    func test_S33_05_aMalformedCallbackIsDropped() async {
        let transport = Self.mintedTransport()
        let log = LogLines()
        let flow = Self.flow(transport, log: log)
        let opened = Opened()
        let run = Task { await flow.run(workspaceId: "ws_1", open: opened.record) }
        await Self.untilWaiting(flow)
        await flow.receive(Self.callback(nonce: "short"))
        XCTAssertTrue(transport.recorded.isEmpty)
        await flow.legOneFailed(state: Self.state)
        _ = await run.value
        XCTAssertEqual(log.lines, ["handoff callback dropped", "handoff path=unbound-fallback"])
    }

    /// ⚠️ A CALLBACK AFTER THE HAND-OFF MOVED ON IS LATE, NOT A SECOND HAND-OFF.
    func test_S33_06_aLateCallbackIsDropped() async {
        let transport = Self.mintedTransport()
        let log = LogLines()
        let flow = Self.flow(transport, log: log, sleep: Holds.never)
        _ = await flow.run(workspaceId: "ws_1") { _, _ in }
        await flow.receive(Self.callback())
        XCTAssertEqual(transport.recorded.count, 1)
        XCTAssertEqual(log.lines, ["handoff path=unbound-fallback", "handoff callback dropped"])
    }

    // MARK: - The fallback

    /// ⛔ NO CALLBACK BEFORE THE CLOCK RUNS OUT: TODAY'S UNBOUND FLOW, NO `nonce` KEY.
    /// This is what a server without leg 1 produces, and why any release order is safe.
    func test_S33_07_theTimeoutFallsBackUnbound() async throws {
        let transport = Self.mintedTransport()
        let log = LogLines()
        let flow = Self.flow(transport, log: log, sleep: Holds.never)
        let opened = Opened()
        let outcome = await flow.run(workspaceId: "ws_1", open: opened.record)

        guard case .minted = outcome else { return XCTFail("expected the fallback mint, got \(outcome)") }
        let raw = try XCTUnwrap(transport.lastRequest?.body)
        XCTAssertEqual(String(bytes: raw, encoding: .utf8), #"{"workspaceId":"ws_1"}"#)
        let leg1 = await opened.urls
        XCTAssertEqual(leg1.count, 1, "leg 1 is still opened before the fallback")
        XCTAssertEqual(log.lines, ["handoff path=unbound-fallback"])
    }

    /// The timeout reached while the flow is parked waiting, rather than during `open`.
    func test_S33_08_theTimeoutWhileWaitingFallsBack() async {
        let transport = Self.mintedTransport()
        let log = LogLines()
        let gate = SleepGate()
        let flow = Self.flow(transport, log: log, sleep: gate.sleep)
        let opened = Opened()
        let run = Task { await flow.run(workspaceId: "ws_1", open: opened.record) }
        await Self.untilWaiting(flow)
        gate.fire()
        guard case .minted = await run.value else { return XCTFail("expected the fallback mint") }
        XCTAssertEqual(Self.noncePresent(in: transport), false)
    }

    /// ⚠️ LEG 1 FAILING VISIBLY FALLS BACK AT ONCE, without waiting out the clock.
    func test_S33_09_aFailedLegOneFallsBackNow() async {
        let transport = Self.mintedTransport()
        let log = LogLines()
        let flow = Self.flow(transport, log: log)
        let outcome = await flow.run(workspaceId: "ws_1") { _, state in
            await flow.legOneFailed(state: state)
        }
        guard case .minted = outcome else { return XCTFail("expected the fallback mint, got \(outcome)") }
        XCTAssertEqual(Self.noncePresent(in: transport), false)
        XCTAssertEqual(log.lines, ["handoff path=unbound-fallback"])
    }

    /// ⛔ AN EVENT FROM AN OLD SHEET CANNOT ANSWER A NEWER HAND-OFF.
    func test_S33_10_eventsForAnotherStateChangeNothing() async {
        let transport = Self.mintedTransport()
        let log = LogLines()
        let flow = Self.flow(transport, log: log)
        let outcome = await flow.run(workspaceId: "ws_1") { _, _ in
            await flow.legOneFailed(state: "old-state-old-state")
            await flow.browserClosed(state: "old-state-old-state")
            await flow.receive(Self.callback())
        }
        guard case .minted = outcome else { return XCTFail("expected a mint, got \(outcome)") }
        XCTAssertEqual(Self.noncePresent(in: transport), true)
    }

    /// ⚠️ A STATE THE SERVER WOULD REFUSE NEVER OPENS A PAGE THAT ANSWERS 400; the
    /// hand-off goes straight to the unbound mint.
    func test_S33_11_anUnusableStateFallsBackWithoutOpening() async {
        let transport = Self.mintedTransport()
        let log = LogLines()
        let flow = Self.flow(transport, log: log, state: "short")
        let opened = Opened()
        let outcome = await flow.run(workspaceId: "ws_1", open: opened.record)
        guard case .minted = outcome else { return XCTFail("expected the fallback mint, got \(outcome)") }
        let leg1 = await opened.urls
        XCTAssertTrue(leg1.isEmpty)
        XCTAssertEqual(Self.noncePresent(in: transport), false)
    }

    // MARK: - Abandon and single flight

    /// Closing the leg-1 browser before any callback mints nothing.
    func test_S33_12_closingTheBrowserAbandons() async {
        let transport = Self.mintedTransport()
        let log = LogLines()
        let flow = Self.flow(transport, log: log)
        let outcome = await flow.run(workspaceId: "ws_1") { _, state in
            await flow.browserClosed(state: state)
        }
        XCTAssertEqual(outcome, .abandoned)
        XCTAssertTrue(transport.recorded.isEmpty)
        XCTAssertEqual(log.lines, ["handoff path=abandoned"])
    }

    /// ⛔ ONE HAND-OFF PER TAP. A second tap while one is pending does nothing at all:
    /// no second leg 1 (whose cookie would replace the first) and no mint.
    func test_S33_13_aSecondTapWhilePendingDoesNothing() async {
        let transport = Self.mintedTransport()
        let log = LogLines()
        let flow = Self.flow(transport, log: log)
        let opened = Opened()
        let first = Task { await flow.run(workspaceId: "ws_1", open: opened.record) }
        await Self.untilWaiting(flow)

        let second = await flow.run(workspaceId: "ws_1", open: opened.record)
        XCTAssertEqual(second, .alreadyPending)
        let leg1 = await opened.urls
        XCTAssertEqual(leg1.count, 1)

        await flow.receive(Self.callback())
        guard case .minted = await first.value else { return XCTFail("the first hand-off must still finish") }
        XCTAssertEqual(transport.recorded.count, 1)
    }

    /// ⛔ THE NEXT TAP STARTS FRESH FROM LEG 1 WITH A NEW STATE, which is what a 410 at
    /// leg 3 needs: nothing from the spent hand-off is reused.
    func test_S33_14_eachTapGetsAFreshState() async {
        let transport = TestTransport([
            .success(HTTPResponse(statusCode: 200, body: Data(Self.minted.utf8))),
            .success(HTTPResponse(statusCode: 200, body: Data(Self.minted.utf8))),
        ])
        let states = StateSequence([Self.state, String(repeating: "t", count: 43)])
        let flow = SchedulingHandoffFlow(
            client: SchedulingHandoffClient(client: .test(transport)),
            newState: states.next,
            sleep: Holds.never,
            log: { _ in }
        )
        let opened = Opened()
        _ = await flow.run(workspaceId: "ws_1", open: opened.record)
        _ = await flow.run(workspaceId: "ws_1", open: opened.record)
        let leg1 = await opened.states
        XCTAssertEqual(leg1, [Self.state, String(repeating: "t", count: 43)])
    }

    // MARK: - Refusals

    /// ⛔ `invalid_nonce` IS A FAILURE AND THE SAME NONCE IS NOT TRIED AGAIN.
    func test_S33_15_invalidNonceFailsWithoutARetry() async {
        let transport = Self.mintedTransport(#"{"error":"nonce is malformed","code":"invalid_nonce"}"#, status: 400)
        let log = LogLines()
        let flow = Self.flow(transport, log: log)
        let outcome = await flow.run(workspaceId: "ws_1") { _, _ in
            await flow.receive(Self.callback())
        }
        XCTAssertEqual(outcome, .failed(.invalidNonce))
        XCTAssertEqual(transport.recorded.count, 1)
        assertNoSecrets(log)
    }

    /// `nonce_required` reaches the caller with its sentence, for the notice.
    func test_S33_16_nonceRequiredReachesTheCaller() async {
        let transport = Self.mintedTransport(
            #"{"error":"Update the app to open the website from it.","code":"nonce_required"}"#,
            status: 400
        )
        let flow = Self.flow(transport, log: LogLines(), sleep: Holds.never)
        let outcome = await flow.run(workspaceId: "ws_1") { _, _ in }
        XCTAssertEqual(outcome, .failed(.nonceRequired(message: "Update the app to open the website from it.")))
    }

    // MARK: - Helpers

    private static func untilWaiting(_ flow: SchedulingHandoffFlow) async {
        while await !flow.isWaitingForCallback {
            await Task.yield()
        }
    }
}

/// Every line the flow logged, in order.
private final class LogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    var lines: [String] {
        lock.withLock { stored }
    }

    @Sendable func append(_ line: String) {
        lock.withLock { stored.append(line) }
    }
}

/// What leg 1 was asked to open.
@MainActor
private final class Opened {
    private(set) var urls: [URL] = []
    private(set) var states: [String] = []

    nonisolated init() {}

    func record(_ url: URL, _ state: String) async {
        urls.append(url)
        states.append(state)
    }
}

/// A different state per call.
private final class StateSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [String]

    init(_ states: [String]) {
        remaining = states
    }

    @Sendable func next() -> String {
        lock.withLock { remaining.removeFirst() }
    }
}

/// Clocks that decide the timeout for a test.
private enum Holds {
    /// Never fires; ends only by cancellation.
    static let forever: SchedulingHandoffFlow.Sleep = { _ in try await Task.sleep(for: .seconds(3600)) }

    /// Fires at once: the callback "never" arrives in time.
    static let never: SchedulingHandoffFlow.Sleep = { _ in }
}

/// A clock the test fires by hand.
private final class SleepGate: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream()
    }

    var sleep: SchedulingHandoffFlow.Sleep {
        { [stream] _ in
            for await _ in stream {
                return
            }
            throw CancellationError()
        }
    }

    func fire() {
        continuation.yield()
    }
}
