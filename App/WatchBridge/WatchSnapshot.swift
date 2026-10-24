import Foundation

/// Everything the watch shows, as the iPhone last saw it.
///
/// ⛔ COMPILED INTO BOTH THE iOS APP AND THE WATCH APP, AND NOTHING ELSE MAY BE. The watch
/// holds no credential, makes no request and links no DistrictCore, so every string in
/// here is DISPLAY-READY and already in the phone's language: the phone formats, the watch
/// draws. A field that needs DistrictCore to interpret does not belong in this type.
///
/// ⛔ ``protocolVersion`` IS CHECKED BEFORE ANYTHING ELSE IS DECODED. The two apps ship in
/// one bundle but are installed and launched separately, so a watch can briefly hold a
/// different build from its phone. A version this build does not know is not decoded at
/// all (see ``WatchSnapshot/read(_:)``); the watch says "Update District AI on your
/// iPhone" rather than guessing at a shape.
///
/// ⚠️ SENT WITH `updateApplicationContext`, WHICH KEEPS ONLY THE LATEST DICTIONARY. That
/// is the right delivery for a picture of state (an older snapshot is worthless once a
/// newer one exists), and it is why this is one value rather than a stream of changes.
/// The dictionary has a size limit (about 64 KB); ``maximumEncodedBytes`` keeps well
/// under it and ``fitted()`` trims the lists, never the state, to stay there.
struct WatchSnapshot: Codable, Equatable, Sendable {
    /// The shape both sides agree on. ⛔ Bump it for any change an older reader would
    /// misread, and in the same change teach ``read(_:)`` nothing new: a mismatch is
    /// shown as "update", never decoded.
    static let currentProtocolVersion = 1

    /// The key in the application context dictionary.
    static let contextKey = "district.watch.snapshot"

    /// ⚠️ HALF OF WHAT WatchConnectivity ACCEPTS, ON PURPOSE. The limit is not published
    /// as a constant and has moved between releases; half of it leaves room for the
    /// property-list overhead around the encoded bytes.
    static let maximumEncodedBytes = 32 * 1024

    /// How many rows of each list the phone sends.
    static let listLimit = 10

    /// After this long, the watch says when it was last updated.
    static let staleAfter: TimeInterval = 15 * 60

    var protocolVersion: Int
    var generatedAt: Date

    /// The phone's chosen language: `en` or `fr-CA`. nil from a phone that did not say,
    /// in which case the watch follows its own locale.
    var language: String?

    /// ⛔ FALSE CLEARS THE WATCH. A signed-out snapshot carries no workspace and no rows,
    /// so a signed-out phone leaves nothing of the last account on the wrist.
    var signedIn: Bool

    /// nil while signed in means no workspace resolved on the phone.
    var workspace: Workspace?

    /// nil means the phone could not read it, which is not "not available".
    var availability: Availability?

    /// nil means the phone could not read it, which is not zero.
    var unreadCount: Int?

    /// nil means the phone could not read the call log, which is not an empty one.
    var calls: [Call]?

    /// nil means the phone could not read the inbox, which is not an empty one.
    var conversations: [Conversation]?

    struct Workspace: Codable, Equatable, Sendable {
        var id: String
        var name: String
    }

    /// Whether calls in ``WatchSnapshot/workspace`` ring this person.
    ///
    /// ⛔ ABOUT ONE WORKSPACE, AND THE WATCH NAMES IT. The same person can be available in
    /// one workspace and not another (see `AvailabilityStatus` on the phone).
    struct Availability: Codable, Equatable, Sendable {
        var workspaceId: String
        var available: Bool
        /// ⛔ FALSE WHEN THE SERVER GAVE A REASON (a viewer, no member row): the watch draws
        /// the reason, not a switch the server will refuse.
        var canToggle: Bool
        /// The reason, in the phone's language, when ``canToggle`` is false.
        var note: String?
    }

    struct Call: Codable, Equatable, Sendable, Identifiable {
        var id: String
        /// The contact's name, or a masked number, or the "no caller ID" sentence.
        var caller: String
        /// Inbound or Outbound, as a word.
        var direction: String
        /// When, as an absolute date and time in the phone's language and zone.
        var time: String
        /// When, relative to ``WatchSnapshot/generatedAt`` ("5 min ago"). The watch
        /// re-reads ``occurredAt`` against its own clock when it has one.
        var relativeTime: String
        var occurredAt: Date?
        /// The status as the call log says it, with the transfer outcome when there is one.
        var outcome: String
        var duration: String?
    }

    struct Conversation: Codable, Hashable, Sendable, Identifiable {
        /// ⛔ THE THREAD KEY (`contact:<id>` or `addr:<address>`), which is what the phone
        /// acts on. The conversation list carries no message id; see ``WatchAction``.
        var id: String
        var workspaceId: String
        var title: String
        /// One line of the latest message, direction glyph first.
        var preview: String
        var unread: Bool
        /// ⛔ FALSE WHEN THE SERVER OFFERS NO CHANNEL TO ANSWER ON. The watch then offers
        /// no reply box at all, as the phone does.
        var canReply: Bool
    }
}

extension WatchSnapshot {
    /// What the phone sends when nobody is signed in: no workspace, no rows.
    static func signedOut(at date: Date, language: String?) -> WatchSnapshot {
        WatchSnapshot(
            protocolVersion: currentProtocolVersion,
            generatedAt: date,
            language: language,
            signedIn: false,
            workspace: nil,
            availability: nil,
            unreadCount: nil,
            calls: nil,
            conversations: nil
        )
    }

    /// True once the snapshot is old enough that the watch should say when it was taken.
    func isStale(at now: Date) -> Bool {
        now.timeIntervalSince(generatedAt) > Self.staleAfter
    }
}

// MARK: - The wire

/// What the watch made of an application context.
enum WatchSnapshotReading: Equatable, Sendable {
    case snapshot(WatchSnapshot)
    /// ⛔ A VERSION THIS BUILD DOES NOT SPEAK, IN EITHER DIRECTION. Never decoded further.
    case versionMismatch(Int)
    /// No snapshot in the dictionary, or bytes that are not one.
    case unreadable
}

extension WatchSnapshot {
    /// Encode for `updateApplicationContext`.
    func encoded() throws -> Data {
        try WatchWire.encoder.encode(self)
    }

    /// The application context dictionary that carries this snapshot.
    func context() throws -> [String: Any] {
        try [Self.contextKey: encoded()]
    }

    /// ⛔ THE LISTS SHRINK, THE STATE NEVER DOES. Sign-in, workspace, availability and
    /// unread count are what the watch exists to show; the oldest rows go first until the
    /// encoding fits ``maximumEncodedBytes``. nil when even an empty list does not fit,
    /// which only an absurd workspace name could cause.
    func fitted() -> WatchSnapshot? {
        var candidate = self
        while true {
            guard let data = try? candidate.encoded() else { return nil }
            if data.count <= Self.maximumEncodedBytes {
                return candidate
            }
            let calls = candidate.calls?.count ?? 0
            let conversations = candidate.conversations?.count ?? 0
            guard calls + conversations > 0 else { return nil }
            if calls >= conversations {
                candidate.calls?.removeLast()
            } else {
                candidate.conversations?.removeLast()
            }
        }
    }

    /// Read an application context.
    static func read(_ context: [String: Any]) -> WatchSnapshotReading {
        guard let data = context[contextKey] as? Data else { return .unreadable }
        return read(data: data)
    }

    /// ⛔ THE VERSION FIRST, FROM A PROBE THAT DECODES NOTHING ELSE. A newer phone may have
    /// changed any other field; decoding the whole value before checking would turn a
    /// version mismatch into an unreadable snapshot, which says nothing useful.
    static func read(data: Data) -> WatchSnapshotReading {
        guard let probe = try? WatchWire.decoder.decode(WatchWire.VersionProbe.self, from: data) else {
            return .unreadable
        }
        guard probe.protocolVersion == currentProtocolVersion else {
            return .versionMismatch(probe.protocolVersion)
        }
        guard let snapshot = try? WatchWire.decoder.decode(WatchSnapshot.self, from: data) else {
            return .unreadable
        }
        return .snapshot(snapshot)
    }
}

/// The one encoder and decoder both sides use, so a date is written and read one way.
enum WatchWire {
    struct VersionProbe: Decodable {
        let protocolVersion: Int
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
