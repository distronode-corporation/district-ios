import Foundation

/// What a push payload turned out to mean.
///
/// Port of the Android client's `PushEvent`. The two cases are named
/// after the Kotlin ones (`Message`, `IncomingCall`) so the mapping is
/// greppable across the two clients.
///
/// ⛔ THE PAYLOAD CARRIES IDENTIFIERS AND NOTHING ELSE, WHICH IS A SERVER-SIDE
/// PRIVACY DECISION THIS TYPE EXISTS TO MAKE STRUCTURAL. A push notification is
/// readable by the operating system and, on this platform, by a Notification
/// Service Extension; there is no message body here, no phone number, no email
/// address and, the expensive one, no LiveKit token. The server's push sender
/// guarantees that, and the shape of this type is what stops a client
/// author from "conveniently" reading a field that must never be sent. If a
/// field like that ever appears in a payload, adding it here is the wrong fix.
///
/// ⛔ SO EVERY BRANCH ENDS IN A FETCH UNDER THIS APP'S OWN BEARER. That is the
/// only point in the chain where a request is attributable to a PERSON rather
/// than to a handset, and it is why an incoming call is answered by calling
/// `calls/{id}/answer` rather than by joining a room the push described.
public enum PushEvent: Equatable, Sendable {
    /// A message arrived in a workspace's inbox.
    ///
    /// ⚠️ THE ID IS NOT A THREAD KEY, AND THAT IS WHY IT COSTS A REQUEST. `messageId`
    /// names one row, and the inbox groups rows into threads server-side over a
    /// bounded window, so there is no client-side way to turn this into a thread.
    /// ⛔ Widening the payload to carry one is the fix that must not be taken: a
    /// `threadKey` is `addr:<address>` whenever the thread has no `Contact` row,
    /// which puts a customer's phone number or email address on a lock screen and
    /// in front of any installed notification-listener app.
    /// ⚠️ `GET /api/district/messages/{id}` is the resolver, spent under this app's
    /// own bearer. See ``PushDeepLinkDecision/openMessage(workspaceId:messageId:)``.
    case message(workspaceId: String, messageId: String)

    /// A call is ringing and this workspace's devices are being asked to take
    /// it.
    ///
    /// ⛔ THE SERVER IS BLOCKING ON THIS. `actions/ring-app` pushes and then
    /// polls a Redis rendezvous for ~25 seconds; the agent's transfer is held
    /// open for that window and falls back to PSTN when it expires. So the cost
    /// of mishandling this event is a caller sitting in silence, and the cost of
    /// handling it EARLY, answering before a human pressed anything, is a caller
    /// handed to nobody. Nothing may call the answer route on the strength of
    /// this event alone.
    case incomingCall(workspaceId: String, callId: String)

    /// The workspace the event is about, whichever case this is.
    ///
    /// ⚠️ CARRIED EVEN WHEN IT IS THE SELECTED ONE. A push can arrive for any
    /// workspace the account belongs to, and the app's selected workspace is
    /// client state that need not match, so the consumer COMPARES rather than
    /// assumes. See ``pushDeepLinkDecision(pending:selectedWorkspaceId:)``.
    public var workspaceId: String {
        switch self {
        case let .message(workspaceId, _): workspaceId
        case let .incomingCall(workspaceId, _): workspaceId
        }
    }
}

/// The one place a raw push `data` map becomes a ``PushEvent``.
///
/// Port of Kotlin's `PushPayload` object, constants included.
///
/// ⛔ PURE, AND THAT IS WHAT MAKES IT THE ONLY PART OF THE PUSH PATH THAT CAN BE
/// TESTED WITHOUT A DEVICE AT ALL. Delivery, background wake and token
/// acquisition are all real-device work; a `[String: String]` in and an enum out is exercisable
/// on Linux, and it is where every hostile-payload decision lives.
///
/// ⛔ UNKNOWN TYPES ARE DROPPED SILENTLY AND MUST STAY THAT WAY. The server is
/// free to add a push type before this build is on every handset, which is the
/// ordinary state of a shipped app, so an unrecognised `type` is forward
/// compatibility rather than an error, and a client that surfaced it would show
/// users a notification about a feature they do not have. It is the same
/// "strict in the gate, lenient in the field" rule the contract gate states.
///
/// ⛔ AND A MISSING ID IS A DROP RATHER THAN A DEFAULT. Every field of the data
/// payload is a string the sender chose, and this map is the least trustworthy
/// input in the app: it arrives unauthenticated from the OS's perspective, and a
/// malformed one is indistinguishable from a malicious one. A blank
/// `workspaceId` would produce a notification about nothing, and a blank
/// `callId` a ringing screen whose Answer button could only ever 404.
public enum PushPayload {
    /// ⚠️ These four names are the server's push-payload keys, verbatim.
    public static let keyType: String = "type"
    public static let keyWorkspaceId: String = "workspaceId"
    public static let keyMessageId: String = "messageId"
    public static let keyCallId: String = "callId"

    public static let typeMessage: String = "message"
    public static let typeIncomingCall: String = "incoming_call"

    /// Parse a data payload.
    ///
    /// - Returns: the event, or `nil` for anything this build cannot act on.
    ///
    /// ⚠️ VALUES ARE TRIMMED AND BLANKS TREATED AS ABSENT, because the data
    /// payload has exactly one type, string, so "no id" and "an empty id" are
    /// the same wire shape and a whitespace-only value is what a mis-templated
    /// sender produces.
    ///
    /// ⚠️ THE TYPE IS MATCHED EXACTLY, not case-insensitively and not by prefix.
    /// Loosening it would mean a future `incoming_call_v2` silently taking the
    /// old branch, which on this path means ringing a phone with a payload this
    /// build cannot fully read.
    public static func parse(_ data: [String: String]) -> PushEvent? {
        guard let workspaceId = value(data, keyWorkspaceId) else { return nil }
        // ⛔ A nil type lands in `default` with every unrecognised one. See the
        // ⛔ on the enum: silence is forward compatibility.
        guard let type = value(data, keyType) else { return nil }
        switch type {
        case typeMessage:
            guard let messageId = value(data, keyMessageId) else { return nil }
            return .message(workspaceId: workspaceId, messageId: messageId)
        case typeIncomingCall:
            guard let callId = value(data, keyCallId) else { return nil }
            return .incomingCall(workspaceId: workspaceId, callId: callId)
        default:
            return nil
        }
    }

    /// Parse an APNs `userInfo` dictionary.
    ///
    /// ⚠️ FCM PLACES THE `data` KEYS AT THE TOP LEVEL OF `userInfo`, alongside
    /// `aps`, rather than nesting them under a `data` key. So the flattening
    /// below is the whole adaptation: keep the top-level entries that are a
    /// `String` mapped to a `String` and hand them to ``parse(_:)``.
    ///
    /// ⛔ EVERYTHING ELSE IS DISCARDED RATHER THAN COERCED. `aps` is a nested
    /// dictionary and a hostile sender can put any plist type anywhere, so a
    /// `description` of a non-string value would let `"1"` and `1` mean the same
    /// thing on a path where the ids are compared for equality. Dropping is the
    /// same decision the parser makes about every other malformed field.
    public static func parse(userInfo: [AnyHashable: Any]) -> PushEvent? {
        var data: [String: String] = [:]
        for (key, value) in userInfo {
            guard let key = key as? String else { continue }
            guard let value = value as? String else { continue }
            data[key] = value
        }
        return parse(data)
    }

    private static func value(_ data: [String: String], _ key: String) -> String? {
        guard let raw = data[key] else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
