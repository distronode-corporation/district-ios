import DistrictLive
import DistrictModel
import Foundation

/// A wait for the receptionist's answer to one note sent from the watch.
@MainActor
protocol WatchReceiptWaiting: AnyObject {
    /// The receipt for the call, or nil when none came before `milliseconds` ran out, the call
    /// ended, or the socket ended. ⛔ Closes the socket either way.
    func receipt(within milliseconds: Int64) async -> WhisperReceipt?
    /// The note was not sent: close the socket.
    func cancel()
}

/// ``WatchReceiptWaiting`` over its own `broadcast: true` telemetry socket.
///
/// ⛔ OPENED, AND CONNECTED, BEFORE THE NOTE IS SENT (xhigh review of PR #101, item 2). The
/// broadcaster relays `whisper_applied` to the sockets open at that moment and replays nothing,
/// so a socket opened after the send's reply could miss a receipt the agent answered quickly
/// (a "not used" for a call being transferred comes back at once).
///
/// ⛔ ITS OWN SOCKET, BECAUSE THE TRANSCRIPT'S CANNOT HEAR IT: the broadcaster skips a
/// `broadcast:false` socket, which is what ``LiveTranscriptModel`` opens (see ``LiveEventFeed``).
///
/// ⚠️ IT WAITS ON THE CLOCK IN SHORT STEPS, like ``WatchLiveRelay``'s snapshot wait, so a test
/// drives it with a manual clock.
@MainActor
final class TelemetryReceiptListener: WatchReceiptWaiting {
    static let pollMilliseconds: Int64 = 100

    private let runner: TelemetryConnectionRunner
    private let callId: String
    private let clock: any LiveClock
    private var pump: Task<Void, Never>?
    private(set) var connected = false
    private(set) var found: WhisperReceipt?
    /// The receipt came, the call ended, or the socket ended: nothing more to wait for.
    private(set) var finished = false

    init(runner: TelemetryConnectionRunner, callId: String, clock: any LiveClock) {
        self.runner = runner
        self.callId = callId
        self.clock = clock
    }

    /// Start the socket, and return once it is open (or `milliseconds` ran out, or it ended).
    func open(within milliseconds: Int64) async {
        let runner = runner
        pump = Task { [weak self] in
            await runner.start()
            for await update in runner.updates {
                guard let self else { return }
                handle(update)
            }
        }
        await wait(milliseconds) { $0.connected || $0.finished }
    }

    func receipt(within milliseconds: Int64) async -> WhisperReceipt? {
        await wait(milliseconds) { $0.finished }
        close()
        return found
    }

    func cancel() {
        close()
    }

    private func handle(_ update: TelemetryUpdate) {
        switch update {
        case .connected:
            connected = true
        case let .event(envelope) where envelope.callId == callId:
            if let receipt = envelope.whisperReceipt {
                found = receipt
                finished = true
            } else if envelope.eventType == .callEnded {
                finished = true
            }
        case .ended:
            finished = true
        default:
            break
        }
    }

    private func wait(_ milliseconds: Int64, until done: (TelemetryReceiptListener) -> Bool) async {
        let deadline = clock.nowMilliseconds() &+ milliseconds
        while !done(self), clock.nowMilliseconds() < deadline {
            guard await (try? clock.sleep(milliseconds: Self.pollMilliseconds)) != nil else { return }
        }
    }

    private func close() {
        finished = true
        pump?.cancel()
        pump = nil
        let runner = runner
        Task { await runner.stop() }
    }
}
