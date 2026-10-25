import ActivityKit
import Foundation

/// ``CallActivityHosting`` over ActivityKit: the one place the app calls it.
///
/// ⚠️ NO DECISION HERE. Which call gets an activity, when it moves and when it ends are
/// ``CallLiveActivities``', tested in `DistrictAITests` against a fake host; this file only
/// translates. A simulator runs it, but whether ActivityKit allows a start from a ring that
/// woke a locked phone is a device question.
@MainActor
struct ActivityKitCallActivityHost: CallActivityHosting {
    /// ⛔ iOS 18 AND LATER ONLY: the extension that draws the activity (`DistrictAIWidgets`)
    /// targets iOS 18, so on iOS 17 an activity would start with nothing to draw it.
    var enabled: Bool {
        guard #available(iOS 18.0, *) else { return false }
        return ActivityAuthorizationInfo().areActivitiesEnabled
    }

    func running() -> [any CallActivityHandle] {
        Activity<DistrictCallActivityAttributes>.activities
            .filter { $0.activityState == .active || $0.activityState == .stale }
            .map(ActivityKitCallActivity.init)
    }

    func start(
        _ attributes: DistrictCallActivityAttributes,
        state: DistrictCallActivityAttributes.ContentState,
        staleDate: Date?
    ) throws -> any CallActivityHandle {
        // ⛔ `pushType: .token`: the server updates and ends it by this token
        // (`POST calls/{id}/live-activity`); without it no push can reach the activity.
        let activity = try Activity.request(
            attributes: attributes,
            content: ActivityContent(state: state, staleDate: staleDate),
            pushType: .token
        )
        return ActivityKitCallActivity(activity)
    }
}

/// One ActivityKit activity as a ``CallActivityHandle``.
@MainActor
final class ActivityKitCallActivity: CallActivityHandle {
    private let activity: Activity<DistrictCallActivityAttributes>
    /// What this process last asked for: ActivityKit's own `content` lags an update by a hop.
    private(set) var state: DistrictCallActivityAttributes.ContentState

    init(_ activity: Activity<DistrictCallActivityAttributes>) {
        self.activity = activity
        state = activity.content.state
    }

    var workspaceId: String {
        activity.attributes.workspaceId
    }

    var callId: String {
        activity.attributes.callId
    }

    var pushTokens: AsyncStream<Data> {
        let activity = activity
        return AsyncStream { continuation in
            let task = Task {
                for await token in activity.pushTokenUpdates {
                    continuation.yield(token)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func update(_ state: DistrictCallActivityAttributes.ContentState, staleDate: Date?) {
        self.state = state
        let activity = activity
        Task {
            await activity.update(ActivityContent(state: state, staleDate: staleDate))
        }
    }

    func end(_ state: DistrictCallActivityAttributes.ContentState, dismissal: CallActivityDismissal) {
        self.state = state
        let activity = activity
        let policy: ActivityUIDismissalPolicy = switch dismissal {
        case .immediate: .immediate
        case let .after(date): .after(date)
        }
        Task {
            await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: policy)
        }
    }
}
