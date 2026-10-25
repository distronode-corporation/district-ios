import Foundation
import UserNotifications

/// Puts the sender's name on a message alert, and leaves every other alert exactly as sent.
///
/// ⛔ THE EXTENSION HOLDS NO SESSION AND REFRESHES NOTHING. It reads one item, the notify-read
/// token in the shared Keychain group (the only group it is entitled to), and asks one route
/// one question. See ``MessageAlertNaming`` for the decisions and why each failure is the
/// alert as sent.
///
/// ⛔ THE CONTENT HANDLER IS CALLED EXACTLY ONCE, whichever comes first: the answer, or
/// `serviceExtensionTimeWillExpire`. A second call is ignored, a missing one would leave iOS
/// to show the original late.
///
/// ⚠️ `@unchecked Sendable`: the handler and the original content are set once in
/// ``didReceive(_:withContentHandler:)``, before any task starts, and taken under ``lock``.
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private let lock = NSLock()
    private var deliver: ((UNNotificationContent) -> Void)?
    private var original: UNNotificationContent?
    private var work: Task<Void, Never>?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        let content = request.content
        lock.withLock {
            deliver = contentHandler
            original = content
        }
        let payload = content.userInfo.reduce(into: [String: String]()) { flat, pair in
            if let key = pair.key as? String, let value = pair.value as? String {
                flat[key] = value
            }
        }
        guard let target = MessageAlertNaming.target(
            categoryIdentifier: content.categoryIdentifier,
            payload: payload
        ) else {
            finish(named: nil)
            return
        }
        work = Task { [weak self] in
            let name = await MessageAlertNaming.senderName(
                of: target,
                tokens: NotifyTokenKeychain(),
                fetcher: PendingSenderNameFetcher(),
                now: Date()
            )
            self?.finish(named: name)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        work?.cancel()
        finish(named: nil)
    }

    /// Deliver the alert: with the name in its title when there is one, as sent otherwise.
    private func finish(named name: String?) {
        let pending = lock.withLock { () -> (((UNNotificationContent) -> Void)?, UNNotificationContent?) in
            defer { deliver = nil }
            return (deliver, original)
        }
        guard let handler = pending.0, let original = pending.1 else { return }
        handler(Self.content(from: original, name: name))
    }

    private static func content(from original: UNNotificationContent, name: String?) -> UNNotificationContent {
        let template = Bundle.main.localizedString(forKey: MessageAlertNaming.titleKey, value: nil, table: nil)
        guard let name,
              let title = MessageAlertNaming.title(template: template, name: name),
              let named = original.mutableCopy() as? UNMutableNotificationContent
        else { return original }
        named.title = title
        return named
    }
}
