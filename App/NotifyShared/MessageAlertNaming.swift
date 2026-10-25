import Foundation

/// The message a message alert is about, read off its payload.
struct MessageAlertTarget: Equatable, Sendable {
    let workspaceId: String
    let messageId: String
}

/// Asks the server who sent a message, with the notify-read token.
///
/// ⚠️ A SEAM, SO THE DECISIONS BELOW ARE TESTED WITHOUT A NETWORK. ⛔ IT NEVER REFRESHES
/// ANYTHING: the notify token is not renewable from here, and the session is out of reach.
protocol SenderNameFetching: Sendable {
    /// The contact's display name, or nil when the thread has no named contact.
    func senderName(of target: MessageAlertTarget, token: String) async throws -> String?
}

/// Until the request exists: no name, so every alert is shown exactly as sent.
///
/// ⚠️ PENDING district-core-swift 7.2.0: replace with a fetcher over the core's `messageSender`
/// endpoint (`GET messages/{id}/sender?workspaceId=`), sent with the notify token as the
/// bearer, a URLSession timeout inside ``MessageAlertNaming/budget``, and no refresh on 401.
/// On a 401 the extension may clear the token (``NotifyTokenKeychain/clear()``), so the
/// app's next launch finds it missing and mints a new one.
struct PendingSenderNameFetcher: SenderNameFetching {
    func senderName(of _: MessageAlertTarget, token _: String) async throws -> String? {
        nil
    }
}

/// What the notification service extension decides about a message alert.
///
/// ⛔ THE ALERT AS SENT IS ALWAYS A CORRECT ANSWER, and every failure ends there: not a
/// message alert, no token, a Keychain that cannot answer (the phone has not been unlocked
/// since it restarted), an expired token, a refusal, no name, or no answer inside
/// ``budget``. The extension then shows "New message" exactly as the server sent it.
///
/// ⚠️ COMPILED INTO THE APP AS WELL AS THE EXTENSION, so `DistrictAITests` can hold it.
enum MessageAlertNaming {
    /// ⛔ THE SERVER'S CATEGORY, VERBATIM: `DistrictNotificationCategory.message` in the app,
    /// restated because the extension does not compile the app's sources. A test pins the two.
    static let category = "district.message"

    /// ⚠️ WELL INSIDE THE ~30 SECONDS iOS GIVES THE EXTENSION: a name that takes longer than
    /// this would arrive after the person has already read the alert.
    static let budget: Duration = .seconds(5)

    /// The key and the placeholder of the named title in the extension's string table.
    static let titleKey = "push.message.title.named"
    static let namePlaceholder = "{name}"

    /// The message a payload names, when it is a message alert with both ids.
    static func target(categoryIdentifier: String, payload: [String: String]) -> MessageAlertTarget? {
        let category = categoryIdentifier.isEmpty ? payload["category"] : categoryIdentifier
        guard category == Self.category,
              let workspaceId = payload["workspaceId"], !workspaceId.isEmpty,
              let messageId = payload["messageId"], !messageId.isEmpty
        else { return nil }
        return MessageAlertTarget(workspaceId: workspaceId, messageId: messageId)
    }

    /// The sender's name for the alert, or nil to leave the alert as sent.
    static func senderName(
        of target: MessageAlertTarget,
        tokens: any NotifyTokenReading,
        fetcher: any SenderNameFetching,
        now: Date,
        budget: Duration = MessageAlertNaming.budget
    ) async -> String? {
        guard let stored = try? tokens.read(), stored.isLive(at: now) else { return nil }
        let token = stored.token
        let name = await withTaskGroup(of: String?.self) { group in
            group.addTask { try? await fetcher.senderName(of: target, token: token) }
            group.addTask {
                try? await Task.sleep(for: budget)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        return displayable(name)
    }

    /// The title with the name in it. ⚠️ A template without the placeholder (a table that
    /// did not load) gives nil, and the alert keeps its own title.
    static func title(template: String, name: String) -> String? {
        guard template.contains(namePlaceholder) else { return nil }
        return template.replacingOccurrences(of: namePlaceholder, with: name)
    }

    /// ⚠️ A NAME IS DISPLAY TEXT FROM THE SERVER: trimmed, and blank is no name.
    static func displayable(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
