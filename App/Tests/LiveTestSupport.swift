@testable import DistrictAI
import DistrictLive
import DistrictModel
import Foundation

/// A `LiveClock` that never waits for real: a sleep returns when the test advances the clock
/// past its deadline, or throws when its task is cancelled. Ported from district-macos's
/// `LiveTestSupport.swift`.
final class ManualLiveClock: LiveClock, @unchecked Sendable {
    private struct Sleeper {
        let id: UUID
        let deadline: Int64
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var now: Int64
    private var sleepers: [Sleeper] = []

    init(startingAt now: Int64 = 1_790_000_000_000) {
        self.now = now
    }

    func nowMilliseconds() -> Int64 {
        lock.withLock { now }
    }

    func sleep(milliseconds: Int64) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let due: Bool = lock.withLock {
                    if milliseconds <= 0 {
                        return true
                    }
                    sleepers.append(Sleeper(id: id, deadline: now + milliseconds, continuation: continuation))
                    return false
                }
                if due {
                    continuation.resume()
                }
            }
        } onCancel: {
            let cancelled: Sleeper? = lock.withLock {
                guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return sleepers.remove(at: index)
            }
            cancelled?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Move time forward, waking every sleep whose deadline has passed.
    func advance(by milliseconds: Int64) {
        let woken: [Sleeper] = lock.withLock {
            now += milliseconds
            let due = sleepers.filter { $0.deadline <= now }
            sleepers.removeAll { $0.deadline <= now }
            return due
        }
        woken.forEach { $0.continuation.resume() }
    }
}

/// A `URLSessionWebSocketTask` stand-in: messages and failures are pushed by the test, sends
/// are recorded, pings are answered at once with a pong. Ported from district-macos, with
/// `send` added.
final class FakeWebSocketTask: WebSocketTasking, @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [Result<URLSessionWebSocketTask.Message, any Error>] = []
    private var waiting: CheckedContinuation<URLSessionWebSocketTask.Message, any Error>?
    private var cancels: [URLSessionWebSocketTask.CloseCode] = []
    private var texts: [String] = []
    private var code: URLSessionWebSocketTask.CloseCode = .invalid
    private var reason: Data?

    var cancelCodes: [URLSessionWebSocketTask.CloseCode] {
        lock.withLock { cancels }
    }

    /// Every text this app sent, in order.
    var sent: [String] {
        lock.withLock { texts }
    }

    var closeCode: URLSessionWebSocketTask.CloseCode {
        lock.withLock { code }
    }

    var closeReason: Data? {
        lock.withLock { reason }
    }

    /// The server's close: the code `closeCode` reports from now on, and a failed read.
    func serverClosed(code: Int, reason: String = "") {
        lock.withLock {
            self.code = URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .invalid
            self.reason = Data(reason.utf8)
        }
        push(.failure(URLError(.networkConnectionLost)))
    }

    /// The server sends `text`.
    func deliver(_ text: String) {
        push(.success(.string(text)))
    }

    func push(_ result: Result<URLSessionWebSocketTask.Message, any Error>) {
        let reader: CheckedContinuation<URLSessionWebSocketTask.Message, any Error>? = lock.withLock {
            guard let reader = waiting else {
                queued.append(result)
                return nil
            }
            waiting = nil
            return reader
        }
        reader?.resume(with: result)
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { continuation in
            let next: Result<URLSessionWebSocketTask.Message, any Error>? = lock.withLock {
                guard !queued.isEmpty else {
                    waiting = continuation
                    return nil
                }
                return queued.removeFirst()
            }
            if let next {
                continuation.resume(with: next)
            }
        }
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        guard case let .string(text) = message else { return }
        lock.withLock { texts.append(text) }
    }

    func sendPing(pongReceiveHandler: @escaping @Sendable ((any Error)?) -> Void) {
        pongReceiveHandler(nil)
    }

    /// ⚠️ A CANCELLED TASK'S PENDING READ FAILS, as the real one's does, so the adapter's read
    /// loop ends rather than waiting forever on a socket nobody will write to.
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        lock.withLock { cancels.append(closeCode) }
        push(.failure(URLError(.cancelled)))
    }
}

/// The credential mint: a fresh fifteen-minute credential each time unless the test scripted
/// another answer, and a count of the calls.
final class ScriptedMinter: TelemetryTokenMinter, @unchecked Sendable {
    private let lock = NSLock()
    private let clock: ManualLiveClock
    private var scripted: [Result<TelemetryTokenResponse, ApiError>]
    private var calls = 0

    init(clock: ManualLiveClock, scripted: [Result<TelemetryTokenResponse, ApiError>] = []) {
        self.clock = clock
        self.scripted = scripted
    }

    var count: Int {
        lock.withLock { calls }
    }

    func mintTelemetryToken(workspaceId _: String) async -> Result<TelemetryTokenResponse, ApiError> {
        let now = clock.nowMilliseconds()
        return lock.withLock {
            calls += 1
            guard scripted.isEmpty else { return scripted.removeFirst() }
            return .success(TelemetryTokenResponse(
                success: true,
                token: "a.b.c",
                expiresAt: now + 15 * 60 * 1000,
                wsUrl: "wss://telemetry.example.test/ws/telemetry"
            ))
        }
    }
}

/// Every socket the adapter opens, each over its own fake task, with what it was opened with.
final class SocketScript: @unchecked Sendable {
    private struct Opened {
        let url: URL
        let protocols: [String]
        let task: FakeWebSocketTask
    }

    private let lock = NSLock()
    private var opened: [Opened] = []

    var tasks: [FakeWebSocketTask] {
        lock.withLock { opened.map(\.task) }
    }

    var protocols: [[String]] {
        lock.withLock { opened.map(\.protocols) }
    }

    var urls: [URL] {
        lock.withLock { opened.map(\.url) }
    }

    /// The real adapter, over a fake task per socket.
    func transport(clock: ManualLiveClock) -> URLSessionTelemetryTransport {
        URLSessionTelemetryTransport(clock: clock) { [self] url, protocols in
            let task = FakeWebSocketTask()
            lock.withLock { opened.append(Opened(url: url, protocols: protocols, task: task)) }
            return OpenedWebSocket(
                task: task,
                selectedSubprotocol: TelemetryProtocol.subprotocol,
                delegate: nil,
                onClose: {}
            )
        }
    }
}

/// Answers for the full-transcript fetch, in order; the last one repeats.
final class ScriptedTranscripts: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [Result<String, ApiError>]
    private var calls = 0

    init(_ answers: [Result<String, ApiError>]) {
        self.answers = answers
    }

    var count: Int {
        lock.withLock { calls }
    }

    func next() -> Result<String, ApiError> {
        lock.withLock {
            calls += 1
            return answers.count > 1 ? answers.removeFirst() : answers[0]
        }
    }
}

/// The contract's frames (§4.11), as the server sends them.
enum TranscriptWire {
    static let workspaceId = "ws_1"
    static let callId = "call_1"
    static let epoch: Int64 = 1_791_297_000_000

    static let mode = #"{"op":"socket.mode","v":1,"broadcast":false}"#
    static let subscribe = #"{"op":"transcript.subscribe","v":1,"callId":"call_1"}"#

    static func envelope(_ eventType: String, _ data: String) -> String {
        #"{"workspaceId":"ws_1","callId":"call_1","eventType":"\#(eventType)","data":\#(data),"#
            + #""timestamp":"2026-10-06T14:30:02.010Z"}"#
    }

    static func segment(
        _ segmentId: String,
        index: Int,
        seq: Int,
        epoch: Int64 = epoch,
        speaker: String = "caller",
        text: String,
        final: Bool = true,
        interrupted: Bool = false
    ) -> String {
        let name = speaker == "agent" ? #""Ava""# : "null"
        return #"{"segmentId":"\#(segmentId)","index":\#(index),"epoch":\#(epoch),"seq":\#(seq),"rev":0,"#
            + #""speaker":"\#(speaker)","speakerName":\#(name),"text":"\#(text)","final":\#(final),"#
            + #""interrupted":\#(interrupted),"language":"en","startedAt":"2026-10-06T14:30:03.100Z","#
            + #""endedAt":\#(final ? #""2026-10-06T14:30:06.300Z""# : "null")}"#
    }

    static func live(_ segment: String) -> String {
        envelope("transcript_segment", #"{"v":1,"callId":"call_1","segment":\#(segment)}"#)
    }

    /// ⚠️ NEVER EMPTY WITH `lastSeq: 0`: the server holds a subscribe until the first line
    /// exists and answers with a snapshot that has it (contract §4.12 Q4).
    static func snapshot(
        _ segments: [String],
        lastSeq: Int,
        epoch: Int64 = epoch,
        live: Bool = true,
        complete: Bool = true
    ) -> String {
        envelope(
            "transcript_snapshot",
            #"{"v":1,"callId":"call_1","live":\#(live),"complete":\#(complete),"epoch":\#(epoch),"#
                + #""lastSeq":\#(lastSeq),"segments":[\#(segments.joined(separator: ","))],"part":0,"more":false}"#
        )
    }

    static func ended(seq: Int, epoch: Int64 = epoch, reason: String = "call_ended") -> String {
        envelope(
            "transcript_ended",
            #"{"v":1,"callId":"call_1","epoch":\#(epoch),"seq":\#(seq),"lastIndex":1,"reason":"\#(reason)"}"#
        )
    }

    /// The §4.11 greeting, which the opening snapshot carries.
    static let greeting = segment("item_a1", index: 0, seq: 1, speaker: "agent", text: "Good afternoon.")

    static func error(_ code: String) -> String {
        envelope(
            "transcript_error",
            #"{"v":1,"callId":"call_1","op":"transcript.subscribe","code":"\#(code)","retryAfterMs":null}"#
        )
    }
}
