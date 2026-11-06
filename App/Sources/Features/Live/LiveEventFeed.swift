import DistrictLive
import DistrictModel
import Foundation
import Observation

/// The workspace's call events, for the Live screens: `call_started`, `call_updated`,
/// `call_ended` and the assistant's `whisper_applied`.
///
/// ⛔ A `broadcast: true` SOCKET, AND IT HAS TO BE. The broadcaster relays the call events and
/// `whisper_applied` to the whole workspace and skips every socket that sent `socket.mode`
/// `broadcast:false` (`telemetry-broadcaster/index.ts`), which is what the call screen's
/// transcript socket sends. So the receipt never reaches ``LiveTranscriptModel``, and this
/// separate socket is the one that hears it.
///
/// ⛔ IT DECIDES NOTHING ABOUT THE SOCKET. `TelemetryConnectionRunner` (district-core-swift)
/// owns the credential, the renewal, the close codes and the reconnects; this opens one for a
/// screen and hands each envelope to ``onEvent``.
///
/// ⚠️ ONLY WHILE A LIVE SCREEN IS SHOWN AND THE APP IS IN FRONT, like the transcript's socket:
/// the screen calls ``activate()`` and ``deactivate()``. A supervision that outlives its screen
/// still learns that the call ended, from the room emptying (`SuperviseSession`).
@MainActor
@Observable
final class LiveEventFeed {
    /// Where the socket stands, for the reconnecting line.
    enum Connection: Equatable {
        case idle
        case connecting
        case open
        /// The socket ended for good: the screen keeps what it has and says nothing more.
        case failed
    }

    /// What a test replaces.
    struct Dependencies {
        let minter: any TelemetryTokenMinter
        let transport: any TelemetrySocketTransport
        let clock: any LiveClock
        let jitter: @Sendable () -> Double
    }

    let workspaceId: String
    private(set) var connection: Connection = .idle
    /// Whether an open socket was lost and is being reopened: the line the website shows over
    /// its feed, so an outage never reads as "no calls".
    private(set) var reconnecting = false

    /// Told every envelope the socket delivers. ⚠️ Set by the screen's model before it activates.
    @ObservationIgnored var onEvent: (@MainActor (TelemetryEnvelope) -> Void)?
    /// Told each time a socket opens, the first included: a model re-reads what it may have missed.
    @ObservationIgnored var onOpen: (@MainActor () -> Void)?

    private let dependencies: Dependencies
    @ObservationIgnored private var runner: TelemetryConnectionRunner?
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private var everOpened = false

    init(workspaceId: String, dependencies: Dependencies) {
        self.workspaceId = workspaceId
        self.dependencies = dependencies
    }

    /// Open the socket, unless one is open.
    func activate() {
        guard runner == nil else { return }
        let runner = TelemetryConnectionRunner(
            workspaceId: workspaceId,
            broadcast: true,
            minter: dependencies.minter,
            transport: dependencies.transport,
            clock: dependencies.clock,
            jitter: dependencies.jitter
        )
        self.runner = runner
        connection = .connecting
        pump = Task { [weak self] in
            await runner.start()
            for await update in runner.updates {
                guard let self else { return }
                handle(update)
            }
        }
    }

    /// Close the socket. What the screen shows stays.
    func deactivate() {
        reconnecting = false
        everOpened = false
        if connection != .failed {
            connection = .idle
        }
        guard let runner else { return }
        self.runner = nil
        pump?.cancel()
        pump = nil
        Task { await runner.stop() }
    }

    private func handle(_ update: TelemetryUpdate) {
        switch update {
        case .connected:
            connection = .open
            reconnecting = false
            everOpened = true
            onOpen?()
        case let .event(envelope):
            onEvent?(envelope)
        case .discarded:
            break
        case .reconnecting:
            connection = .connecting
            // ⚠️ ONLY AFTER A SOCKET WAS OPEN: the first connect is "loading", not "lost".
            reconnecting = everOpened
        case let .ended(error):
            runner = nil
            pump = nil
            reconnecting = false
            connection = error == nil ? .idle : .failed
        }
    }
}

extension LiveEventFeed.Dependencies {
    /// The app's own: the session's API client, the real socket and clock.
    @MainActor
    static func live(container: AppContainer) -> Self {
        Self(
            minter: container.api,
            transport: URLSessionTelemetryTransport(),
            clock: SystemLiveClock(),
            jitter: TelemetryConnectionRunner.randomJitter
        )
    }
}
