import DistrictAuthCore
import DistrictModel
import Foundation
import UserNotifications

/// "You declined the call. Tell the assistant what to say?": the notification a PERSON's
/// decline leaves behind (3.2, Sean 2026-10-25, GitLab #2).
///
/// ⛔ ONLY AFTER A PERSON'S DECLINE. It is posted by ``IncomingCallDeclineSender``, which runs
/// only for ``IncomingCallCommand/requestDecline(workspace:call:)``, and the reducer emits that
/// only for ``IncomingCallEvent/declinePressed`` while ringing. A timeout, a withdrawal and a
/// ring ended for no session send nothing and so post nothing (``IncomingCallEnding``).
///
/// ⛔ THE PAYLOAD IS AN `incoming_call` PUSH'S OWN SHAPE (`type`, `workspaceId`, `callId`,
/// `PushPayload`'s constants), so a TAP opens the call exactly as a tapped ring alert does, on
/// the phone and on the watch it mirrors to. No name, no number: ids only, as on every push.
///
/// ⚠️ NO SOUND. The person declined a second ago and is holding the phone or looking at the
/// wrist; a second chime for the call they just silenced reads as the call coming back.
enum DeclineSteerNotification {
    /// ⚠️ A LOCAL CATEGORY: the server never sends it, so it is free to name here.
    static let category = "district.declined_steer"
    /// The text box.
    static let typed = "district.declined_steer.typed"
    /// "We will call them back today."
    static let callBackToday = "district.declined_steer.call-back-today"
    /// "Ask what the call is about."
    static let askWhatAbout = "district.declined_steer.ask-what-about"

    /// Whether an identifier names one of this notification's three actions. See
    /// ``MessageNotificationAction/isShadeAction(_:)`` for why the set is a function.
    static func isAction(_ identifier: String) -> Bool {
        identifier == typed || identifier == callBackToday || identifier == askWhatAbout
    }

    /// The category, for ``NotificationCategories/register(on:)``.
    ///
    /// ⛔ `options: []` ON ALL THREE, as on a message's Reply: non-foreground, so an
    /// instruction goes from the lock screen or the wrist without opening the app.
    static func registration() -> UNNotificationCategory {
        let typed = UNTextInputNotificationAction(
            identifier: typed,
            title: IncomingCallCopy.steerTyped,
            options: [],
            textInputButtonTitle: CommonCopy.send,
            textInputPlaceholder: IncomingCallCopy.steerPlaceholder
        )
        let callBack = UNNotificationAction(
            identifier: callBackToday,
            title: IncomingCallCopy.steerCallBackToday,
            options: []
        )
        let ask = UNNotificationAction(identifier: askWhatAbout, title: IncomingCallCopy.steerAskWhatAbout, options: [])
        return UNNotificationCategory(identifier: category, actions: [callBack, ask, typed], intentIdentifiers: [])
    }

    /// What is posted for one declined call.
    static func content(workspaceId: String, callId: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.body = IncomingCallCopy.steerBody
        content.categoryIdentifier = category
        content.userInfo = [
            PushPayload.keyType: PushPayload.typeIncomingCall,
            PushPayload.keyWorkspaceId: workspaceId,
            PushPayload.keyCallId: callId,
        ]
        return content
    }

    /// ⚠️ ONE PER CALL: a second decline of the same call replaces the first notification.
    static func identifier(callId: String) -> String {
        "district.declined-steer.\(callId)"
    }
}

/// Posts ``DeclineSteerNotification``, behind a seam so a test can count the posts.
@MainActor
protocol DeclineSteerPosting {
    func post(workspaceId: String, callId: String)
}

/// ⚠️ FIRE AND FORGET, like the failure notifications: `add` can fail (notifications turned
/// off), and the decline itself has already been sent.
struct UserNotificationsDeclineSteerPoster: DeclineSteerPosting {
    func post(workspaceId: String, callId: String) {
        let request = UNNotificationRequest(
            identifier: DeclineSteerNotification.identifier(callId: callId),
            content: DeclineSteerNotification.content(workspaceId: workspaceId, callId: callId),
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}

/// One pressed action on the declined-call notification: the line, and the call it is for.
struct DeclineSteerAction: Equatable {
    let text: String
    let workspaceId: String?
    let callId: String?

    /// The action a flattened response names (see ``NotificationPresenter``), or nil for
    /// anything else: a tap, a dismiss, a message's Reply.
    ///
    /// ⚠️ A CANNED LINE IS READ HERE, IN THE PHONE'S LANGUAGE NOW, which is the language its
    /// button was drawn in when the category was registered at launch.
    init?(payload: [String: String]) {
        switch payload[MessageNotificationAction.identifierKey] {
        case DeclineSteerNotification.typed: text = payload[MessageNotificationAction.replyTextKey] ?? ""
        case DeclineSteerNotification.callBackToday: text = IncomingCallCopy.steerCallBackToday
        case DeclineSteerNotification.askWhatAbout: text = IncomingCallCopy.steerAskWhatAbout
        default: return nil
        }
        workspaceId = Self.value(payload, PushPayload.keyWorkspaceId)
        callId = Self.value(payload, PushPayload.keyCallId)
    }

    private static func value(_ payload: [String: String], _ key: String) -> String? {
        let trimmed = payload[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Sends a declined-call instruction to the assistant: `POST /api/district/calls/whisper`.
///
/// ⛔ THE SAME RULES AS A MESSAGE'S REPLY FROM THE SHADE (``NotificationActionHandler``, which
/// owns this and is its only caller): the token first and through the one coordinator, one
/// request per action, a background task for the whole length, nothing retried. A whisper that
/// timed out may have reached the assistant, and a second one is a second instruction.
@MainActor
final class DeclineSteerHandler {
    private let coordinator: TokenRefreshCoordinator
    private let whisper: any WhisperSending
    private let backgroundTasks: any BackgroundTaskScheduling
    private var inFlight: [String: Task<Result<Void, MessageActionFailure>, Never>] = [:]

    init(
        coordinator: TokenRefreshCoordinator,
        whisper: any WhisperSending,
        backgroundTasks: any BackgroundTaskScheduling
    ) {
        self.coordinator = coordinator
        self.whisper = whisper
        self.backgroundTasks = backgroundTasks
    }

    func perform(_ action: DeclineSteerAction) async -> Result<Void, MessageActionFailure> {
        // ⚠️ AN EMPTY BOX IS NOT A FAILURE, as for a reply: the route would answer 400.
        let line = action.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return .success(()) }
        guard let workspaceId = action.workspaceId, let callId = action.callId else {
            return .failure(.unreadablePayload)
        }
        let key = "steer:\(workspaceId):\(callId):\(line)"
        if let running = inFlight[key] {
            return await running.value
        }
        let task = Task { [self] in
            let lease = BackgroundTaskLease.begin("district.decline-steer", on: backgroundTasks)
            let outcome = await send(line, workspaceId: workspaceId, callId: callId)
            lease.end()
            inFlight[key] = nil
            return outcome
        }
        inFlight[key] = task
        return await task.value
    }

    private func send(_ line: String, workspaceId: String, callId: String) async -> Result<Void, MessageActionFailure> {
        switch await coordinator.accessToken() {
        case .available:
            break
        case let .reauthRequired(reason):
            return .failure(.signedOut(reason))
        case let .retryLater(reason):
            return .failure(.sessionUnavailable(reason))
        }
        return await whisper.whisper(workspaceId: workspaceId, callId: callId, text: line)
            .mapError { .refused($0) }
    }
}

extension MessageActionFailure {
    /// Why an instruction from the declined-call notification did not reach the assistant.
    ///
    /// ⚠️ A CALL THAT ENDED IS SAID AS MUCH (404, `call_not_in_progress`), through the watch's
    /// own rule for the same route (``WatchLiveComposer/whisperFailure(_:)``).
    @MainActor
    var steerReason: String {
        switch self {
        case .unreadablePayload, .threadNotFound, .unresolved:
            CallsCopy.callNotAvailable
        case let .signedOut(reason):
            SessionModel.text(for: reason).isEmpty ? SessionCopy.sessionHasEndedPlease : SessionModel.text(for: reason)
        case let .sessionUnavailable(reason):
            SessionModel.text(for: reason)
        case let .refused(error):
            WatchLiveComposer.whisperFailure(error).sentence
        }
    }
}
