import DistrictLive
import Foundation

/// The telemetry socket over `URLSessionWebSocketTask`: the one piece of `DistrictLive`
/// that lives in the app.
///
/// ⚠️ PORTED FROM district-macos (`App/Sources/Platform/Live/URLSessionTelemetryTransport.swift`
/// at `08e9a17`), with ``URLSessionTelemetrySocket/send(_:)`` added for the live transcript's
/// ops. Keep the two in step: a fix to one is a fix the other needs.
///
/// ⛔ IT MOVES BYTES AND DECIDES NOTHING. Every rule about the socket (what to offer, what
/// to accept, when to renew, when to give up) is `TelemetryConnection`'s, in
/// district-core-swift, tested on Linux. `TelemetrySocketTransport`'s documentation lists
/// what an adapter owes it, and each item is answered here:
///
/// - `connect(to:subprotocols:)` returns once the handshake completed (the delegate's
///   `didOpenWithProtocol`), with the protocol the server selected, and throws for a
///   refused handshake or a network failure.
/// - ⛔ THE SUBPROTOCOLS ARE OFFERED EXACTLY AS GIVEN, IN ORDER: the protocol version
///   first, then the credential (`distronode.token.<jwt>`). `URLSessionWebSocketTask`
///   sends them as one `Sec-WebSocket-Protocol` header in the order of the array, and
///   reordering them would let a server that selects the first offer echo the credential
///   back. Nothing here builds, filters or sorts the list.
/// - ⛔ LIVENESS IS SURFACED AS `.heartbeat`. `URLSessionWebSocketTask` answers the
///   server's pings itself and never hands them to `receive()`, so a quiet, healthy socket
///   delivers nothing at all, and the core's 90 s silence watchdog would drop every quiet
///   socket. So the socket sends its own ping every ``pingIntervalMilliseconds`` and
///   reports each pong as a heartbeat. See ``URLSessionTelemetrySocket``.
/// - ⛔ THE SERVER'S CLOSE CODE IS REPORTED as `.closed(code:reason:)`, from the delegate's
///   `didCloseWith` or from `closeCode` once `receive()` throws, because 4401 ("mint a
///   new credential") and 4403 ("stop") are the protocol. A close with no status is 1005.
/// - A text op is sent with `URLSessionWebSocketTask.send(_:)`, which delivers in call order;
///   the core's runner waits for each send before the next, so nothing is reordered here.
///
/// ⚠️ ONE `URLSession` PER SOCKET, invalidated when the socket closes. A session retains
/// its delegate until it is invalidated, so a shared session with per-socket delegates
/// would either leak every delegate or route one socket's handshake to another's waiter.
struct URLSessionTelemetryTransport: TelemetrySocketTransport {
    /// How often the socket pings the server. ⚠️ A third of the core's 90 s silence limit,
    /// so two pongs can go missing before a healthy socket is presumed dead; the server
    /// pings on the same 30 s period.
    static let pingIntervalMilliseconds: Int64 = 30000

    /// Opens a socket and waits for the handshake: the real `URLSession` below, or a test's
    /// fake. The same three values come back either way.
    typealias Opener = @Sendable (URL, [String]) async throws -> OpenedWebSocket

    private let opener: Opener
    private let clock: any LiveClock

    init(clock: any LiveClock = SystemLiveClock(), opener: @escaping Opener = URLSessionTelemetryTransport.open) {
        self.clock = clock
        self.opener = opener
    }

    func connect(to url: URL, subprotocols: [String]) async throws -> any TelemetrySocket {
        let opened = try await opener(url, subprotocols)
        let socket = URLSessionTelemetrySocket(
            task: opened.task,
            selectedSubprotocol: opened.selectedSubprotocol,
            clock: clock,
            onClose: opened.onClose
        )
        opened.delegate?.attach(socket)
        return socket
    }

    /// The real handshake.
    ///
    /// ⚠️ THE CREDENTIAL TRAVELS ONLY IN `protocols`, which becomes the
    /// `Sec-WebSocket-Protocol` header; the URL carries nothing but the workspace id.
    static func open(url: URL, subprotocols: [String]) async throws -> OpenedWebSocket {
        let delegate = WebSocketDelegate()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        let task = session.webSocketTask(with: url, protocols: subprotocols)
        let selected: String?
        do {
            selected = try await withTaskCancellationHandler {
                try await delegate.waitForOpen(task)
            } onCancel: {
                task.cancel(with: .goingAway, reason: nil)
            }
        } catch {
            session.invalidateAndCancel()
            throw error
        }
        return OpenedWebSocket(
            task: task,
            selectedSubprotocol: selected,
            delegate: delegate,
            onClose: { session.invalidateAndCancel() }
        )
    }
}

/// What opening a socket produced.
struct OpenedWebSocket: Sendable {
    let task: any WebSocketTasking
    /// The subprotocol the server selected, or nil. ⚠️ Judged by the core, not here.
    let selectedSubprotocol: String?
    /// Delivers the server's close code to the socket, when there is a real delegate.
    let delegate: WebSocketDelegate?
    /// Releases whatever the opener holds (the per-socket `URLSession`).
    let onClose: @Sendable () -> Void
}

/// What the socket needs of a `URLSessionWebSocketTask`, and the seam a test replaces.
protocol WebSocketTasking: AnyObject, Sendable {
    func receive() async throws -> URLSessionWebSocketTask.Message
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func sendPing(pongReceiveHandler: @escaping @Sendable ((any Error)?) -> Void)
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    var closeCode: URLSessionWebSocketTask.CloseCode { get }
    var closeReason: Data? { get }
}

extension URLSessionWebSocketTask: WebSocketTasking {}

/// One open telemetry socket.
///
/// ⛔ TWO SOURCES FEED ONE STREAM OF FRAMES: the read loop (`receive()`, which yields text
/// and binary messages and, once it throws, the close code) and the ping loop (a pong is
/// a heartbeat). The delegate's `didCloseWith` is a third, for the close code. Whichever
/// reports the end first wins; everything after it is dropped, so the core sees exactly
/// one `.closed` or one failure and nothing after it.
final class URLSessionTelemetrySocket: TelemetrySocket, @unchecked Sendable {
    let selectedSubprotocol: String?

    private let task: any WebSocketTasking
    private let clock: any LiveClock
    private let onClose: @Sendable () -> Void
    private let frames: AsyncThrowingStream<TelemetrySocketFrame, any Error>
    private let sink: FrameSink

    /// ⚠️ GUARDS THE THREE BELOW. The read loop, the ping loop, the delegate's queue and the
    /// core's runner all reach this object from different threads.
    private let lock = NSLock()
    private var iterator: AsyncThrowingStream<TelemetrySocketFrame, any Error>.Iterator?
    private var loops: [Task<Void, Never>] = []
    private var closed = false

    init(
        task: any WebSocketTasking,
        selectedSubprotocol: String?,
        clock: any LiveClock,
        onClose: @escaping @Sendable () -> Void = {}
    ) {
        self.task = task
        self.selectedSubprotocol = selectedSubprotocol
        self.clock = clock
        self.onClose = onClose
        let (stream, continuation) = AsyncThrowingStream<TelemetrySocketFrame, any Error>.makeStream()
        frames = stream
        sink = FrameSink(continuation)
        iterator = stream.makeAsyncIterator()
        loops = [Self.readLoop(task: task, sink: sink), Self.pingLoop(task: task, sink: sink, clock: clock)]
    }

    /// The next frame.
    ///
    /// ⚠️ READ BY ONE CONSUMER, the core's runner, which awaits each frame before asking
    /// for the next; the iterator is taken out for the wait and put back after it, so the
    /// lock is never held across a suspension.
    func receive() async throws -> TelemetrySocketFrame {
        var current = lock.withLock { () -> AsyncThrowingStream<TelemetrySocketFrame, any Error>.Iterator? in
            defer { iterator = nil }
            return iterator
        }
        guard current != nil else { throw TelemetrySocketEnded() }
        let frame = try await current?.next()
        lock.withLock { iterator = current }
        guard let frame else { throw TelemetrySocketEnded() }
        return frame
    }

    /// Send one text message. ⚠️ A send on a socket this app closed throws without reaching
    /// the task; any other failure is the task's, and the read loop reports the break.
    func send(_ text: String) async throws {
        guard !lock.withLock({ closed }) else { throw TelemetrySocketEnded() }
        try await task.send(.string(text))
    }

    /// Close with a normal closure and stop both loops. ⚠️ Idempotent.
    func close() async {
        let running: [Task<Void, Never>]? = lock.withLock {
            guard !closed else { return nil }
            closed = true
            defer { loops = [] }
            return loops
        }
        guard let running else { return }
        running.forEach { $0.cancel() }
        task.cancel(with: .normalClosure, reason: nil)
        sink.fail(TelemetrySocketEnded())
        onClose()
    }

    /// The delegate's `didCloseWith`: the server closed the socket with `code`.
    func peerClosed(code: Int, reason: Data?) {
        sink.close(code: code, reason: reason)
    }

    /// The delegate's `didCompleteWithError` after the handshake: the socket broke.
    func broke(_ error: any Error) {
        sink.fail(error)
    }

    // MARK: - The two loops

    /// ⛔ ONCE `receive()` THROWS, `closeCode` SAYS WHETHER THE SERVER CLOSED THE SOCKET
    /// (and with what) or the connection simply broke. `.invalid` is "no close frame".
    private static func readLoop(task: any WebSocketTasking, sink: FrameSink) -> Task<Void, Never> {
        Task.detached {
            while !Task.isCancelled {
                do {
                    switch try await task.receive() {
                    case let .string(text):
                        sink.yield(.text(text))
                    case let .data(bytes):
                        sink.yield(.binary(bytes))
                    @unknown default:
                        // ⚠️ A message kind this SDK does not know is still proof of life.
                        sink.yield(.heartbeat)
                    }
                } catch {
                    let code = task.closeCode
                    if code == .invalid {
                        sink.fail(error)
                    } else {
                        sink.close(code: code.rawValue, reason: task.closeReason)
                    }
                    return
                }
            }
        }
    }

    /// ⛔ A PING EVERY ``URLSessionTelemetryTransport/pingIntervalMilliseconds``, AND A
    /// HEARTBEAT FOR EACH PONG. A ping that fails yields nothing: the read loop is the
    /// one that reports a broken socket, and a missing pong is what the core's silence
    /// watchdog exists to notice.
    private static func pingLoop(
        task: any WebSocketTasking,
        sink: FrameSink,
        clock: any LiveClock
    ) -> Task<Void, Never> {
        Task.detached {
            while true {
                guard await (try? clock.sleep(milliseconds: URLSessionTelemetryTransport.pingIntervalMilliseconds)) !=
                    nil,
                    !Task.isCancelled
                else { return }
                task.sendPing { error in
                    guard error == nil else { return }
                    sink.yield(.heartbeat)
                }
            }
        }
    }
}

/// The socket's frame stream, ended exactly once.
private final class FrameSink: @unchecked Sendable {
    private let continuation: AsyncThrowingStream<TelemetrySocketFrame, any Error>.Continuation
    private let lock = NSLock()
    private var ended = false

    init(_ continuation: AsyncThrowingStream<TelemetrySocketFrame, any Error>.Continuation) {
        self.continuation = continuation
    }

    func yield(_ frame: TelemetrySocketFrame) {
        lock.withLock {
            guard !ended else { return }
            continuation.yield(frame)
        }
    }

    /// ⚠️ A CLOSE WITH NO STATUS IS 1005, as the protocol's adapter contract says;
    /// `URLSessionWebSocketTask` reports it as `.noStatusReceived` (1005) already, and a raw
    /// 0 from a delegate is read the same way.
    func close(code: Int, reason: Data?) {
        lock.withLock {
            guard !ended else { return }
            ended = true
            let text = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            continuation.yield(.closed(code: code == 0 ? 1005 : code, reason: text))
            continuation.finish()
        }
    }

    func fail(_ error: any Error) {
        lock.withLock {
            guard !ended else { return }
            ended = true
            continuation.finish(throwing: error)
        }
    }
}

/// The socket was closed by this app, or its stream had already ended.
struct TelemetrySocketEnded: Error, Equatable {}

/// The per-socket `URLSession` delegate: the handshake, and the server's close.
///
/// ⚠️ `@unchecked Sendable` BECAUSE `URLSession` CALLS IT ON ITS OWN SERIAL QUEUE while the
/// opener waits on another thread; the two mutable values are behind one lock.
final class WebSocketDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var opening: CheckedContinuation<String?, any Error>?
    private weak var socket: URLSessionTelemetrySocket?

    func waitForOpen(_ task: URLSessionWebSocketTask) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { opening = continuation }
            task.resume()
        }
    }

    func attach(_ socket: URLSessionTelemetrySocket) {
        lock.withLock { self.socket = socket }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol selected: String?
    ) {
        takeOpening()?.resume(returning: selected)
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        if let opening = takeOpening() {
            opening.resume(throwing: URLError(.badServerResponse))
            return
        }
        lock.withLock { socket }?.peerClosed(code: closeCode.rawValue, reason: reason)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let failure = error ?? URLError(.networkConnectionLost)
        if let opening = takeOpening() {
            opening.resume(throwing: failure)
            return
        }
        lock.withLock { socket }?.broke(failure)
    }

    private func takeOpening() -> CheckedContinuation<String?, any Error>? {
        lock.withLock {
            defer { opening = nil }
            return opening
        }
    }
}
