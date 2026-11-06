import DistrictData
import DistrictModel
import Foundation
import Observation

/// The workspace's calls in progress, for the Live calls screen.
///
/// ⛔ THE CALL LOG'S FIRST PAGE, FILTERED, PLUS THE TELEMETRY EVENTS, AND NEVER `calls/active`.
/// That route spreads the whole `Call` row, has no `EndpointID`, and cannot be decoded
/// strictly; the first page of the log already carries every call that started recently, and
/// ``CallDisplay/transcribesLive`` is the phone's one rule for "live" (the watch relay uses it
/// too, ``WatchLiveComposer/liveCalls(_:workspaceId:role:)``).
///
/// ⚠️ THE EVENTS DRIVE A RE-READ, NOT A PATCH. A `call_started` or `call_updated` body is the
/// raw `Call` row, not the log's projection, so it is a hint to read the page again; only a
/// `call_ended` (or a status that left `in-progress`) takes a row off at once, which is the
/// change a supervisor must not see late.
@MainActor
@Observable
final class LiveCallsModel {
    enum State {
        case loading
        case ready([CallSummary])
        /// ⛔ A FAILURE, NEVER AN EMPTY LIST: "no calls right now" is a claim about the
        /// workspace, and a read that failed cannot make it.
        case failed(FailureText)
    }

    /// The most rows read: the log's first page, newest first.
    static let pageLimit = 50
    /// How long a burst of events is gathered into one re-read.
    static let rereadDelay: Duration = .milliseconds(800)

    let workspaceId: String
    private(set) var state: State = .loading
    let events: LiveEventFeed

    private let read: @Sendable () async -> Result<[CallSummary], ApiError>
    private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var reread: Task<Void, Never>?
    @ObservationIgnored private var loading = false

    init(
        workspaceId: String,
        events: LiveEventFeed,
        read: @escaping @Sendable () async -> Result<[CallSummary], ApiError>,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.workspaceId = workspaceId
        self.events = events
        self.read = read
        self.sleep = sleep
        events.onEvent = { [weak self] in self?.received($0) }
        // ⚠️ EVERY OPEN, THE FIRST INCLUDED: anything that happened while no socket was open is
        // only in the log.
        events.onOpen = { [weak self] in self?.scheduleReread() }
    }

    convenience init(container: AppContainer, workspaceId: String) {
        let calls = container.calls
        self.init(
            workspaceId: workspaceId,
            events: LiveEventFeed(workspaceId: workspaceId, dependencies: .live(container: container)),
            read: {
                await calls.pager(workspaceId: workspaceId).loadNext(limit: LiveCallsModel.pageLimit).map(\.items)
            }
        )
    }

    var calls: [CallSummary] {
        if case let .ready(rows) = state {
            return rows
        }
        return []
    }

    /// Read the page. ⚠️ A read already on its way is not doubled.
    func load() async {
        guard !loading else { return }
        loading = true
        let result = await read()
        loading = false
        switch result {
        case let .success(rows):
            let live = rows.filter { CallDisplay($0).transcribesLive }
            state = .ready(live)
        case let .failure(error):
            // ⚠️ A RE-READ THAT FAILS KEEPS THE LIST IT HAD: the socket's events still arrive,
            // and the next one asks again.
            if case .ready = state {
                return
            }
            state = .failed(FailureText.from(error))
        }
    }

    private func received(_ envelope: TelemetryEnvelope) {
        switch envelope.eventType {
        case .callEnded:
            remove(envelope.callId)
        case .callUpdated:
            if let status = envelope.callStatus, status != CallWire.statusInProgress {
                remove(envelope.callId)
            }
            scheduleReread()
        case .callStarted:
            scheduleReread()
        default:
            break
        }
    }

    private func remove(_ callId: String) {
        guard case let .ready(rows) = state else { return }
        state = .ready(rows.filter { $0.id != callId })
    }

    private func scheduleReread() {
        reread?.cancel()
        let sleep = sleep
        reread = Task { [weak self] in
            guard await (try? sleep(Self.rereadDelay)) != nil, !Task.isCancelled else { return }
            await self?.load()
        }
    }
}
