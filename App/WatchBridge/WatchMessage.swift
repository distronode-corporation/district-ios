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

    static var success: WatchReply {
        WatchReply(protocolVersion: WatchSnapshot.currentProtocolVersion, ok: true, error: nil)
    }

    static func failure(_ sentence: String) -> WatchReply {
        WatchReply(protocolVersion: WatchSnapshot.currentProtocolVersion, ok: false, error: sentence)
    }

    func message() -> [String: Any] {
        // ⚠️ AN ENCODING FAILURE OF THREE SCALARS CANNOT HAPPEN; an empty payload reads as
        // unreadable on the watch, which shows the generic failure rather than success.
        [Self.messageKey: (try? WatchWire.encoder.encode(self)) ?? Data()]
    }

    static func read(_ message: [String: Any]) -> WatchReply? {
        guard let data = message[messageKey] as? Data else { return nil }
        return try? WatchWire.decoder.decode(WatchReply.self, from: data)
    }
}
