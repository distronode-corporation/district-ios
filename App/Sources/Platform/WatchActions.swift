import DistrictData
import Foundation

/// The watch's writes, made through the paths the phone already trusts.
///
/// ⛔ REPLY AND MARK READ GO THROUGH ``NotificationActionHandler``, THE SAME OBJECT A
/// NOTIFICATION'S BUTTONS USE: one coordinator, one request per action, a background task,
/// nothing retried, and the same sentences when it fails. A second implementation here
/// would be a second place to get "no retry" wrong.
///
/// ⛔ AVAILABILITY GOES THROUGH ``CallHandlingRepository``, AS ``AvailabilityModel`` DOES,
/// FOR THE WORKSPACE THE WATCH NAMED. The server writes the caller's own membership row
/// and nothing else, and its refusal (a viewer, no member row) is the answer shown.
@MainActor
struct ContainerWatchActions: WatchActionPerforming {
    private let notificationActions: NotificationActionHandler
    private let callHandling: CallHandlingRepository

    init(notificationActions: NotificationActionHandler, callHandling: CallHandlingRepository) {
        self.notificationActions = notificationActions
        self.callHandling = callHandling
    }

    func perform(_ action: WatchAction) async -> Result<Void, WatchActionFailure> {
        switch action {
        case let .reply(workspaceId, threadKey, text):
            await message(.reply(text), workspaceId: workspaceId, threadKey: threadKey)
        case let .markRead(workspaceId, threadKey):
            await message(.markRead, workspaceId: workspaceId, threadKey: threadKey)
        case let .setAvailability(workspaceId, available):
            await callHandling.saveAvailability(workspaceId: workspaceId, availableForCalls: available)
                .map { _ in () }
                .mapError { WatchActionFailure(sentence: FailureText.from($0).message) }
        case .refresh, .resolveMessage:
            // ⚠️ NEITHER WRITES. `.resolveMessage` is answered by ``threadKey(workspaceId:messageId:)``.
            .success(())
        }
    }

    func threadKey(workspaceId: String, messageId: String) async -> Result<String, WatchActionFailure> {
        // ⚠️ THE WATCH SHOWS NO SENTENCE FOR THIS: an unresolved message leaves it on the inbox.
        await notificationActions.threadKey(workspaceId: workspaceId, messageId: messageId)
            .mapError { _ in WatchActionFailure(sentence: InboxCopy.conversationCouldNotOpened) }
    }

    private func message(
        _ action: MessageAction,
        workspaceId: String,
        threadKey: String
    ) async -> Result<Void, WatchActionFailure> {
        await notificationActions.perform(action, workspaceId: workspaceId, threadKey: threadKey)
            .mapError { WatchActionFailure(sentence: $0.reason(for: action)) }
    }
}
