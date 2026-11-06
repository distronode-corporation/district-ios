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

    /// One page of the log, newest first.
    nonisolated static let pageLimit = 50
    /// The most pages read for one list.
    nonisolated static let maxPages = 10
    /// How old a call may be and still be live. ⚠️ A page whose oldest row is older than this
    /// cannot hold a live call further down, so reading stops there (xhigh review of PR #101,
    /// item 10: the first page alone missed a live call behind 50 newer ones).
    nonisolated static let liveWindowSeconds: TimeInterval = 4 * 60 * 60
    /// How long a burst of events is gathered into one re-read.
    static let rereadDelay: Duration = .milliseconds(800)

    let workspaceId: String
    private(set) var state: State = .loading
    let events: LiveEventFeed

    private let read: @Sendable () async -> Result<[CallSummary], ApiError>
    private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var reread: Task<Void, Never>?
    @ObservationIgnored private var loading = false
    /// A read was asked for while one was on its way. ⛔ It runs once that one lands: the read
    /// on its way may have been answered before the event that asked for this one.
    @ObservationIgnored private var readAgain = false
    /// Every call the socket said has ended. ⛔ FILTERED OUT OF EVERY LATER READ (Seer, PR #101):
    /// a read answered before the end would otherwise put the call back as live, and an ended call
    /// never becomes live again.
    @ObservationIgnored private var ended: Set<String> = []

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
                await LiveCallsModel.readLive(pager: calls.pager(workspaceId: workspaceId), now: Date())
            }
        )
    }

    /// Read the log's pages, newest first, until one ends older than any live call, the log
    /// ends, or ``maxPages`` were read. ⛔ NO NEW API FIELD: the same call-log route and pager.
    ///
    /// ⚠️ A FAILURE AFTER THE FIRST PAGE KEEPS WHAT WAS READ: the newest calls are already in it,
    /// and the socket's next event asks again.
    nonisolated static func readLive(
        pager: OffsetPager<CallSummary>,
        now: Date
    ) async -> Result<[CallSummary], ApiError> {
        var rows: [CallSummary] = []
        for page in 0 ..< maxPages {
            switch await pager.loadNext(limit: pageLimit) {
            case let .failure(error):
                return page == 0 ? .failure(error) : .success(rows)
            case let .success(slice):
                rows += slice.items
                if slice.isEnd {
                    return .success(rows)
                }
                let oldest = slice.items.last.flatMap { WireInstant.parse($0.createdAt) }
                if let oldest, now.timeIntervalSince(oldest) > liveWindowSeconds {
                    return .success(rows)
                }
            }
        }
        return .success(rows)
    }

    var calls: [CallSummary] {
        if case let .ready(rows) = state {
            return rows
        }
        return []
    }

    /// Read the page. ⚠️ A read already on its way is not doubled, and NOT DROPPED either: one
    /// more read follows it (Seer, PR #101), however many were asked for meanwhile.
    func load() async {
        guard !loading else {
            readAgain = true
            return
        }
        loading = true
        repeat {
            readAgain = false
            await apply(read())
        } while readAgain
        loading = false
    }

    private func apply(_ result: Result<[CallSummary], ApiError>) {
        switch result {
        case let .success(rows):
            let live = rows.filter { CallDisplay($0).transcribesLive && !ended.contains($0.id) }
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
            remove(envelope.callId, ended: true)
        case .callUpdated:
            // ⚠️ OFF THE LIST UNLESS IN PROGRESS, BUT REMEMBERED AS ENDED ONLY WHEN IT IS: a call
            // still ringing comes back with the next read once it is answered.
            if let status = envelope.callStatus, status != CallWire.statusInProgress {
                remove(envelope.callId, ended: CallWire.hasEnded(status))
            }
            scheduleReread()
        case .callStarted:
            scheduleReread()
        default:
            break
        }
    }

    private func remove(_ callId: String, ended isOver: Bool) {
        if isOver {
            ended.insert(callId)
        }
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
