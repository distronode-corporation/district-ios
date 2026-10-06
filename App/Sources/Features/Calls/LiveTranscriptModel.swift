import DistrictLive
import DistrictModel
import Foundation
import Observation

/// The live transcript of one call in progress, for the call's screen.
///
/// ⛔ IT DECIDES NOTHING ABOUT THE TRANSCRIPT OR THE SOCKET. `TranscriptReducer` (what the
/// frames mean) and `TelemetryConnectionRunner` (the socket, its renewal, its close codes and
/// re-sending the subscribe on every open) are district-core-swift's, tested on Linux. This
/// object starts and stops a socket for the screen, feeds the reducer what arrives, performs
/// the reducer's commands on the clock, and publishes the state for the view.
///
/// ⛔ THE SOCKET IS THIS SCREEN'S, AND IT RUNS ONLY WHILE THE SCREEN IS SHOWN AND THE APP IS
/// IN FRONT. ``activate()`` when the screen appears or the scene becomes active,
/// ``deactivate()`` when it disappears or the scene goes to the background: a phone holds no
/// socket for a screen nobody is looking at, and a socket left open in the background is
/// killed by the system anyway. Coming back opens a new socket, whose subscribe brings a
/// snapshot that replaces what is on screen.
///
/// ⚠️ `broadcast: false`, SENT AS `socket.mode` ON EVERY OPEN: this socket wants only its
/// call's transcript, not the workspace's call and message events.
@MainActor
@Observable
final class LiveTranscriptModel {
    /// Where the socket stands, for the line under the heading.
    enum Connection: Equatable {
        /// No socket: not yet activated, or deactivated.
        case idle
        /// Opening, or reopening after a gap.
        case connecting
        case open
        /// The socket ended for good (the server refused the member, or no credential could
        /// be minted). The screen falls back to the transcript after the call.
        case failed
    }

    let workspaceId: String
    let callId: String

    private(set) var lines: [TranscriptSegment] = []
    private(set) var phase: LiveTranscriptPhase = .subscribing
    private(set) var complete = true
    private(set) var finalTranscript: FinalTranscriptState = .notRequested
    private(set) var connection: Connection = .idle

    /// Whether the screen should show the transcript after the call instead (the server
    /// has no live transcript for this call, or the socket cannot be had).
    var fallsBack: Bool {
        if case .unavailable = phase {
            return true
        }
        return connection == .failed
    }

    /// What a test replaces: how a socket is made, how the full transcript is fetched, and
    /// the time.
    struct Dependencies {
        let minter: any TelemetryTokenMinter
        let transport: any TelemetrySocketTransport
        let clock: any LiveClock
        let jitter: @Sendable () -> Double
        let fetchTranscript: @Sendable () async -> Result<String, ApiError>
    }

    private let dependencies: Dependencies
    private var reducer: TranscriptReducer
    private var runner: TelemetryConnectionRunner?
    private var pump: Task<Void, Never>?
    private var timers: [Timer: Task<Void, Never>] = [:]
    /// Set once the call no longer needs a socket (the full transcript is in, or the live
    /// one is unavailable), so a later activation opens none.
    private var finished = false

    private enum Timer: Hashable {
        case resubscribe
        case gap
        case fetch
    }

    init(workspaceId: String, callId: String, dependencies: Dependencies) {
        self.workspaceId = workspaceId
        self.callId = callId
        self.dependencies = dependencies
        reducer = TranscriptReducer(callId: callId)
    }

    // MARK: - The screen's lifecycle

    /// The screen is shown and the app is in front: open a socket, unless one is open, or
    /// resume fetching the full transcript if that is where it stood.
    func activate() {
        if case .fetching = finalTranscript {
            schedule(.fetch, after: 0) { [weak self] in await self?.fetchFinal() }
            return
        }
        guard !finished, runner == nil else { return }
        let runner = TelemetryConnectionRunner(
            workspaceId: workspaceId,
            broadcast: false,
            minter: dependencies.minter,
            transport: dependencies.transport,
            clock: dependencies.clock,
            jitter: dependencies.jitter
        )
        self.runner = runner
        connection = .connecting
        let callId = callId
        pump = Task { [weak self] in
            await runner.subscribeTranscript(callId: callId)
            await runner.start()
            for await update in runner.updates {
                guard let self else { return }
                handle(update)
            }
        }
    }

    /// The screen went away or the app went to the background: close the socket and stop
    /// every wait. What is on screen stays.
    func deactivate() {
        closeSocket()
        cancelTimers()
        if connection != .failed {
            connection = .idle
        }
    }

    // MARK: - The socket

    private func handle(_ update: TelemetryUpdate) {
        switch update {
        case .connected:
            // ⚠️ EVERY OPEN, THE FIRST INCLUDED: the runner has sent the subscribe on it, so a
            // snapshot is coming, and anything half-received on an earlier socket is stale.
            connection = .open
            reducer.reconnected()
            cancel(.gap)
        case let .event(envelope):
            guard let event = envelope.transcriptEvent else { return }
            perform(reducer.apply(event, atMilliseconds: dependencies.clock.nowMilliseconds()))
        case .discarded:
            break
        case .reconnecting:
            connection = .connecting
        case let .ended(error):
            runner = nil
            connection = error == nil ? .idle : .failed
        }
        publish()
    }

    private func perform(_ commands: [TranscriptCommand]) {
        for command in commands {
            switch command {
            case let .resubscribe(delay):
                schedule(.resubscribe, after: delay) { [weak self] in
                    guard let self else { return }
                    await runner?.resubscribeTranscript(callId: callId)
                }
            case let .checkGap(delay):
                schedule(.gap, after: delay) { [weak self] in
                    guard let self else { return }
                    perform(reducer.gapCheck(atMilliseconds: dependencies.clock.nowMilliseconds()))
                    publish()
                }
            case let .fetchFinal(delay):
                schedule(.fetch, after: delay) { [weak self] in await self?.fetchFinal() }
            case .unsubscribe:
                // ⚠️ THE SOCKET IS THIS CALL'S ALONE, so nothing more wanted from it means
                // closing it. See ``closeSocket()`` for why no unsubscribe is sent first.
                finished = true
                closeSocket()
            }
        }
    }

    private func fetchFinal() async {
        let result = await dependencies.fetchTranscript()
        perform(reducer.finalFetched(result))
        publish()
    }

    /// ⚠️ NO `transcript.unsubscribe` BEFORE THE CLOSE: the server keeps subscriptions per
    /// socket and drops them with it, and an op sent just before the close would race it
    /// (measured: the close won, and the send failed on a closed socket).
    private func closeSocket() {
        guard let runner else { return }
        self.runner = nil
        pump?.cancel()
        pump = nil
        Task { await runner.stop() }
    }

    private func publish() {
        lines = reducer.lines
        phase = reducer.phase
        complete = reducer.complete
        finalTranscript = reducer.finalTranscript
    }

    // MARK: - Waits

    /// Run `work` after `milliseconds` on the clock, replacing any pending wait of `timer`'s
    /// kind.
    private func schedule(_ timer: Timer, after milliseconds: Int64, _ work: @escaping @MainActor () async -> Void) {
        timers[timer]?.cancel()
        let clock = dependencies.clock
        timers[timer] = Task {
            guard await (try? clock.sleep(milliseconds: milliseconds)) != nil, !Task.isCancelled else { return }
            await work()
        }
    }

    private func cancel(_ timer: Timer) {
        timers.removeValue(forKey: timer)?.cancel()
    }

    private func cancelTimers() {
        timers.values.forEach { $0.cancel() }
        timers = [:]
    }
}

extension LiveTranscriptModel.Dependencies {
    /// The app's own: the session's API client, the real socket and clock, and the call's
    /// transcript route.
    @MainActor
    static func live(container: AppContainer, workspaceId: String, callId: String) -> Self {
        let calls = container.calls
        return Self(
            minter: container.api,
            transport: URLSessionTelemetryTransport(),
            clock: SystemLiveClock(),
            jitter: TelemetryConnectionRunner.randomJitter,
            fetchTranscript: { await calls.transcript(workspaceId: workspaceId, callId: callId) }
        )
    }
}
