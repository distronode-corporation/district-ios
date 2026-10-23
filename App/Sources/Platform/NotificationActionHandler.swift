import DistrictAuthCore
import DistrictData
import DistrictModel
import Foundation
import UIKit

/// What a background action asks for: Reply (with the text typed) or Mark read.
enum MessageAction: Sendable, Equatable {
    case reply(String)
    case markRead

    /// The action a flattened notification response names (see ``NotificationPresenter``),
    /// or nil for anything that is not one of the two shade buttons: an ordinary tap, a
    /// dismiss, a button this build does not know.
    init?(payload: [String: String]) {
        switch payload[MessageNotificationAction.identifierKey] {
        case MessageNotificationAction.reply: self = .reply(payload[MessageNotificationAction.replyTextKey] ?? "")
        case MessageNotificationAction.markRead: self = .markRead
        default: return nil
        }
    }

    /// ⚠️ THE TEXT IS PART OF A REPLY'S KEY. Two different replies to one message are two
    /// requests; the same reply delivered twice is one.
    func singleFlightKey(workspaceId: String, messageId: String) -> String {
        switch self {
        case let .reply(text): "reply:\(workspaceId):\(messageId):\(text)"
        case .markRead: "mark-read:\(workspaceId):\(messageId)"
        }
    }
}

/// Why a background action did not go through.
enum MessageActionFailure: Error, Sendable, Equatable {
    /// The push carried no `workspaceId`/`messageId` this build can read.
    case unreadablePayload
    /// The coordinator answered ``AccessTokenOutcome/reauthRequired(_:)``: there is no
    /// session to act with, and nothing was sent.
    case signedOut(ReauthReason)
    /// The coordinator answered ``AccessTokenOutcome/retryLater(_:)``. Nothing was sent.
    case sessionUnavailable(RetryReason)
    /// `GET messages/{id}` refused or failed, so there was no thread to act on.
    case unresolved(ApiError)
    /// The send or the mark-read itself refused or failed (a 403 or a 404 among them).
    case refused(ApiError)
}

/// Reply and Mark read from a notification, done without any SwiftUI view.
///
/// ⛔ IT DEPENDS ON NO VIEW STATE, AND THAT IS THE FIX IT EXISTS FOR. These actions used
/// to run from `ShellView`, which needed the UI's workspace session to have loaded (it
/// starts `.loading`, role nil) and a scene to have appeared. An action from a locked
/// phone or an Apple Watch launches the app COLD and in the background, where neither is
/// true, so the action was dropped with no feedback. Here the workspace is the push's own
/// `workspaceId`, the token comes from the one ``TokenRefreshCoordinator``, and the work
/// goes through the container's ``InboxRepository``.
///
/// ⛔ NO CLIENT-SIDE ROLE GATE. The server authorises `messages/send` and
/// `messages/mark-read` against the operator's membership of the PUSH's workspace; the
/// UI's role belonged to whichever workspace was selected, which is a different question.
/// A 403 or a 404 comes back as ``MessageActionFailure/refused(_:)`` and is reported.
///
/// ⛔ NOTHING IS RETRIED. A send that timed out may well have landed, and a second
/// attempt is a second charge and a duplicate message to a customer.
///
/// ⚠️ ``perform(_:workspaceId:messageId:)`` IS THE ENTRY POINT FOR ANY CALLER, not only
/// the notification delegate, and it reports nothing itself: a caller decides how a
/// failure reaches the person. ``handleNotificationResponse(_:)`` is the notification
/// caller, and it posts a local notification.
@MainActor
final class NotificationActionHandler {
    private let coordinator: TokenRefreshCoordinator
    private let inbox: InboxRepository
    private let reporter: any MessageActionFailureReporting
    private let backgroundTasks: any BackgroundTaskScheduling

    /// ⛔ ONE REQUEST PER TAP. A second delivery of the same action while the first is on
    /// the wire joins it and gets its answer, rather than sending again.
    private var inFlight: [String: Task<Result<Void, MessageActionFailure>, Never>] = [:]

    init(
        coordinator: TokenRefreshCoordinator,
        inbox: InboxRepository,
        reporter: any MessageActionFailureReporting = NotificationFailureReporter(),
        backgroundTasks: any BackgroundTaskScheduling = UIKitBackgroundTasks()
    ) {
        self.coordinator = coordinator
        self.inbox = inbox
        self.reporter = reporter
        self.backgroundTasks = backgroundTasks
    }

    /// Do one action on one message, in the message's own workspace.
    ///
    /// ⚠️ HELD OPEN BY A BACKGROUND TASK FOR ITS WHOLE LENGTH. A cold wake has no access
    /// token (it is memory-only), so the work is a refresh, a resolve and the write; a
    /// suspension in the middle of the refresh is the case the coordinator turns into a
    /// re-login. The task ends exactly once, on whichever comes first: the work finishing
    /// or the system's expiration.
    func perform(
        _ action: MessageAction,
        workspaceId: String,
        messageId: String
    ) async -> Result<Void, MessageActionFailure> {
        let key = action.singleFlightKey(workspaceId: workspaceId, messageId: messageId)
        if let running = inFlight[key] {
            return await running.value
        }
        let task = Task { [self] in
            let lease = BackgroundTaskLease.begin("district.notification-action", on: backgroundTasks)
            let outcome = await run(action, workspaceId: workspaceId, messageId: messageId)
            lease.end()
            // ⚠️ CLEARED INSIDE THE TASK, SO IT IS NIL BEFORE ANY WAITER RESUMES. The slot
            // can only hold this task: a same-key caller joins it rather than replacing it.
            inFlight[key] = nil
            return outcome
        }
        inFlight[key] = task
        return await task.value
    }

    /// The notification delegate's half: read the response, act, and say so on failure.
    ///
    /// ⛔ A FAILURE IS POSTED AS A LOCAL NOTIFICATION, because the notification that was
    /// acted on is gone and the app may never come forward. A silently dropped reply is
    /// the worst outcome on this surface.
    func handleNotificationResponse(_ payload: [String: String]) async {
        guard let action = MessageAction(payload: payload) else { return }
        let outcome = await perform(action, payload: payload)
        if case let .failure(failure) = outcome {
            reporter.report(failure, for: action)
        }
    }

    private func perform(
        _ action: MessageAction,
        payload: [String: String]
    ) async -> Result<Void, MessageActionFailure> {
        guard case let .message(workspaceId, messageId)? = PushPayload.parse(payload) else {
            return .failure(.unreadablePayload)
        }
        return await perform(action, workspaceId: workspaceId, messageId: messageId)
    }

    private func run(
        _ action: MessageAction,
        workspaceId: String,
        messageId: String
    ) async -> Result<Void, MessageActionFailure> {
        // ⚠️ AN EMPTY BOX IS NOT A FAILURE. iOS lets a reply be confirmed with nothing
        // typed, and `messages/send` would answer 400 for a message nobody wrote.
        if case let .reply(text) = action, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .success(())
        }
        // ⛔ THE TOKEN FIRST, AND THROUGH THE ONE COORDINATOR. On a cold wake this is the
        // refresh; asking here rather than leaving it to the first request means a
        // signed-out handset sends nothing at all and says why.
        switch await coordinator.accessToken() {
        case .available:
            break
        case let .reauthRequired(reason):
            return .failure(.signedOut(reason))
        case let .retryLater(reason):
            return .failure(.sessionUnavailable(reason))
        }
        // ⛔ BOTH ACTIONS ARE ADDRESSED BY THREAD AND THE PUSH NAMES A MESSAGE, so the
        // resolver comes first: `mark-read` takes a contact or counterpart, `send` takes
        // `to` plus a channel.
        let resolved: ResolvedThread
        switch await inbox.messageThread(workspaceId: workspaceId, messageId: messageId) {
        case let .success(thread):
            resolved = thread
        case let .failure(error):
            return .failure(.unresolved(error))
        }
        switch action {
        case .markRead:
            // ⚠️ ZERO MARKED IS A SUCCESS: a colleague may have opened the thread first.
            return await inbox.markRead(workspaceId: workspaceId, selector: resolved.selector)
                .map { _ in () }
                .mapError { .refused($0) }
        case let .reply(text):
            // ⛔ THE RECIPIENT IS ``ResolvedThread/replyTarget`` VERBATIM, the server's
            // unwrapped address and its channel. ⛔ No subject, even on email: a shade has
            // one box, and `messages/send` substitutes its own.
            return await inbox.send(workspaceId: workspaceId, target: resolved.replyTarget, body: text)
                .map { _ in () }
                .mapError { .refused($0) }
        }
    }
}

// MARK: - Reporting a failure

/// How a failed background action reaches the person. A seam for tests.
@MainActor
protocol MessageActionFailureReporting {
    func report(_ failure: MessageActionFailure, for action: MessageAction)
}

/// Posts the failure as a local notification. See ``NotificationCategories``.
struct NotificationFailureReporter: MessageActionFailureReporting {
    func report(_ failure: MessageActionFailure, for action: MessageAction) {
        let reason = failure.reason(for: action)
        switch action {
        case let .reply(text):
            NotificationCategories.postReplyFailure(text: text, reason: reason)
        case .markRead:
            NotificationCategories.postMarkReadFailure(reason: reason)
        }
    }
}

extension MessageActionFailure {
    /// The sentence that says why, in the person's language.
    ///
    /// ⚠️ A SERVER REFUSAL IS THE SERVER'S OWN SENTENCE where it gave one (an unverified
    /// sender, the per-workspace cap, a viewer's 403), through ``FailureText``. A thread
    /// that could not be resolved on the REPLY path keeps the sentence that says where the
    /// text can still be sent from.
    @MainActor
    func reason(for action: MessageAction) -> String {
        switch self {
        case .unreadablePayload:
            return Self.unresolvedReason(for: action)
        case let .signedOut(reason):
            // ⚠️ `.noSession` HAS NO SENTENCE ON THE SIGN-IN SCREEN (nothing to explain on
            // a cold start), but a notification needs one.
            let text = SessionModel.text(for: reason)
            return text.isEmpty ? SessionCopy.sessionHasEndedPlease : text
        case let .sessionUnavailable(reason):
            return SessionModel.text(for: reason)
        case let .unresolved(error):
            if case .reply = action {
                return Self.unresolvedReason(for: action)
            }
            return FailureText.from(error).message
        case let .refused(error):
            return FailureText.from(error).message
        }
    }

    private static func unresolvedReason(for action: MessageAction) -> String {
        switch action {
        case .reply: NavigationCopy.conversationCouldNotOpened
        case .markRead: InboxCopy.conversationCouldNotOpened
        }
    }
}

// MARK: - Background time

/// `beginBackgroundTask`/`endBackgroundTask`, behind a seam so a test can expire one.
@MainActor
protocol BackgroundTaskScheduling {
    func begin(_ name: String, expiration: @escaping @MainActor @Sendable () -> Void) -> UIBackgroundTaskIdentifier
    func end(_ identifier: UIBackgroundTaskIdentifier)
}

struct UIKitBackgroundTasks: BackgroundTaskScheduling {
    func begin(_ name: String, expiration: @escaping @MainActor @Sendable () -> Void) -> UIBackgroundTaskIdentifier {
        UIApplication.shared.beginBackgroundTask(withName: name, expirationHandler: expiration)
    }

    func end(_ identifier: UIBackgroundTaskIdentifier) {
        UIApplication.shared.endBackgroundTask(identifier)
    }
}

/// One background task, ended exactly once.
///
/// ⛔ ENDED ONCE WHICHEVER SIDE GETS THERE FIRST. The expiration handler must end the
/// task or the app is killed; the work finishing must end it too; and ending one twice,
/// or ending `.invalid` (what `begin` answers when no background time is granted), is a
/// UIKit misuse. The identifier is swapped for `.invalid` on the first end.
///
/// ⚠️ EXPIRATION ENDS THE TASK AND DOES NOT CANCEL THE WORK. The app is about to be
/// suspended; a send cancelled now may still have landed, and reporting it as failed
/// would invite a duplicate.
@MainActor
final class BackgroundTaskLease {
    private let tasks: any BackgroundTaskScheduling
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    private init(tasks: any BackgroundTaskScheduling) {
        self.tasks = tasks
    }

    static func begin(_ name: String, on tasks: any BackgroundTaskScheduling) -> BackgroundTaskLease {
        let lease = BackgroundTaskLease(tasks: tasks)
        lease.identifier = tasks.begin(name) { lease.end() }
        return lease
    }

    func end() {
        guard identifier != .invalid else { return }
        let ending = identifier
        identifier = .invalid
        tasks.end(ending)
    }
}

// MARK: - The handover from the notification delegate

/// Where the notification delegate hands a background action, and how it reaches the
/// handler on a launch that has no scene.
///
/// ⛔ A PROCESS-WIDE SLOT, AND THE BACKGROUND LAUNCH IS WHY. A non-foreground action from
/// a locked phone or a watch launches the app in the background WITHOUT connecting a
/// scene, so no `body`, `onAppear` or `.task` runs, and anything handed over from a view
/// (which is how ``PushTapRelay`` reaches its registrar) never arrives. `DistrictApp.init`
/// runs on every launch, so it adopts the container's handler here. It holds a reference
/// to the ONE handler built by the ONE ``AppContainer``; it builds nothing.
///
/// ⚠️ A QUEUE, UNLIKE ``PushTapRelay``'s ONE SLOT. A tap is a wish to go somewhere and the
/// newest wins; each action is something the operator asked to happen, and none may be
/// dropped. A response that arrives before ``adopt(_:)`` is held, with its completion.
@MainActor
final class NotificationActionInbox {
    static let process = NotificationActionInbox()

    private var handler: NotificationActionHandler?
    private var waiting: [(payload: [String: String], finish: () -> Void)] = []

    func adopt(_ handler: NotificationActionHandler) {
        self.handler = handler
        let held = waiting
        waiting = []
        for item in held {
            receive(item.payload, finish: item.finish)
        }
    }

    /// Act on a response, then call `finish`: the system's completion handler.
    ///
    /// ⛔ `finish` RUNS AFTER THE WORK, NEVER BEFORE IT. Calling it first tells iOS the app
    /// is done, and a background launch is then suspended mid-request.
    @discardableResult
    func receive(_ payload: [String: String], finish: @escaping () -> Void) -> Task<Void, Never>? {
        guard let handler else {
            waiting.append((payload, finish))
            return nil
        }
        return Task {
            await handler.handleNotificationResponse(payload)
            finish()
        }
    }
}
