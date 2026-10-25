import DistrictData
import DistrictNetwork
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

/// The real fetcher: `GET /api/district/messages/{id}/sender?workspaceId=`, through the core's
/// `InboxRepository.messageSender` (district-core-swift 8.0.0), with the notify token as the
/// bearer.
///
/// ⛔ THE CLIENT'S TOKEN PROVIDER ANSWERS THE NOTIFY TOKEN AND NOTHING ELSE. It never sees the
/// session (which this process cannot read), and nothing here refreshes or mints: the app does
/// that (`NotifyTokenRenewal`).
///
/// ⛔ A 401 FORGETS THE TOKEN, and only that token. ``ApiClient`` reports the bearer every 401
/// answered to `rejectedToken`; the extension then clears the stored token if it is still the
/// one refused (``NotifyTokenStoring/clear(ifStill:)``), so the app's next launch finds none and
/// mints, and a token the app minted in the meantime survives.
///
/// ⚠️ THE FIVE-SECOND BUDGET IS ENFORCED TWICE: ``MessageAlertNaming/senderName(of:tokens:fetcher:now:budget:)``
/// stops waiting, and the extension's transport gives up on the request at the same bound.
struct NotifyReadSenderNameFetcher: SenderNameFetching {
    let transport: any HTTPTransport
    var baseURL: URL = ApiClient.productionBaseURL
    /// Told the token a 401 answered.
    let rejected: @Sendable (String) -> Void

    func senderName(of target: MessageAlertTarget, token: String) async throws -> String? {
        let rejected = rejected
        let client = ApiClient(
            baseURL: baseURL,
            transport: transport,
            accessToken: { token },
            rejectedToken: { rejected($0) }
        )
        return try await InboxRepository(client: client)
            .messageSender(workspaceId: target.workspaceId, messageId: target.messageId)
            .get()
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
