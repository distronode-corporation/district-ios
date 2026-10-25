import Foundation

/// A write the watch asks the phone to make.
///
/// ⛔ SENT WITH `sendMessage` AND A REPLY HANDLER, NEVER `transferUserInfo`. A queued
/// transfer is delivered whenever the system likes, possibly hours later and after the
/// person has given up, and nothing tells the watch whether it worked. A message either
/// reaches a reachable phone now and is answered, or fails now and the watch says so.
///
/// ⚠️ REPLY AND MARK READ NAME A THREAD, NOT A MESSAGE. The phone's conversation list
/// (`GET conversations`) carries no message id, so the watch has the thread key the list
/// is keyed on; the phone acts on that thread through ``NotificationActionHandler``.
enum WatchAction: Codable, Equatable, Sendable {
    case reply(workspaceId: String, threadKey: String, text: String)
    case markRead(workspaceId: String, threadKey: String)
    case setAvailability(workspaceId: String, available: Bool)
    /// Send a fresh snapshot now. Writes nothing.
    case refresh
    /// Which thread a message belongs to, for a tapped notification. Writes nothing.
    ///
    /// ⛔ THE PHONE RESOLVES IT, BECAUSE ONLY THE PHONE CAN. A message push carries
    /// `workspaceId` and `messageId` and, by decision, no thread key (see `PushEvent.message`
    /// in DistrictModel), and the watch makes no request; the phone spends
    /// `GET messages/{id}` under its own bearer and answers ``WatchReply/threadKey``.
    ///
    /// ⚠️ NO PROTOCOL BUMP, ON PURPOSE. A phone that predates this case cannot decode the
    /// request and answers "update both apps", which the watch treats as unresolved and
    /// stays on the inbox. Bumping would instead blank every watch until both apps update.
    case resolveMessage(workspaceId: String, messageId: String)

    // MARK: - Live calls (round 2)

    //
    // ⚠️ NO PROTOCOL BUMP FOR THESE EITHER, for the reason on ``resolveMessage(workspaceId:messageId:)``.
    // A phone that predates them answers "update both apps", and the watch hides Live, steering
    // and the summary card rather than blanking everything else.

    /// The workspace's calls in progress, answered ``WatchReply/liveCalls``. Writes nothing.
    case liveList(workspaceId: String)
    /// Start relaying a call's transcript; answered ``WatchReply/live`` with everything so far.
    case liveSubscribe(workspaceId: String, callId: String)
    /// "Still watching", about every 5 s, answered with what is new since `cursor`.
    ///
    /// ⛔ THE PHONE STOPS AFTER 20 s WITHOUT ONE: a watch that walked away, slept or crashed
    /// sends no unsubscribe, and the phone must not keep a socket open for nobody.
    /// `roundTripMilliseconds` is how long the watch waited for the previous answer, for the
    /// phone's diagnostics log; nil when there was none.
    case liveKeepalive(workspaceId: String, callId: String, cursor: String?, roundTripMilliseconds: Int?)
    /// The transcript screen closed.
    case liveUnsubscribe(workspaceId: String, callId: String)
    /// One line for the assistant, from the Live screen (`POST calls/whisper`).
    ///
    /// ⛔ THIRD PERSON, BECAUSE IT ARRIVES AS A SUPERVISOR'S INSTRUCTION, never spoken as is.
    case whisper(workspaceId: String, callId: String, text: String)
    /// The after-call card, answered ``WatchReply/card``. Writes nothing.
    case callDetail(workspaceId: String, callId: String)
}

struct WatchRequest: Codable, Equatable, Sendable {
    static let messageKey = "district.watch.request"

    var protocolVersion: Int
    var action: WatchAction

    init(action: WatchAction, protocolVersion: Int = WatchSnapshot.currentProtocolVersion) {
        self.protocolVersion = protocolVersion
        self.action = action
    }

    func message() throws -> [String: Any] {
        try [Self.messageKey: WatchWire.encoder.encode(self)]
    }

    /// The request in a message, or nil when there is none this build can read.
    static func read(_ message: [String: Any]) -> Data? {
        message[messageKey] as? Data
    }
}

/// The phone's answer: done, or a sentence saying why not, in the phone's language.
struct WatchReply: Codable, Equatable, Sendable {
    static let messageKey = "district.watch.reply"

    var protocolVersion: Int
    var ok: Bool
    var error: String?
    /// ``WatchAction/resolveMessage(workspaceId:messageId:)``'s answer; nil for every
    /// other request. ⚠️ Optional, so a reply from an older phone still decodes.
    var threadKey: String?
    /// ``WatchAction/liveList(workspaceId:)``'s answer. ⛔ nil FROM A PHONE THAT DOES NOT KNOW
    /// THE REQUEST, which is how the watch learns to hide Live.
    var liveCalls: [WatchLiveCall]?
    /// A subscribe's or a keepalive's answer.
    var live: WatchLiveUpdate?
    /// ``WatchAction/callDetail(workspaceId:callId:)``'s answer.
    var card: WatchCallCard?

    static var success: WatchReply {
        WatchReply(protocolVersion: WatchSnapshot.currentProtocolVersion, ok: true, error: nil)
    }

    static func failure(_ sentence: String) -> WatchReply {
        WatchReply(protocolVersion: WatchSnapshot.currentProtocolVersion, ok: false, error: sentence)
    }

    static func thread(_ threadKey: String) -> WatchReply {
        WatchReply(protocolVersion: WatchSnapshot.currentProtocolVersion, ok: true, error: nil, threadKey: threadKey)
    }

    static func liveCalls(_ calls: [WatchLiveCall]) -> WatchReply {
        var reply = success
        reply.liveCalls = calls
        return reply
    }

    static func live(_ update: WatchLiveUpdate) -> WatchReply {
        var reply = success
        reply.live = update
        return reply
    }

    static func card(_ card: WatchCallCard) -> WatchReply {
        var reply = success
        reply.card = card.fitted()
        return reply
    }

    func message() -> [String: Any] {
        // ⚠️ AN ENCODING FAILURE OF PLAIN STRINGS AND NUMBERS CANNOT HAPPEN; an empty payload reads as
        // unreadable on the watch, which shows the generic failure rather than success.
        [Self.messageKey: (try? WatchWire.encoder.encode(self)) ?? Data()]
    }

    static func read(_ message: [String: Any]) -> WatchReply? {
        guard let data = message[messageKey] as? Data else { return nil }
        return try? WatchWire.decoder.decode(WatchReply.self, from: data)
    }
}
