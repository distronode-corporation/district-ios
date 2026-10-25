@testable import DistrictAI
import DistrictLive
import DistrictModel
import Foundation
import XCTest

// The fakes `CallLiveActivitiesTests` and `CallLiveActivityPushStartTests` share: ActivityKit
// and the server, behind the app's own seams.

// MARK: - Fakes

@MainActor
final class FakeActivity: CallActivityHandle {
    let activityId = UUID().uuidString
    let workspaceId: String
    let callId: String
    private(set) var state: DistrictCallActivityAttributes.ContentState
    private(set) var updates: [DistrictCallActivityAttributes.ContentState] = []
    private(set) var staleDates: [Date?] = []
    private(set) var ending: CallActivityDismissal?
    private(set) var endCount = 0
    let pushTokens: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation

    init(
        workspaceId: String,
        callId: String,
        state: DistrictCallActivityAttributes.ContentState,
        staleDate: Date? = nil
    ) {
        self.workspaceId = workspaceId
        self.callId = callId
        self.state = state
        staleDates = [staleDate]
        (pushTokens, continuation) = AsyncStream.makeStream()
    }

    func send(_ token: Data) {
        continuation.yield(token)
    }

    func update(_ state: DistrictCallActivityAttributes.ContentState, staleDate: Date?) {
        self.state = state
        updates.append(state)
        staleDates.append(staleDate)
    }

    func end(_ state: DistrictCallActivityAttributes.ContentState, dismissal: CallActivityDismissal) {
        self.state = state
        ending = dismissal
        endCount += 1
    }
}

@MainActor
final class FakeActivityHost: CallActivityHosting {
    var enabled = true
    var refuse = false
    var alreadyRunning: [FakeActivity] = []
    private(set) var started: [FakeActivity] = []
    private(set) var attributes: [DistrictCallActivityAttributes] = []
    /// What ActivityKit's `activityUpdates` would hand over: see ``announce(_:)``.
    private var onNew: (@MainActor (any CallActivityHandle) -> Void)?

    struct Refused: Error {}

    func running() -> [any CallActivityHandle] {
        alreadyRunning
    }

    func observeNewActivities(_ onNew: @escaping @MainActor (any CallActivityHandle) -> Void) -> Task<Void, Never> {
        self.onNew = onNew
        return Task {}
    }

    /// An activity started, by the server's push-to-start or by the app.
    func announce(_ activity: FakeActivity) {
        onNew?(activity)
    }

    func start(
        _ attributes: DistrictCallActivityAttributes,
        state: DistrictCallActivityAttributes.ContentState,
        staleDate: Date?
    ) throws -> any CallActivityHandle {
        if refuse {
            throw Refused()
        }
        let activity = FakeActivity(
            workspaceId: attributes.workspaceId,
            callId: attributes.callId,
            state: state,
            staleDate: staleDate
        )
        started.append(activity)
        self.attributes.append(attributes)
        return activity
    }
}

final class FakeRegistrar: LiveActivityRegistering, @unchecked Sendable {
    struct Call: Equatable {
        let workspaceId: String
        let callId: String
        let token: String
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    var result: Result<Void, ApiError> = .success(())

    var calls: [Call] {
        lock.withLock { recorded }
    }

    func registerLiveActivity(workspaceId: String, callId: String, token: String) async -> Result<Void, ApiError> {
        lock.withLock {
            recorded.append(Call(workspaceId: workspaceId, callId: callId, token: token))
            return result
        }
    }
}

@MainActor
final class EndedFeed: WatchLiveTranscriptFeed {
    var lines: [TranscriptSegment] = [LiveFixtures.segment("s1", index: 0, speaker: .agent, text: "Goodbye.")]
    var phase: LiveTranscriptPhase = .ended(.callEnded)
    var complete = true
    var connection: LiveTranscriptModel.Connection = .idle
    var fallsBack = false
    var snapshotsReceived = 1
    func activate() {}
    func deactivate() {}
    func callShownInProgress() {}
}
