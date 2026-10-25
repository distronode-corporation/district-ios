import Foundation

// The wrist's live transcript, its steering and its after-call card: what the phone answers
// to the watch's live requests (see ``WatchAction``).
//
// ⛔ COMPILED INTO BOTH APPS, LIKE ``WatchSnapshot``, AND DISPLAY-READY FOR THE SAME REASON:
// the watch links no DistrictCore and makes no request, so every string here is already in
// the phone's language and every decision (who may steer, whether a summary is still coming)
// is already made.
//
// ⛔ NONE OF THIS IS EVER PERSISTED ON THE WATCH. A transcript is what a caller said, and the
// App Group, the snapshot and the application context all outlive the screen: the watch holds
// these values in memory, for the screen that asked, and drops them when it closes.
//
// ⚠️ EVERY FIELD A LATER PHONE ADDS MUST BE OPTIONAL. These ride a reply, not the snapshot, so
// there is no protocol version in front of them: an older watch decodes what it knows and
// ignores the rest.

/// A call in progress, as the watch lists it.
struct WatchLiveCall: Codable, Hashable, Sendable, Identifiable {
    /// The call id.
    var id: String
    var workspaceId: String
    /// The contact's name, or a masked number (``WatchMasking``), or the "no caller ID" sentence.
    var caller: String
    /// When it started, for "3 min ago" against the watch's clock.
    var startedAt: Date?
    /// ⛔ FALSE FOR A VIEWER. The watch draws no steering buttons at all then, rather than
    /// buttons the server refuses.
    var canWhisper: Bool
}

/// Where a watched transcript stands.
enum WatchLivePhase: String, Codable, Sendable {
    /// Subscribed; nothing heard yet. ⚠️ The server holds a subscribe until the assistant's
    /// first line, up to 30 s, so this can last.
    case connecting
    case live
    /// The call ended. The watch moves to the call's summary card.
    case ended
    /// No live transcript can be had for this call (not AI-handled, or refused).
    case unavailable
}

/// One line of the transcript, display-ready.
struct WatchLiveLine: Codable, Hashable, Sendable, Identifiable {
    /// The segment id, unique within the call.
    var id: String
    /// The order key: the assistant session, then the line's place in it.
    var epoch: Int64
    var index: Int
    /// "Caller", or the persona's name, in the phone's language.
    var speaker: String
    var fromCaller: Bool
    var text: String
}

/// The phone's answer to a subscribe or a keepalive.
///
/// ⛔ ONLY WHAT THE WATCH DOES NOT HAVE YET. ``cursor`` names the phone's relay session; while
/// the watch sends it back unchanged, ``lines`` are the final lines it has not been sent, and
/// ``retracted`` the ones it holds that the caller had erased. A new cursor comes with
/// ``reset``, and the watch replaces everything it holds.
///
/// ⚠️ INTERIM LINES ARE COALESCED: only the newest one is sent, and it replaces the last.
struct WatchLiveUpdate: Codable, Equatable, Sendable {
    var callId: String
    var cursor: String
    var reset: Bool
    var lines: [WatchLiveLine]
    var retracted: [String]
    var interim: WatchLiveLine?
    var phase: WatchLivePhase
    /// False when the server's memory did not reach back to the call's first line.
    var complete: Bool

    /// ⚠️ HALF OF WHAT A WatchConnectivity REPLY CARRIES, like ``WatchSnapshot/maximumEncodedBytes``.
    static let maximumEncodedBytes = 32 * 1024

    /// The longest line sent, in `Character`s. A segment may be 2000 UTF-16 units; a wrist
    /// reads far less, and the phone keeps the whole transcript.
    static let lineLimit = 600

    /// ⛔ THE OLDEST LINES GO FIRST. What is being said now is what the wrist is for; the
    /// earlier lines are on the phone and in the transcript after the call. Returns the lines
    /// that were dropped too, so the relay counts them as sent and never offers them again.
    func fitted() -> (update: WatchLiveUpdate, dropped: [String]) {
        var candidate = self
        candidate.lines = lines.map(Self.shortened)
        candidate.interim = interim.map(Self.shortened)
        var dropped: [String] = []
        while let data = try? WatchWire.encoder.encode(candidate), data.count > Self.maximumEncodedBytes {
            guard !candidate.lines.isEmpty else {
                candidate.interim = nil
                break
            }
            dropped.append(candidate.lines.removeFirst().id)
        }
        return (candidate, dropped)
    }

    private static func shortened(_ line: WatchLiveLine) -> WatchLiveLine {
        guard line.text.count > lineLimit else { return line }
        var short = line
        short.text = "…" + String(line.text.suffix(lineLimit))
        return short
    }
}

/// The card after a call: who, how it went, and what the summary says.
struct WatchCallCard: Codable, Equatable, Sendable {
    var callId: String
    var workspaceId: String
    var caller: String
    /// The status as the call log says it, with the transfer outcome when there is one.
    var outcome: String
    var time: String
    /// The AI summary, when there is one.
    var summary: String?
    /// ⛔ TRUE ONLY WHILE ONE MAY STILL ARRIVE. The watch says "Summary on its way" and asks
    /// again; a summary that failed to be written is not pending, and ``summaryNote`` says so.
    var summaryPending: Bool
    /// What to say instead of a summary, once none is coming.
    var summaryNote: String?
    var actionItems: [String]
    var inProgress: Bool
    /// ⛔ WHETHER THE PHONE CAN DIAL THIS CALLER BACK. The number never comes to the watch:
    /// Handoff carries the call id and the phone looks the number up.
    var canCallBack: Bool

    /// The most action items a card carries, and the longest summary, in `Character`s.
    static let actionItemLimit = 8
    static let summaryLimit = 1200

    /// Trimmed to what a wrist reads, so a reply always fits.
    func fitted() -> WatchCallCard {
        var card = self
        if let summary, summary.count > Self.summaryLimit {
            card.summary = String(summary.prefix(Self.summaryLimit)) + "…"
        }
        card.actionItems = Array(actionItems.prefix(Self.actionItemLimit)).map { item in
            item.count > 200 ? String(item.prefix(200)) + "…" : item
        }
        return card
    }
}

/// The Handoff that opens the iPhone's dialler on a call's caller.
///
/// ⛔ THE CALL ID TRAVELS, NEVER THE NUMBER. A Handoff activity is visible to the person's
/// other devices and to the system; the phone looks the number up under its own session,
/// with the same rule as its "Call them back" list.
enum CallBackHandoff {
    /// ⛔ LISTED IN THE iOS APP'S `NSUserActivityTypes` (project.yml), or iOS never offers it.
    static let activityType = "com.distronode.district.call-back"
    static let keyWorkspaceId = "workspaceId"
    static let keyCallId = "callId"

    static func userInfo(workspaceId: String, callId: String) -> [String: String] {
        [keyWorkspaceId: workspaceId, keyCallId: callId]
    }

    /// The call an activity names, or nil when it names none.
    static func parse(_ userInfo: [AnyHashable: Any]?) -> (workspaceId: String, callId: String)? {
        guard let workspaceId = (userInfo?[keyWorkspaceId] as? String).flatMap(nonBlank),
              let callId = (userInfo?[keyCallId] as? String).flatMap(nonBlank)
        else { return nil }
        return (workspaceId, callId)
    }

    private static func nonBlank(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
