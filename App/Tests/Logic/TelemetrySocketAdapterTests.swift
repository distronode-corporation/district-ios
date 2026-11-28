@testable import DistrictAI
import DistrictLive
import Foundation
import XCTest

/// The app's half of the telemetry socket: ``URLSessionTelemetrySocket`` over a
/// ``FakeWebSocketTask``, ``URLSessionTelemetryTransport/connect(to:subprotocols:)`` over a
/// scripted opener, and ``WebSocketDelegate``'s routing of the server's close.
///
/// ⛔ WHAT THE CORE IS OWED, AND WHAT THIS PINS: frames in order, the server's close code and
/// reason exactly once, a close with no status read as 1005, a pong reported as a heartbeat (and
/// a failed ping as nothing), and nothing at all after the end.
@MainActor
final class TelemetrySocketAdapterTests: XCTestCase {
    private let clock = ManualLiveClock()

    // MARK: - Frames

    func testTextAndBinaryArriveInOrder() async throws {
        let task = FakeWebSocketTask()
        let socket = makeSocket(task)
        task.deliver("{\"seq\":1}")
        task.push(.success(.data(Data([0x7B, 0x7D]))))
        task.deliver("{\"seq\":2}")

        let first = try await socket.receive()
        let second = try await socket.receive()
        let third = try await socket.receive()

        XCTAssertEqual(first, .text("{\"seq\":1}"))
        XCTAssertEqual(second, .binary(Data([0x7B, 0x7D])))
        XCTAssertEqual(third, .text("{\"seq\":2}"))
        await socket.close()
    }

    /// ⛔ 4401 AND 4403 ARE THE PROTOCOL: the code and the reason reach the core, once, and the
    /// stream has ended after it.
    func testAServerCloseCarriesItsCodeAndReasonThenEnds() async throws {
        let task = FakeWebSocketTask()
        let socket = makeSocket(task)
        task.deliver("last words")
        task.serverClosed(code: 4401, reason: "renew")

        let text = try await socket.receive()
        let closed = try await socket.receive()

        XCTAssertEqual(text, .text("last words"))
        XCTAssertEqual(closed, .closed(code: 4401, reason: "renew"))
        await assertEnded(socket)
        await socket.close()
    }

    /// ⛔ A READ THAT THROWS WITH NO CLOSE FRAME IS A BROKEN SOCKET, NOT A CLOSE.
    func testABrokenReadWithNoCloseFrameIsAFailure() async {
        let task = FakeWebSocketTask()
        let socket = makeSocket(task)
        task.push(.failure(URLError(.timedOut)))

        do {
            let frame = try await socket.receive()
            XCTFail("expected a failure, got \(frame)")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        await socket.close()
    }

    /// ⚠️ A CLOSE WITH NO STATUS IS 1005, a missing reason is "", and a second close is dropped.
    func testAPeerCloseWithNoStatusReadsAs1005AndOnlyTheFirstCounts() async throws {
        let task = FakeWebSocketTask()
        let socket = makeSocket(task)

        socket.peerClosed(code: 0, reason: nil)
        socket.peerClosed(code: 4403, reason: Data("stop".utf8))
        task.deliver("after the end")

        let closed = try await socket.receive()
        XCTAssertEqual(closed, .closed(code: 1005, reason: ""))
        await assertEnded(socket)
        await socket.close()
    }

    /// A reason that is not UTF-8 is reported as an empty reason, not dropped with the code.
    func testAReasonThatIsNotTextKeepsItsCode() async throws {
        let socket = makeSocket(FakeWebSocketTask())

        socket.peerClosed(code: 4000, reason: Data([0xFF, 0xFE, 0xFD]))

        let closed = try await socket.receive()
        XCTAssertEqual(closed, .closed(code: 4000, reason: ""))
        await socket.close()
    }

    func testABreakAfterTheHandshakeFailsTheStream() async {
        let socket = makeSocket(FakeWebSocketTask())

        socket.broke(URLError(.networkConnectionLost))
        socket.peerClosed(code: 4401, reason: nil)

        do {
            let frame = try await socket.receive()
            XCTFail("expected a failure, got \(frame)")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost)
        }
        await socket.close()
    }

    // MARK: - Liveness

    /// ⛔ A PONG IS A HEARTBEAT, and only once the ping interval has passed.
    func testAPongIsAHeartbeatOnceTheIntervalHasPassed() async throws {
        let task = FakeWebSocketTask()
        let socket = makeSocket(task)
        await waitUntilAsleep(clock, count: 1)

        clock.advance(by: URLSessionTelemetryTransport.pingIntervalMilliseconds - 1)
        task.deliver("before the ping")
        let early = try await socket.receive()
        XCTAssertEqual(early, .text("before the ping"))

        clock.advance(by: 1)
        let beat = try await socket.receive()
        XCTAssertEqual(beat, .heartbeat)
        await socket.close()
    }

    /// ⛔ A FAILED PING YIELDS NOTHING: a missing pong is the core's watchdog's to notice.
    func testAFailedPingYieldsNoHeartbeat() async throws {
        let inner = FakeWebSocketTask()
        let socket = makeSocket(PonglessTask(inner))
        await waitUntilAsleep(clock, count: 1)

        clock.advance(by: URLSessionTelemetryTransport.pingIntervalMilliseconds)
        // The loop has pinged and is asleep again before the next frame is sent.
        await waitUntilAsleep(clock, count: 1)
        inner.deliver("still here")

        let frame = try await socket.receive()
        XCTAssertEqual(frame, .text("still here"))
        await socket.close()
    }

    // MARK: - Send and close

    func testASendReachesTheTaskInOrder() async throws {
        let task = FakeWebSocketTask()
        let socket = makeSocket(task)

        try await socket.send("{\"op\":\"mode\"}")
        try await socket.send("{\"op\":\"subscribe\"}")

        XCTAssertEqual(task.sent, ["{\"op\":\"mode\"}", "{\"op\":\"subscribe\"}"])
        await socket.close()
    }

    /// ⚠️ CLOSE IS IDEMPOTENT: one normal closure, one release of the session, and every send
    /// and read after it ends without reaching the task.
    func testCloseIsFinalAndIdempotent() async {
        let task = FakeWebSocketTask()
        let released = ReleaseCount()
        let socket = URLSessionTelemetrySocket(
            task: task,
            selectedSubprotocol: nil,
            clock: clock,
            onClose: { released.add() }
        )

        await socket.close()
        await socket.close()

        XCTAssertEqual(task.cancelCodes, [.normalClosure])
        XCTAssertEqual(released.value, 1)
        do {
            try await socket.send("late")
            XCTFail("a send after close went out")
        } catch {
            XCTAssertEqual(error as? TelemetrySocketEnded, TelemetrySocketEnded())
        }
        XCTAssertEqual(task.sent, [])
        do {
            let frame = try await socket.receive()
            XCTFail("a read after close answered \(frame)")
        } catch {}
    }

    // MARK: - connect(to:subprotocols:)

    /// ⛔ THE SUBPROTOCOLS GO TO THE OPENER EXACTLY AS GIVEN, and the server's selection and the
    /// opener's release come back on the socket.
    func testConnectOffersTheSubprotocolsAsGivenAndKeepsTheSelection() async throws {
        let opened = OpenerLog()
        let task = FakeWebSocketTask()
        let transport = URLSessionTelemetryTransport(clock: clock) { url, protocols in
            opened.record(url, protocols)
            return OpenedWebSocket(
                task: task,
                selectedSubprotocol: "district.telemetry.v1",
                delegate: nil,
                onClose: { opened.release() }
            )
        }
        let url = try XCTUnwrap(URL(string: "wss://telemetry.invalid/ws/telemetry?workspaceId=ws_1"))

        let socket = try await transport.connect(
            to: url,
            subprotocols: ["district.telemetry.v1", "distronode.token.a.b.c"]
        )

        XCTAssertEqual(socket.selectedSubprotocol, "district.telemetry.v1")
        XCTAssertEqual(opened.calls.map(\.url), [url])
        XCTAssertEqual(opened.calls.map(\.protocols), [["district.telemetry.v1", "distronode.token.a.b.c"]])
        task.deliver("hello")
        let frame = try await socket.receive()
        XCTAssertEqual(frame, .text("hello"))
        await socket.close()
        XCTAssertEqual(opened.releases, 1)
    }

    func testAFailedOpenFailsTheConnect() async throws {
        let transport = URLSessionTelemetryTransport(clock: clock) { _, _ in
            throw URLError(.cannotConnectToHost)
        }
        let url = try XCTUnwrap(URL(string: "wss://telemetry.invalid/ws/telemetry"))

        do {
            _ = try await transport.connect(to: url, subprotocols: ["district.telemetry.v1"])
            XCTFail("connected through a refused open")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost)
        }
    }

    /// ⚠️ THE REAL OPEN, AGAINST A PORT NOTHING LISTENS ON: the handshake throws rather than
    /// hanging, and the per-socket session is released on the way out.
    func testTheRealOpenThrowsWhenNothingAnswers() async throws {
        let url = try XCTUnwrap(URL(string: "ws://127.0.0.1:9/ws/telemetry"))

        do {
            _ = try await URLSessionTelemetryTransport.open(url: url, subprotocols: ["district.telemetry.v1"])
            XCTFail("a handshake with nothing listening succeeded")
        } catch {}
    }

    // MARK: - WebSocketDelegate

    /// ⛔ THE SERVER'S CLOSE, REPORTED BY THE DELEGATE AFTER THE HANDSHAKE, REACHES THE SOCKET.
    func testTheDelegateRoutesTheServersCloseToTheSocket() async throws {
        let (session, webSocket) = try Self.idleWebSocket()
        defer { session.invalidateAndCancel() }
        let delegate = WebSocketDelegate()
        let socket = makeSocket(FakeWebSocketTask())
        delegate.attach(socket)
        let stop = try XCTUnwrap(URLSessionWebSocketTask.CloseCode(rawValue: 4403))

        delegate.urlSession(session, webSocketTask: webSocket, didCloseWith: stop, reason: Data("stop".utf8))

        let closed = try await socket.receive()
        XCTAssertEqual(closed, .closed(code: 4403, reason: "stop"))
        await socket.close()
    }

    /// ⚠️ A COMPLETION WITH NO ERROR AFTER THE HANDSHAKE IS STILL A LOST CONNECTION.
    func testTheDelegateReadsACompletionWithNoErrorAsALostConnection() async throws {
        let (session, webSocket) = try Self.idleWebSocket()
        defer { session.invalidateAndCancel() }
        let delegate = WebSocketDelegate()
        let socket = makeSocket(FakeWebSocketTask())
        delegate.attach(socket)

        delegate.urlSession(session, task: webSocket, didCompleteWithError: nil)

        do {
            let frame = try await socket.receive()
            XCTFail("expected a failure, got \(frame)")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost)
        }
        await socket.close()
    }

    /// ⚠️ THE SOCKET IS HELD WEAKLY: a close for a socket already gone reaches nothing and
    /// does not crash.
    func testTheDelegateHoldsTheSocketWeakly() throws {
        let (session, webSocket) = try Self.idleWebSocket()
        defer { session.invalidateAndCancel() }
        let delegate = WebSocketDelegate()
        weak var released: URLSessionTelemetrySocket?
        do {
            let task = FakeWebSocketTask()
            let socket = URLSessionTelemetrySocket(task: task, selectedSubprotocol: nil, clock: clock)
            delegate.attach(socket)
            released = socket
        }

        delegate.urlSession(session, task: webSocket, didCompleteWithError: URLError(.timedOut))
        delegate.urlSession(session, webSocketTask: webSocket, didCloseWith: .goingAway, reason: nil)

        // ⚠️ The loops hold the socket's task and its sink, never the socket itself.
        XCTAssertNil(released)
    }

    // MARK: - Helpers

    private func makeSocket(_ task: any WebSocketTasking) -> URLSessionTelemetrySocket {
        URLSessionTelemetrySocket(task: task, selectedSubprotocol: "district.telemetry.v1", clock: clock)
    }

    private func assertEnded(
        _ socket: URLSessionTelemetrySocket,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            let frame = try await socket.receive()
            XCTFail("a frame after the end: \(frame)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? TelemetrySocketEnded, TelemetrySocketEnded(), file: file, line: line)
        }
    }

    /// A real `URLSessionWebSocketTask` that is never resumed, so nothing is dialled: only the
    /// delegate's arguments need one.
    private static func idleWebSocket() throws -> (URLSession, URLSessionWebSocketTask) {
        let session = URLSession(configuration: .ephemeral)
        let url = try XCTUnwrap(URL(string: "wss://telemetry.invalid/ws/telemetry"))
        return (session, session.webSocketTask(with: url))
    }
}

/// A task whose pings never get a pong: everything else is the wrapped fake's.
private final class PonglessTask: WebSocketTasking, @unchecked Sendable {
    private let inner: FakeWebSocketTask

    init(_ inner: FakeWebSocketTask) {
        self.inner = inner
    }

    var closeCode: URLSessionWebSocketTask.CloseCode {
        inner.closeCode
    }

    var closeReason: Data? {
        inner.closeReason
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await inner.receive()
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        try await inner.send(message)
    }

    func sendPing(pongReceiveHandler: @escaping @Sendable ((any Error)?) -> Void) {
        pongReceiveHandler(URLError(.timedOut))
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        inner.cancel(with: closeCode, reason: reason)
    }
}

/// How many times the opener's release ran.
private final class ReleaseCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func add() {
        lock.withLock { count += 1 }
    }
}

/// What each open was asked for, and how many releases ran.
private final class OpenerLog: @unchecked Sendable {
    struct Call {
        let url: URL
        let protocols: [String]
    }

    private let lock = NSLock()
    private var opened: [Call] = []
    private var released = 0

    var calls: [Call] {
        lock.withLock { opened }
    }

    var releases: Int {
        lock.withLock { released }
    }

    func record(_ url: URL, _ protocols: [String]) {
        lock.withLock { opened.append(Call(url: url, protocols: protocols)) }
    }

    func release() {
        lock.withLock { released += 1 }
    }
}
