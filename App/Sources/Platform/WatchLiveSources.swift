import DistrictData
import DistrictLive
import DistrictModel
import Foundation

/// What ``WatchLiveRelay`` reads and writes through, behind a seam so a test can stand in for
/// the server.
@MainActor
protocol WatchLiveSourcing {
    /// The workspace's calls in progress, from the call log the phone already reads.
    func liveCalls(workspaceId: String, now: Date) async -> Result<[WatchLiveCall], WatchActionFailure>
    /// One call as the after-call card shows it.
    func card(workspaceId: String, callId: String, now: Date) async -> Result<WatchCallCard, WatchActionFailure>
    /// One line for the assistant.
    func whisper(workspaceId: String, callId: String, text: String) async -> Result<Void, WatchActionFailure>
    /// A transcript feed for one call, not yet activated.
    func feed(workspaceId: String, callId: String) -> any WatchLiveTranscriptFeed
    /// A feed is about to open a socket: the next credential may come from the cache.
    func willActivate() async
}

/// One call's live transcript as the relay drives it: ``LiveTranscriptModel``, the call
/// screen's own model, behind a seam.
///
/// ⛔ THE SAME MODEL AS THE CALL SCREEN, NOT A SECOND READER OF THE SOCKET. Every rule about
/// frames, gaps, snapshots and the end is `TranscriptReducer`'s, in district-core-swift, and
/// the model already performs it; the relay only decides when the socket is open.
@MainActor
protocol WatchLiveTranscriptFeed: AnyObject {
    var lines: [TranscriptSegment] { get }
    var phase: LiveTranscriptPhase { get }
    var complete: Bool { get }
    var connection: LiveTranscriptModel.Connection { get }
    var fallsBack: Bool { get }
    /// How many whole snapshots have arrived: the relay's sign that a subscribe was answered.
    var snapshotsReceived: Int { get }
    func activate()
    func deactivate()
    func callShownInProgress()
}

extension LiveTranscriptModel: WatchLiveTranscriptFeed {}

/// Steering: `POST /api/district/calls/whisper`, a seam so a test can stand in for the server.
///
/// ⚠️ THE CORE'S `CallsRepository.whisper` (district-core-swift 8.0.0) IS THE ONE CONFORMANCE.
/// The app never builds a request by hand: the core's `EndpointID` table is the one list of
/// what it calls.
protocol WhisperSending: Sendable {
    func whisper(workspaceId: String, callId: String, text: String) async -> Result<Void, ApiError>
}

extension CallsRepository: WhisperSending {}

/// The relay's reads, from the container's repositories and session.
///
/// ⛔ THE CONTAINER'S OWN API CLIENT AND REPOSITORIES, like ``ContainerWatchSnapshotSource``:
/// one ``TokenRefreshCoordinator`` per process.
@MainActor
final class ContainerWatchLiveSources: WatchLiveSourcing {
    private unowned let container: AppContainer
    private let whisperSender: any WhisperSending
    private let minter: CachingTelemetryMinter

    /// - Parameter whisper: ⛔ NO DEFAULT, so nothing can build this without a real sender;
    ///   `AppContainer.watchBridge` passes the container's own ``AppContainer/calls``.
    init(container: AppContainer, whisper: any WhisperSending) {
        self.container = container
        whisperSender = whisper
        minter = CachingTelemetryMinter(upstream: container.api, clock: SystemLiveClock())
    }

    /// ⛔ THE CALL LOG, FILTERED, NOT A NEW ENDPOINT. `calls/active` has no `EndpointID` and
    /// answers whole `Call` rows; the first page of the log already carries every call that
    /// started recently, and ``CallDisplay/transcribesLive`` is the phone's own rule for "live".
    func liveCalls(workspaceId: String, now _: Date) async -> Result<[WatchLiveCall], WatchActionFailure> {
        let workspaces = WorkspaceSessionModel(container: container)
        async let listed: Void = workspaces.load()
        let page = await container.calls.pager(workspaceId: workspaceId).loadNext(limit: WatchSnapshot.listLimit)
        await listed
        // ⛔ A ROLE THAT COULD NOT BE READ STEERS NOTHING: `allowsMutation(nil)` is false.
        let role = WorkspaceRole.fromWire(workspaces.workspaces.first { $0.id == workspaceId }?.role)
        return page
            .map { WatchLiveComposer.liveCalls($0.items, workspaceId: workspaceId, role: role) }
            .mapError { WatchActionFailure(sentence: FailureText.from($0).message) }
    }

    func card(workspaceId: String, callId: String, now: Date) async -> Result<WatchCallCard, WatchActionFailure> {
        await container.calls.detail(workspaceId: workspaceId, callId: callId)
            .map {
                WatchLiveComposer.card($0, workspaceId: workspaceId, now: now, language: WatchBridgeLanguage.current)
            }
            .mapError { WatchLiveComposer.cardFailure($0) }
    }

    func whisper(workspaceId: String, callId: String, text: String) async -> Result<Void, WatchActionFailure> {
        await whisperSender.whisper(workspaceId: workspaceId, callId: callId, text: text)
            .mapError { WatchLiveComposer.whisperFailure($0) }
    }

    func feed(workspaceId: String, callId: String) -> any WatchLiveTranscriptFeed {
        let calls = container.calls
        return LiveTranscriptModel(
            workspaceId: workspaceId,
            callId: callId,
            dependencies: LiveTranscriptModel.Dependencies(
                minter: minter,
                transport: URLSessionTelemetryTransport(),
                clock: SystemLiveClock(),
                jitter: TelemetryConnectionRunner.randomJitter,
                fetchTranscript: { await calls.transcript(workspaceId: workspaceId, callId: callId) }
            )
        )
    }

    func willActivate() async {
        await minter.beginActivation()
    }
}

/// Telemetry credentials, reused across the relay's short sockets.
///
/// ⛔ THE MINT IS RATE-LIMITED TO 30 A MINUTE PER ACCOUNT (`POST telemetry/token`), and the
/// snapshot relay opens a socket every 5 s: minting for each would spend 12 of them a minute
/// on one wrist. A credential lives 15 min, so it is kept while it has more than
/// ``reuseMarginMilliseconds`` left.
///
/// ⚠️ ONCE PER ACTIVATION. A second mint within one activation means the server refused the
/// first credential (4401: mint again), and handing back the same one would loop; it goes to
/// the server.
actor CachingTelemetryMinter: TelemetryTokenMinter {
    /// Twice the connection's own renewal lead, so a reused credential is never one the
    /// connection would renew at once.
    static let reuseMarginMilliseconds = 2 * TelemetryProtocol.renewalLeadMilliseconds

    private let upstream: any TelemetryTokenMinter
    private let clock: any LiveClock
    private var cached: [String: TelemetryTokenResponse] = [:]
    private var served: Set<String> = []

    init(upstream: any TelemetryTokenMinter, clock: any LiveClock) {
        self.upstream = upstream
        self.clock = clock
    }

    func beginActivation() {
        served = []
    }

    func mintTelemetryToken(workspaceId: String) async -> Result<TelemetryTokenResponse, ApiError> {
        let reusable = cached[workspaceId].flatMap { token in
            token.expiresAt &- clock.nowMilliseconds() > Self.reuseMarginMilliseconds ? token : nil
        }
        let first = served.insert(workspaceId).inserted
        if first, let reusable {
            return .success(reusable)
        }
        let result = await upstream.mintTelemetryToken(workspaceId: workspaceId)
        cached[workspaceId] = try? result.get()
        return result
    }
}

/// Wire rows to the watch's live values. Pure, so the tests can feed it.
///
/// ⛔ THE PHONE SCREENS' OWN MAPPERS (``CallDisplay``, ``LiveTranscriptCopy``,
/// ``WatchSnapshotComposer``), so the wrist says what the phone says about the same call.
@MainActor
enum WatchLiveComposer {
    /// The longest whisper the server takes, in UTF-16 units (the route counts JavaScript
    /// string length).
    nonisolated static let whisperLimit = 2000

    static func liveCalls(_ rows: [CallSummary], workspaceId: String, role: WorkspaceRole?) -> [WatchLiveCall] {
        rows.filter { CallDisplay($0).transcribesLive }.map { row in
            let display = CallDisplay(row)
            return WatchLiveCall(
                id: row.id,
                workspaceId: workspaceId,
                caller: display.displayName.map(WatchMasking.caller) ?? display.callerLabel,
                startedAt: WireInstant.parse(row.createdAt),
                canWhisper: WorkspaceRole.allowsMutation(role)
            )
        }
    }

    static func card(_ row: CallSummary, workspaceId: String, now: Date, language: String) -> WatchCallCard {
        let display = CallDisplay(row)
        let call = WatchSnapshotComposer.call(row, now: now, language: language)
        let pending = switch display.aiSummary {
        case .absent: true
        case .text, .failed: false
        }
        return WatchCallCard(
            callId: row.id,
            workspaceId: workspaceId,
            caller: call.caller,
            outcome: call.outcome,
            time: call.time,
            summary: display.aiSummaryText,
            summaryPending: pending,
            summaryNote: display.aiSummaryNote,
            actionItems: (row.analysis?.actionItems ?? []).filter {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            },
            inProgress: display.live,
            canCallBack: callBackNumber(row) != nil
        )
    }

    /// The number "Call back" dials, or nil when there is none to dial.
    ///
    /// ⛔ THE RULE OF THE DIALLER'S "CALL THEM BACK" LIST (`CallsRepository.recentCallbacks`):
    /// an inbound call's caller, through ``CallerIdentity``. An outbound row's `from` is the
    /// workspace's own line, and a withheld caller's is an English sentence.
    static func callBackNumber(_ row: CallSummary) -> String? {
        guard row.direction == "inbound" else { return nil }
        return CallerIdentity.resolved(row.from)
    }

    static func line(_ segment: TranscriptSegment) -> WatchLiveLine {
        WatchLiveLine(
            id: segment.segmentId,
            epoch: segment.epoch,
            index: segment.index,
            speaker: LiveTranscriptCopy.speaker(segment),
            fromCaller: segment.speaker == .caller,
            text: segment.text
        )
    }

    static func phase(of feed: any WatchLiveTranscriptFeed) -> WatchLivePhase {
        if feed.fallsBack {
            return .unavailable
        }
        switch feed.phase {
        case .subscribing: return .connecting
        case .live, .reconnecting: return .live
        case .ended: return .ended
        case .unavailable: return .unavailable
        }
    }

    /// ⚠️ A 404 DOES NOT IMPLY A MALFORMED ID (see ``CallDetailModel``), so it reads as "not
    /// available", the phone's own sentence for it.
    static func cardFailure(_ error: ApiError) -> WatchActionFailure {
        guard error.httpStatus != 404 else { return WatchActionFailure(sentence: CallsCopy.callNotAvailable) }
        return WatchActionFailure(sentence: FailureText.from(error).message)
    }

    /// ⛔ A CALL THAT ENDED IS SAID AS MUCH, NOT AS A FAILURE TO SEND: the route answers 404
    /// `call_not_found` and 400 `call_not_in_progress`.
    static func whisperFailure(_ error: ApiError) -> WatchActionFailure {
        if case let .http(status, _, code) = error {
            if status == 404 || code == "call_not_in_progress" {
                return WatchActionFailure(sentence: WatchBridgeCopy.whisperCallEnded)
            }
        }
        return WatchActionFailure(sentence: FailureText.from(error).message)
    }
}
