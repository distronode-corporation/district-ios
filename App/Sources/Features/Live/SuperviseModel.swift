import DistrictCall
import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import Observation

/// The three supervise routes, behind a seam so a test can stand in for the server.
///
/// ⚠️ THE CORE'S `CallsRepository` IS THE ONE CONFORMANCE (district-core-swift 8.2.0): the app
/// never builds a request by hand, and the core's `EndpointID` table is the one list of what
/// it calls. None of the three is ever retried, there or here.
protocol SuperviseServing: Sendable {
    func monitor(callId: SupervisedCallID, platform: ClientPlatform) async -> Result<CallMonitorResponse, ApiError>
    func takeOver(workspaceId: String, callId: String) async -> Result<CallTakeoverResponse, ApiError>
    func whisper(workspaceId: String, callId: String, text: String) async -> Result<Void, ApiError>
}

extension CallsRepository: SuperviseServing {}

/// One person supervising one live call: listen in, a note to the receptionist, take over,
/// hand back.
///
/// ⛔ IT DECIDES NOTHING ABOUT THE CALL. `SuperviseSession` (district-core-swift, `DistrictCall`)
/// is the state machine, tested on Linux: the takeover is asked for while still listening, a
/// refusal leaves the person listening, a grant leaves the listen room before the coach room is
/// joined, and every ending CallKit did not perform is reported. This model feeds it events and
/// performs its commands IN ORDER, through ``SuperviseServing`` and ``SuperviseMedia``.
///
/// ⛔ THE SUPERVISION OUTLIVES THE SCREEN, FOR THE DIALLER'S REASON. Listen claims the device's
/// call through ``SuperviseMedia/claim(_:handler:)``, whose handler holds this object strongly,
/// and ``release()`` drops it on every terminal path. A Live screen popped mid-call leaves the
/// person listening (the lock screen still shows the call and ends it), and a screen rebuilt
/// around the call finds this model again through ``CallStack/supervisor``.
///
/// ⛔ LISTEN IS A CALLKIT CALL, AND THE START COMES FIRST (Sean, 2026-11-05, Q3). The OS is
/// asked for the call before the server is asked for the seat, exactly as the dialler asks it
/// before the carrier, so the session is configured by CallKit, a ring arriving meets a call
/// in progress, and a takeover from the lock screen has a call to continue.
///
/// ⛔ A COLLEAGUE'S OWN SOFTPHONE CALL OFFERS LISTEN ONLY (Sean, Q2): the session is built
/// from the row's `receptionistOnCall`, so `mayWhisper` and `mayTakeOver` are false there.
/// The routes' 409 `call_has_no_receptionist` stays the fallback.
@MainActor
@Observable
final class SuperviseModel {
    let workspaceId: String
    let callId: String

    /// The call as the Live list read it when the screen opened.
    let call: CallSummary

    /// Where the supervision stands. ⛔ The only writer is ``apply(_:)``.
    private(set) var session: SuperviseSession

    /// Why Listen did nothing, when the device or the OS refused before the session began
    /// (another call, a room, a system call that never started). ⚠️ Cleared by the next press.
    private(set) var startRefusal: String?

    /// True between the press and the OS performing the start.
    private(set) var starting = false

    /// The note being written. ⚠️ Kept through a failed send, cleared by a delivered one.
    var draft = ""
    /// True while a note is on its way. ⛔ One at a time (single-flight).
    private(set) var sending = false
    /// Why the last note did not go, or nil.
    private(set) var whisperProblem: String?

    /// The call's live transcript, the call screen's own model.
    let transcript: LiveTranscriptModel
    /// The workspace's call events: the call ending, and the receipt for a note.
    let events: LiveEventFeed

    // ⚠️ MODULE-VISIBLE FOR `SuperviseModel+Steps.swift`, WHICH IS SPLIT OUT FOR
    // `type_body_length` AND NOTHING ELSE. Swift's `private` is file-scoped.
    let server: any SuperviseServing
    let media: any SuperviseMedia
    var callUUID: UUID?
    var claimed = false
    var connectedReported = false
    var engineLeg: SuperviseLeg?
    var legTask: Task<Void, Never>?
    var startTask: Task<Void, Never>?

    /// Where a started listen-in is remembered for a Recents tap. ⚠️ nil in most tests.
    var recents: ListenInRecents?

    /// How long the OS may take to perform the start before the attempt is abandoned.
    static let startTimeoutSeconds = 10

    init(
        call: CallSummary,
        workspaceId: String,
        role: WorkspaceRole?,
        server: any SuperviseServing,
        media: any SuperviseMedia,
        transcript: LiveTranscriptModel,
        events: LiveEventFeed
    ) {
        self.call = call
        callId = call.id
        self.workspaceId = workspaceId
        session = SuperviseSession(call: call, role: role)
        self.server = server
        self.media = media
        self.transcript = transcript
        self.events = events
        events.onEvent = { [weak self] in self?.received($0) }
    }

    var state: SuperviseState {
        session.state
    }

    /// Whether Listen may be pressed now. ⚠️ Not while the OS is still being asked.
    var mayListen: Bool {
        state.mayListen && !starting
    }

    // MARK: - Listen, stop, take over, hand back

    /// The person pressed Listen.
    ///
    /// ⛔ ONE SYSTEM CALL ON THE DEVICE: refused, with a sentence, while a phone call or a
    /// meeting room holds it, as a dial is.
    func listen() {
        guard mayListen, !claimed else { return }
        startRefusal = nil
        if media.hasLiveCall {
            startRefusal = SuperviseCopy.busyWithCall
            return
        }
        if media.hasLiveRoom {
            startRefusal = SuperviseCopy.busyInRoom
            return
        }
        let uuid = UUID()
        callUUID = uuid
        claimed = true
        starting = true
        // ⛔ ARMED BEFORE THE TRANSACTION, NEVER AFTER: see ``CallKitBridge/onSystemRequest``.
        media.claim(self) { [self] request in system(request) }
        media.startCall(uuid: uuid, handle: Self.handle(for: call)) { [weak self] in
            Task { await self?.abandonStart(uuid: uuid) }
        }
        armStartWatchdog(uuid: uuid)
    }

    /// Stop listening, or Hand back: both are leaving the room.
    ///
    /// ⛔ THE OS IS TOLD FIRST, THEN THE REDUCER, as ``DialerModel/hangUp()`` does:
    /// ``CallKitBridge/requestEndCall(uuid:)`` disarms itself, so its action does not come back.
    func stop() async {
        guard let uuid = callUUID else { return }
        media.requestEnd(uuid: uuid)
        if starting {
            // ⚠️ THE SESSION NEVER BEGAN: there is nothing for the reducer to leave.
            await release()
            return
        }
        await apply(.stopPressed)
    }

    /// The person confirmed Take over.
    ///
    /// ⛔ THE MICROPHONE IS ASKED BEFORE THE SERVER, as the dialler asks it before the carrier.
    /// A refusal here leaves the person listening and asks the server nothing: a coach seat
    /// whose microphone cannot start would only put the assistant on hold for silence.
    func takeOver() async {
        guard state.mayTakeOver else { return }
        guard await media.microphone.request() else {
            whisperProblem = nil
            startRefusal = SuperviseCopy.takeOverJoinFailed
            return
        }
        startRefusal = nil
        await apply(.takeOverPressed)
    }

    /// The in-app mute control. ⛔ Through CallKit, like the dialler's.
    func toggleMute() {
        guard let uuid = callUUID, state.holdsTheCall else { return }
        media.requestMuted(uuid: uuid, muted: state.media.microphoneEnabled)
    }

    func toggleSpeaker() async {
        await apply(.speakerToggled)
    }

    // MARK: - The note

    /// Send the note.
    ///
    /// ⛔ NEVER RETRIED (the route publishes before it answers, so a lost answer may follow a
    /// note already acted on), and ONE AT A TIME: a second press while one is on its way is
    /// dropped rather than queued.
    func sendWhisper() async {
        guard state.mayWhisper, !sending else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard text.utf16.count <= SuperviseCopy.whisperLimit else {
            whisperProblem = SuperviseCopy.whisperTooLong(SuperviseCopy.whisperLimit)
            return
        }
        sending = true
        whisperProblem = nil
        let result = await server.whisper(workspaceId: workspaceId, callId: callId, text: text)
        sending = false
        switch result {
        case .success:
            draft = ""
            // ⚠️ THE PREVIOUS RECEIPT IS NOT THIS NOTE'S: the event names no note.
            await apply(.whisperSent)
        case let .failure(error):
            whisperProblem = SuperviseCopy.refusal(error, fallback: SuperviseCopy.whisperFailed)
        }
    }

    // MARK: - What the list and the socket say

    private func received(_ envelope: TelemetryEnvelope) {
        guard envelope.callId == callId else { return }
        if let receipt = envelope.whisperReceipt {
            Task { await apply(.whisperReceipt(receipt)) }
            return
        }
        let over = envelope.callStatus.map(CallWire.hasEnded) == true
        let ended = envelope.eventType == .callEnded || (envelope.eventType == .callUpdated && over)
        guard ended else { return }
        Task {
            await apply(.callEnded)
            transcript.callEnded()
        }
    }

    // MARK: - The start

    /// The OS performed the start: ask the server for the seat.
    func began(uuid: UUID) async {
        startTask?.cancel()
        startTask = nil
        guard starting, callUUID == uuid else { return }
        starting = false
        guard state.phase == .idle else {
            // ⛔ THE CALL ENDED WHILE THE OS WAS STARTING ITS OWN: `over` absorbs the press, so
            // the system call is ended here or it would hold the device's one call group.
            media.requestEnd(uuid: uuid)
            await release()
            return
        }
        media.reportConnecting(uuid: uuid, callerName: CallDisplay(call).callerLabel)
        // ⚠️ THE SYSTEM CALL EXISTS NOW, SO RECENTS WILL SHOW IT: remember which call it was.
        recents?.record(handle: Self.handle(for: call), workspaceId: workspaceId, callId: callId)
        await apply(.listenPressed)
    }

    // MARK: - The one sink

    /// Apply one event, perform what it asked for, then settle.
    ///
    /// ⛔ EVERY EVENT GOES THROUGH HERE, WHICH IS WHAT MAKES ``release()`` TOTAL. The commands
    /// are performed IN ORDER and one after another, because the order is part of
    /// `SuperviseCommand`'s contract: the listen room is left before the coach room is joined.
    func apply(_ event: SuperviseEvent) async {
        var next = session
        let commands = next.handle(event)
        // ⚠️ WRITTEN BACK BEFORE THE AWAITS, so an event that interleaves reads the new state.
        session = next
        for command in commands {
            await perform(command)
        }
        await settle()
    }

    /// ⛔ THE ONE EXIT, AND IT DROPS THE CLAIM LAST: the claim is this object's only strong
    /// reference while no screen shows it. ⚠️ Safe to call with nothing claimed.
    func release() async {
        startTask?.cancel()
        startTask = nil
        legTask?.cancel()
        legTask = nil
        engineLeg = nil
        starting = false
        connectedReported = false
        guard claimed else { return }
        claimed = false
        callUUID = nil
        media.endLeg()
        media.release(self)
    }

    // MARK: - The start that never came back

    /// ⛔ A START THE OS REFUSED, OR NEVER ANSWERED, ENDS THE ATTEMPT: nothing was asked of the
    /// server yet, so nothing is torn down there.
    func abandonStart(uuid: UUID) async {
        guard starting, callUUID == uuid else { return }
        // ⚠️ BELT AND BRACES, as ``DialerModel/abandonStart(uuid:because:)`` does: if the start
        // was in fact performed late, this ends the call the OS is holding.
        media.requestEnd(uuid: uuid)
        startRefusal = SuperviseCopy.notStarted
        await release()
    }

    func armStartWatchdog(uuid: UUID) {
        let timeout = Self.startTimeoutSeconds
        startTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, let self else { return }
            await abandonStart(uuid: uuid)
        }
    }

    // MARK: - The handle

    /// What the OS's call surfaces and Recents show for the listen-in.
    ///
    /// ⚠️ AN INBOUND CALL'S CALLER NUMBER WHEN IT HAS ONE, else the call log's own label for the
    /// call (an outbound row's `from` is the workspace's own line). ⛔ Never the call id: it
    /// would write a meaningless string into the system call log
    /// (``CallKitBridge/reportIncomingCall(uuid:handle:)``).
    static func handle(for call: CallSummary) -> String {
        let number = call.direction == "inbound" ? CallerIdentity.resolved(call.from) : nil
        return number ?? CallDisplay(call).callerLabel
    }
}
