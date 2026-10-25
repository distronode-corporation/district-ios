import ActivityKit
import Foundation

/// One call as its Live Activity shows it: the Lock Screen, the Dynamic Island and, through
/// the iPhone, the Apple Watch Smart Stack.
///
/// ⛔ COMPILED INTO THE APP AND INTO `DistrictAIWidgets` AS SOURCE, so the app that starts and
/// updates an activity and the extension that draws it agree on one type. ActivityKit matches
/// an activity to its `ActivityConfiguration` by this type, and a copy in each target would
/// be two types that happen to share a name.
///
/// ⛔ THE CONTENT STATE IS A WIRE SHAPE. The server's `apns-push-type: liveactivity` pushes
/// carry `content-state` as JSON with exactly these keys (`phase`, `startedAt`, `endedAt`,
/// `latestLine`, `latestSpeaker`, `callerName`), and ActivityKit decodes it with this type's
/// `Codable`. A renamed property is an update that silently never arrives.
///
/// ⛔ THE ONE PLACE A NAME AND CONVERSATION TEXT TRAVEL IN A PUSH (Sean's decision 2026-10-25,
/// GitLab #2). Nothing here, in the app or in the extension, logs a state.
struct DistrictCallActivityAttributes: ActivityAttributes {
    /// What changes during the call.
    ///
    /// ⚠️ THE TIMES ARE ISO-8601 STRINGS, NOT `Date`. ActivityKit decodes a push's
    /// `content-state` with a default `JSONDecoder`, whose `Date` is seconds since 2001, and
    /// the server writes ISO-8601; ``DistrictCallActivityTime`` reads both forms.
    struct ContentState: Codable, Hashable, Sendable {
        var phase: DistrictCallActivityPhase
        var startedAt: String
        var endedAt: String?
        /// The latest final transcript line, trimmed, at most ``DistrictCallActivityLine/limit``
        /// characters.
        var latestLine: String?
        var latestSpeaker: DistrictCallActivitySpeaker?
        /// A name resolved after the start, which the UI prefers to the static one.
        var callerName: String?

        init(
            phase: DistrictCallActivityPhase,
            startedAt: String,
            endedAt: String? = nil,
            latestLine: String? = nil,
            latestSpeaker: DistrictCallActivitySpeaker? = nil,
            callerName: String? = nil
        ) {
            self.phase = phase
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.latestLine = latestLine
            self.latestSpeaker = latestSpeaker
            self.callerName = callerName
        }

        private enum CodingKeys: String, CodingKey {
            case phase, startedAt, endedAt, latestLine, latestSpeaker, callerName
        }

        /// ⚠️ TOLERANT ON PURPOSE: a phase or speaker this build does not know reads as the
        /// nearest one it does, rather than failing the decode and dropping the whole update.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            phase = try DistrictCallActivityPhase(wire: container.decode(String.self, forKey: .phase))
            startedAt = try container.decode(String.self, forKey: .startedAt)
            endedAt = try container.decodeIfPresent(String.self, forKey: .endedAt)
            latestLine = try container.decodeIfPresent(String.self, forKey: .latestLine)
            latestSpeaker = try container.decodeIfPresent(String.self, forKey: .latestSpeaker)
                .flatMap(DistrictCallActivitySpeaker.init(rawValue:))
            callerName = try container.decodeIfPresent(String.self, forKey: .callerName)
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(phase.rawValue, forKey: .phase)
            try container.encode(startedAt, forKey: .startedAt)
            try container.encodeIfPresent(endedAt, forKey: .endedAt)
            try container.encodeIfPresent(latestLine, forKey: .latestLine)
            try container.encodeIfPresent(latestSpeaker?.rawValue, forKey: .latestSpeaker)
            try container.encodeIfPresent(callerName, forKey: .callerName)
        }
    }

    let workspaceId: String
    let callId: String
    /// The caller as known at the start: a name, a masked number, or the "no caller ID" words.
    let callerName: String
}

/// Where the call stands. The raw values are the server's.
enum DistrictCallActivityPhase: String, Codable, Hashable, Sendable, CaseIterable {
    case ringing
    case aiAnswering = "ai_answering"
    case declined
    case messageTaken = "message_taken"
    case transferred
    case ended

    /// ⚠️ AN UNKNOWN PHASE IS THE CALL STILL GOING, the one reading that is never false while
    /// an activity is on screen at all: an ended call arrives as an `end` event too.
    init(wire: String) {
        self = Self(rawValue: wire) ?? .aiAnswering
    }

    /// The call is over: no elapsed timer, and the end time is shown instead.
    var isOver: Bool {
        switch self {
        case .ringing, .aiAnswering: false
        case .declined, .messageTaken, .transferred, .ended: true
        }
    }
}

/// Who said the latest line. The raw values are the server's.
enum DistrictCallActivitySpeaker: String, Codable, Hashable, Sendable {
    case caller
    case assistant
}

/// The latest line's one rule, shared by the app (which writes it) and the extension.
enum DistrictCallActivityLine {
    /// The contract's ceiling, in characters.
    static let limit = 120

    /// The text trimmed, its runs of white space collapsed, and cut to ``limit`` characters
    /// with an ellipsis; nil when nothing is left.
    static func clip(_ text: String) -> String? {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return nil }
        let line = words.joined(separator: " ")
        guard line.count > limit else { return line }
        let cut = line.prefix(limit - 1).trimmingCharacters(in: .whitespaces)
        return cut + "…"
    }
}

/// The ISO-8601 instants in a content state.
enum DistrictCallActivityTime {
    /// `2026-10-25T14:03:00.000Z`, the server's form, which this app writes too.
    static func string(_ date: Date) -> String {
        Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date)
    }

    /// Either form the server writes, with or without fractional seconds; nil for anything
    /// else.
    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        return (try? withFraction.parse(text)) ?? (try? Date.ISO8601FormatStyle().parse(text))
    }
}
