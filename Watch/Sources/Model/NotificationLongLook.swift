import Foundation
import UserNotifications

/// What the long-look interface of a message alert shows (3.2).
///
/// ⛔ ONLY WHAT THE ALERT ALREADY SAYS. The push carries ids and no text, by decision; the
/// iPhone's notification service extension puts the sender's name in the TITLE
/// (`push.message.title.named`: "New message · {name}"), and the body is the generic sentence.
/// The watch adds nothing it would have to fetch: it holds no credential.
///
/// ⚠️ NO PREVIEW FROM THE WATCH'S SNAPSHOT. Message pushes do not wake the phone app, so the
/// snapshot's row for this sender predates the message, and its preview would be the PREVIOUS
/// message drawn as if it were this one.
struct MessageLongLook: Equatable, Sendable {
    /// The server's category, verbatim (`DistrictNotificationCategory.message` on the phone).
    static let category = "district.message"

    /// The separator the extension's title puts before the name, in both languages.
    static let separator = " · "

    /// The sender's name, or nil when the extension could not name one.
    let sender: String?
    /// The alert's title as shown, for when there is no name.
    let title: String
    let body: String

    init(title: String, body: String) {
        self.title = title
        self.body = body
        sender = Self.sender(fromTitle: title)
    }

    /// The name after the first separator. ⚠️ THE FIRST, so a name that itself holds one stays
    /// whole; nothing after it, or no separator at all, is no name.
    static func sender(fromTitle title: String) -> String? {
        guard let range = title.range(of: separator) else { return nil }
        let name = title[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}

/// What the long-look interface of a call alert shows: the call's card, when the alert names one.
struct CallLongLook: Equatable, Sendable {
    /// The server's category for a ring's alert, verbatim (`PushCategory` on the server).
    static let category = "district.incoming_call"

    let workspaceId: String
    let callId: String

    /// The call an alert's payload names, or nil for anything else. ⚠️ THE TAP'S OWN PARSER
    /// (``WatchNotificationRoute``), so the long look and a tap agree on which call it is.
    init?(userInfo: [AnyHashable: Any]) {
        guard case let .call(workspaceId, callId)? = WatchNotificationRoute.parse(
            WatchNotificationRoute.flatten(userInfo)
        ) else { return nil }
        self.workspaceId = workspaceId
        self.callId = callId
    }
}
