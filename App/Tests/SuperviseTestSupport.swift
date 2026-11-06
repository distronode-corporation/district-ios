@testable import DistrictAI
import DistrictCall
import DistrictLive
import DistrictModel
import DistrictNetwork
import Foundation

/// The device as a supervision sees it, recording every step in order.
///
/// ⚠️ ONE LOG FOR CALLKIT AND THE ENGINES TOGETHER, because the order across them is the
/// contract: the start before the seat, the listen room left before the coach room is joined.
@MainActor
final class FakeSuperviseMedia: SuperviseMedia {
    var hasLiveCall = false
    var hasLiveRoom = false
    let fakeMicrophone: FakeMicrophoneAccess
    private(set) var log: [String] = []
    private(set) var handler: ((CallKitRequest) -> Void)?
    private(set) var uuid: UUID?
    private(set) var onRefused: (@MainActor @Sendable () -> Void)?
    /// Every engine built, in order: a test can speak as one the session has already left.
    private(set) var engines: [(leg: SuperviseLeg, events: AsyncStream<CallEngineEvent>.Continuation)] = []

    init(microphone: FakeMicrophoneAccess = FakeMicrophoneAccess(status: .granted)) {
        fakeMicrophone = microphone
    }

    var microphone: any MicrophoneAccess {
        fakeMicrophone
    }

    var isClaimed: Bool {
        handler != nil
    }

    func claim(_: AnyObject, handler: @escaping (CallKitRequest) -> Void) {
        log.append("claim")
        self.handler = handler
    }

    func release(_: AnyObject) {
        log.append("release")
        handler = nil
    }

    func startCall(uuid: UUID, handle: String, onRefused: @escaping @MainActor @Sendable () -> Void) {
        log.append("start \(handle)")
        self.uuid = uuid
        self.onRefused = onRefused
    }

    func reportConnecting(uuid _: UUID, callerName: String) {
        log.append("connecting \(callerName)")
    }

    func reportConnected(uuid _: UUID) {
        log.append("connected")
    }

    func requestEnd(uuid _: UUID) {
        log.append("requestEnd")
    }

    func reportEnded(uuid _: UUID) {
        log.append("reportEnded")
    }

    func requestMuted(uuid _: UUID, muted: Bool) {
        log.append("requestMuted \(muted)")
    }

    func beginLeg(_ leg: SuperviseLeg) async -> AsyncStream<CallEngineEvent> {
        log.append("beginLeg \(leg)")
        let (stream, continuation) = AsyncStream<CallEngineEvent>.makeStream()
        engines.append((leg, continuation))
        return stream
    }

    /// When set, a connect waits here until the test lets it go (a join still in flight).
    var holdsConnect = false
    private var heldConnect: CheckedContinuation<Void, Never>?

    var isHoldingConnect: Bool {
        heldConnect != nil
    }

    func releaseConnect() {
        let held = heldConnect
        heldConnect = nil
        held?.resume()
    }

    func perform(_ command: CallCommand) async {
        switch command {
        case let .connect(url, token):
            log.append("connect \(url) \(token)")
            if holdsConnect {
                await withCheckedContinuation { heldConnect = $0 }
            }
        case .disconnect: log.append("disconnect")
        case let .setMuted(muted): log.append("setMuted \(muted)")
        case let .setSpeakerphone(enabled): log.append("speaker \(enabled)")
        }
    }

    func endLeg() {
        log.append("endLeg")
    }

    /// What the OS does next: performs the start, ends the call, moves its mute control.
    func system(_ request: CallKitRequest) {
        handler?(request)
    }

    /// The OS performed the start this fake was asked for.
    func performStart() {
        guard let uuid else { return }
        system(.dialRequested(uuid: uuid))
    }

    /// The newest engine for `leg` reports something.
    func engine(_ leg: SuperviseLeg, _ event: CallEngineEvent) {
        engines.last { $0.leg == leg }?.events.yield(event)
    }

    /// The `index`th engine built reports something, current or not.
    func engine(at index: Int, _ event: CallEngineEvent) {
        engines[index].events.yield(event)
    }

    func clearLog() {
        log = []
    }
}

/// The three routes, answered as the test says, with what each was asked.
final class FakeSuperviseServer: SuperviseServing, @unchecked Sendable {
    private let lock = NSLock()
    private var monitorResults: [Result<CallMonitorResponse, ApiError>] = []
    private var takeoverResults: [Result<CallTakeoverResponse, ApiError>] = []
    private var whisperResults: [Result<Void, ApiError>] = []
    private var asked: [String] = []
    /// When set, a whisper waits here until the test resumes it.
    private var whisperGate: CheckedContinuation<Void, Never>?
    var holdsWhispers = false

    var requests: [String] {
        lock.withLock { asked }
    }

    func answerMonitor(_ result: Result<CallMonitorResponse, ApiError>) {
        lock.withLock { monitorResults.append(result) }
    }

    func answerTakeover(_ result: Result<CallTakeoverResponse, ApiError>) {
        lock.withLock { takeoverResults.append(result) }
    }

    func answerWhisper(_ result: Result<Void, ApiError>) {
        lock.withLock { whisperResults.append(result) }
    }

    func releaseWhisper() {
        let gate: CheckedContinuation<Void, Never>? = lock.withLock {
            defer { whisperGate = nil }
            return whisperGate
        }
        gate?.resume()
    }

    var isHoldingWhisper: Bool {
        lock.withLock { whisperGate != nil }
    }

    func monitor(callId: SupervisedCallID, platform: ClientPlatform) async -> Result<CallMonitorResponse, ApiError> {
        lock.withLock {
            asked.append("monitor \(callId.value) \(platform.rawValue)")
            return monitorResults.isEmpty ? .failure(.transport("unscripted")) : monitorResults.removeFirst()
        }
    }

    func takeOver(workspaceId: String, callId: String) async -> Result<CallTakeoverResponse, ApiError> {
        lock.withLock {
            asked.append("takeOver \(workspaceId) \(callId)")
            return takeoverResults.isEmpty ? .failure(.transport("unscripted")) : takeoverResults.removeFirst()
        }
    }

    private var detailResult: Result<CallSummary, ApiError> = .failure(.transport("unscripted"))

    func answerDetail(_ result: Result<CallSummary, ApiError>) {
        lock.withLock { detailResult = result }
    }

    func detail(workspaceId: String, callId: String) async -> Result<CallSummary, ApiError> {
        lock.withLock {
            asked.append("detail \(workspaceId) \(callId)")
            return detailResult
        }
    }

    func whisper(workspaceId _: String, callId _: String, text: String) async -> Result<Void, ApiError> {
        lock.withLock { asked.append("whisper \(text)") }
        if holdsWhispers {
            await withCheckedContinuation { continuation in
                lock.withLock { whisperGate = continuation }
            }
        }
        return lock.withLock {
            whisperResults.isEmpty ? .success(()) : whisperResults.removeFirst()
        }
    }
}

enum SuperviseFixtures {
    static let workspaceId = "ws_1"
    /// ⚠️ cuid-shaped: a `Call.id` carries no `_` (``SupervisedCallID``).
    static let callId = "cmh1live0001"

    static let listenSeat = CallMonitorResponse(success: true, token: "listen.jwt", url: "wss://sfu.example.test")
    static let coachSeat = CallTakeoverResponse(
        success: true,
        url: "wss://sfu.example.test",
        token: "coach.jwt",
        roomName: "inbound_ws_1_cmh1live0001"
    )

    static func call(receptionistOnCall: Bool? = true, status: String = "in-progress") throws -> CallSummary {
        try LiveFixtures.call(
            id: callId,
            status: status,
            number: "Marie Tremblay",
            from: "+15555550100",
            receptionistOnCall: receptionistOnCall
        )
    }

    /// A telemetry event for the call, as the broadcaster relays it.
    static func envelope(_ type: TelemetryEventType, _ data: WireJSON, callId: String = callId) -> TelemetryEnvelope {
        TelemetryEnvelope(
            workspaceId: workspaceId,
            callId: callId,
            eventType: type,
            data: data,
            timestamp: "2026-11-05T18:00:00.000Z"
        )
    }

    /// Feed dependencies that are never activated by these tests: no socket is opened.
    static func feedDependencies() -> LiveEventFeed.Dependencies {
        let clock = ManualLiveClock()
        return LiveEventFeed.Dependencies(
            minter: ScriptedMinter(clock: clock),
            transport: SocketScript().transport(clock: clock),
            clock: clock,
            jitter: { 0 }
        )
    }

    @MainActor
    static func model(
        call: CallSummary,
        role: WorkspaceRole? = .agency,
        server: FakeSuperviseServer,
        media: FakeSuperviseMedia
    ) -> SuperviseModel {
        let clock = ManualLiveClock()
        let transcript = LiveTranscriptModel(
            workspaceId: workspaceId,
            callId: call.id,
            dependencies: LiveTranscriptModel.Dependencies(
                minter: ScriptedMinter(clock: clock),
                transport: SocketScript().transport(clock: clock),
                clock: clock,
                jitter: { 0 },
                fetchTranscript: { .success("") }
            )
        )
        return SuperviseModel(
            call: call,
            workspaceId: workspaceId,
            role: role,
            server: server,
            media: media,
            transcript: transcript,
            events: LiveEventFeed(workspaceId: workspaceId, dependencies: feedDependencies())
        )
    }
}
