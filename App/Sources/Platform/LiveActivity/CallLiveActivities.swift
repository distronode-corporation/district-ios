import DistrictData
import DistrictModel
import Foundation

/// One running Live Activity, behind a seam so the decisions run in a test.
@MainActor
protocol CallActivityHandle: AnyObject {
    /// ActivityKit's own id: two handles for one activity share it.
    var activityId: String { get }
    var workspaceId: String { get }
    var callId: String { get }
    var state: DistrictCallActivityAttributes.ContentState { get }
    /// Each push token ActivityKit hands over, the first one included.
    var pushTokens: AsyncStream<Data> { get }
    func update(_ state: DistrictCallActivityAttributes.ContentState, staleDate: Date?)
    func end(_ state: DistrictCallActivityAttributes.ContentState, dismissal: CallActivityDismissal)
}

/// When an ended activity leaves the Lock Screen.
enum CallActivityDismissal: Equatable {
    case immediate
    case after(Date)
}

/// ActivityKit itself, behind a seam: whether activities are allowed, the ones running, and
/// starting one.
@MainActor
protocol CallActivityHosting {
    /// The person allows Live Activities for this app (Settings, District AI).
    var enabled: Bool { get }
    /// The activities running now, including those a previous process started.
    func running() -> [any CallActivityHandle]
    /// Hand each activity that starts from now on to `onNew`, the push-started ones (a ring
    /// the server announced) and this app's own alike.
    func observeNewActivities(_ onNew: @escaping @MainActor (any CallActivityHandle) -> Void) -> Task<Void, Never>
    /// Start one locally, asking for push tokens.
    func start(
        _ attributes: DistrictCallActivityAttributes,
        state: DistrictCallActivityAttributes.ContentState,
        staleDate: Date?
    ) throws -> any CallActivityHandle
}

/// Hands one activity token to the server. `CallsRepository.registerLiveActivity`
/// (district-core-swift 8.1.0) is the one conformance.
protocol LiveActivityRegistering: Sendable {
    func registerLiveActivity(workspaceId: String, callId: String, token: String) async -> Result<Void, ApiError>
}

extension CallsRepository: LiveActivityRegistering {}

/// How a ring on this phone ended, as far as the call's Live Activity cares.
enum CallActivityRingOutcome: Equatable {
    /// This person answered: the call screen takes over, and the activity goes.
    case answeredHere
    /// This person declined: the assistant takes a message.
    case declinedHere
    /// Nobody here answered (the ring timed out, or the server stopped ringing): the assistant
    /// has the call.
    case unanswered
    /// The ring was withdrawn with nobody signed in: nothing about the call may stay on screen.
    case withdrawn
}

/// The call Live Activities: started, updated and ended locally, and their push tokens handed
/// to the server so it can update them while the app sleeps.
///
/// ⛔ STARTED THREE WAYS (Sean, 2026-10-25: "When you're rung, or the app is open", then "Add
/// push-to-start"): the server's push-to-start on a ring (iOS 18, the token sent by
/// ``LiveActivityStartTokens``; this object adopts what it starts), and locally, as the
/// fallback, by a ring that wakes the app (``rang(workspaceId:callId:)``, after CallKit
/// has the call), and the open app seeing a call in progress
/// (``seenLive(workspaceId:callId:callerName:startedAt:)``, the call screen or the watch
/// relay's live list).
///
/// ⛔ NEVER TWO FOR ONE CALL. Every start first looks at what ActivityKit is running, which
/// includes an activity a previous process started, so a relaunch adopts rather than doubles.
///
/// ⛔ A TOKEN IS SENT ONCE, NEVER RETRIED. ActivityKit hands over a new one when it rotates it;
/// a failure only costs server updates, and the app still updates and ends the activity while
/// it is awake.
///
/// ⚠️ THE CONTENT IS A NAME AND A LINE OF CONVERSATION ON THE LOCK SCREEN, which is Sean's
/// decision (GitLab #2, 2026-10-25). Nothing here logs a state, a name or a line.
@MainActor
final class CallLiveActivities {
    /// How long an ended call stays on the Lock Screen.
    static let dismissalDelay: TimeInterval = 4 * 60
    /// Shown as out of date when nothing updated it for this long (a lost push).
    static let staleAfter: TimeInterval = 30 * 60

    private let host: any CallActivityHosting
    private let registrar: any LiveActivityRegistering
    private let now: () -> Date
    private var activities: [String: any CallActivityHandle] = [:]
    private var tokenTasks: [String: Task<Void, Never>] = [:]
    private var adopted = false
    private var newActivities: Task<Void, Never>?

    init(host: any CallActivityHosting, registrar: any LiveActivityRegistering, now: @escaping () -> Date = Date.init) {
        self.host = host
        self.registrar = registrar
        self.now = now
    }

    /// The calls with an activity this object is driving. For tests.
    var callIds: Set<String> {
        Set(activities.keys)
    }

    // MARK: - Starting

    /// A ring woke the app and CallKit has the call. ⚠️ No name yet: the identity look-up
    /// follows, and ``named(callId:callerName:)`` carries it.
    func rang(workspaceId: String, callId: String) {
        start(workspaceId: workspaceId, callId: callId, callerName: "", phase: .ringing, startedAt: now())
    }

    /// The open app saw this call in progress. Starts one if there is none; an activity still
    /// ringing moves on to the assistant answering.
    func seenLive(workspaceId: String, callId: String, callerName: String, startedAt: Date?) {
        if let activity = tracked(callId) {
            guard activity.state.phase == .ringing else { return }
            var state = activity.state
            state.phase = .aiAnswering
            push(state, to: activity)
            return
        }
        start(
            workspaceId: workspaceId,
            callId: callId,
            callerName: callerName,
            phase: .aiAnswering,
            startedAt: startedAt ?? now()
        )
    }

    private func start(
        workspaceId: String,
        callId: String,
        callerName: String,
        phase: DistrictCallActivityPhase,
        startedAt: Date
    ) {
        guard tracked(callId) == nil, host.enabled else { return }
        let attributes = DistrictCallActivityAttributes(
            workspaceId: workspaceId,
            callId: callId,
            callerName: callerName
        )
        let state = DistrictCallActivityAttributes.ContentState(
            phase: phase,
            startedAt: DistrictCallActivityTime.string(startedAt)
        )
        // ⚠️ A REFUSED START IS NOT AN ERROR ANYONE SEES: the call goes on without one.
        // ActivityKit refuses one when activities are off, too many run, or (its `visibility`
        // error) the app is not in front, which a ring that wakes a locked phone may be: a
        // DEVICE question this build answers by trying, never by a check of its own.
        guard let started = try? host.start(attributes, state: state, staleDate: staleDate()) else { return }
        track(started)
    }

    /// The activities a previous process left running: tracked, and their tokens watched
    /// again; and from then on every activity that starts, once per process.
    func adoptRunning() {
        guard !adopted else { return }
        adopted = true
        for activity in host.running() {
            adopt(activity)
        }
        newActivities = host.observeNewActivities { [weak self] activity in self?.adopt(activity) }
    }

    /// ⛔ ONE ACTIVITY PER CALL. A push-started activity whose call already has one (this app
    /// started it first, in front) is ended at once: the older one already has its token on
    /// the server. The app's own start, reported back, is the same activity and changes
    /// nothing.
    private func adopt(_ activity: any CallActivityHandle) {
        guard let existing = activities[activity.callId] else {
            track(activity)
            return
        }
        guard existing.activityId != activity.activityId else { return }
        activity.end(activity.state, dismissal: .immediate)
    }

    /// The activity for a call: the tracked one, else one ActivityKit runs that the server
    /// started (a ring's push-to-start can land before its announcement reaches ``adopt(_:)``).
    private func tracked(_ callId: String) -> (any CallActivityHandle)? {
        adoptRunning()
        if activities[callId] == nil, let running = host.running().first(where: { $0.callId == callId }) {
            adopt(running)
        }
        return activities[callId]
    }

    private func track(_ activity: any CallActivityHandle) {
        let callId = activity.callId
        activities[callId] = activity
        let workspaceId = activity.workspaceId
        let registrar = registrar
        let tokens = activity.pushTokens
        tokenTasks[callId] = Task {
            var last: String?
            for await data in tokens {
                let token = Self.hex(data)
                // ⚠️ THE SAME TOKEN TWICE IS ONE REGISTRATION: the route is idempotent, but a
                // repeat is still a request.
                guard token != last else { continue }
                last = token
                _ = await registrar.registerLiveActivity(workspaceId: workspaceId, callId: callId, token: token)
            }
        }
    }

    // MARK: - Updating

    /// The caller's name arrived after the start (the ring's identity look-up).
    func named(callId: String, callerName: String) {
        guard let activity = tracked(callId), activity.state.callerName != callerName else { return }
        var state = activity.state
        state.callerName = callerName
        push(state, to: activity)
    }

    /// The ring on this phone ended.
    func ringEnded(callId: String, _ outcome: CallActivityRingOutcome) {
        guard let activity = tracked(callId) else { return }
        var state = activity.state
        switch outcome {
        case .answeredHere, .withdrawn:
            finish(callId, state, dismissal: .immediate)
        case .declinedHere:
            state.phase = .declined
            push(state, to: activity)
        case .unanswered:
            guard state.phase == .ringing else { return }
            state.phase = .aiAnswering
            push(state, to: activity)
        }
    }

    /// The live transcript changed: the latest FINAL line, if it is new.
    ///
    /// ⚠️ INTERIM LINES ARE NEVER SHOWN: they are rewritten as the caller speaks, and the
    /// server's own updates carry final segments only, so the two agree.
    func transcript(callId: String, lines: [TranscriptSegment]) {
        guard let activity = tracked(callId),
              let segment = lines.last(where: \.final),
              let line = DistrictCallActivityLine.clip(segment.text)
        else { return }
        var state = activity.state
        state.latestLine = line
        state.latestSpeaker = Self.speaker(segment.speaker)
        if state.phase == .ringing {
            state.phase = .aiAnswering
        }
        guard state != activity.state else { return }
        push(state, to: activity)
    }

    /// The call ended. The activity shows how for ``dismissalDelay``, then goes.
    func ended(callId: String) {
        guard let activity = tracked(callId) else { return }
        var state = activity.state
        // ⚠️ A PHASE THAT ALREADY SAYS HOW IT ENDED (declined, a message taken, transferred)
        // IS KEPT: "ended" would say less.
        if !state.phase.isOver {
            state.phase = .ended
        }
        state.endedAt = state.endedAt ?? DistrictCallActivityTime.string(now())
        finish(callId, state, dismissal: .after(now().addingTimeInterval(Self.dismissalDelay)))
    }

    /// Sign-out: every activity goes at once, because each names a caller of the account that
    /// is leaving.
    func endAll() {
        adoptRunning()
        for (callId, activity) in activities {
            finish(callId, activity.state, dismissal: .immediate)
        }
    }

    private func finish(
        _ callId: String,
        _ state: DistrictCallActivityAttributes.ContentState,
        dismissal: CallActivityDismissal
    ) {
        guard let activity = activities.removeValue(forKey: callId) else { return }
        tokenTasks.removeValue(forKey: callId)?.cancel()
        activity.end(state, dismissal: dismissal)
    }

    private func push(_ state: DistrictCallActivityAttributes.ContentState, to activity: any CallActivityHandle) {
        activity.update(state, staleDate: staleDate())
    }

    private func staleDate() -> Date {
        now().addingTimeInterval(Self.staleAfter)
    }

    // MARK: - Pure rules

    /// The token as APNs wants it: lowercase hex.
    nonisolated static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func speaker(_ speaker: TranscriptSpeaker) -> DistrictCallActivitySpeaker? {
        switch speaker {
        case .caller: .caller
        case .agent: .assistant
        case .other: nil
        }
    }
}
