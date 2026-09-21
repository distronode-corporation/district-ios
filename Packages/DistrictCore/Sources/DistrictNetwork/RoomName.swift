import Foundation

/// The name of a multi-party meeting room, proven to be one.
///
/// ⛔ THE APP MUST NEVER CONSTRUCT A `video_` ROOM NAME, AND THIS TYPE IS WHY IT
/// CANNOT. `video_` is one character from `meet_` in the same `startsWith` chain
/// on the server, and it silently starts a **billable Tavus avatar** — default
/// concurrency ceiling 1, never exercised in production, so the first time it
/// happens it is both a charge and an outage of the avatar feature for every
/// other room. A comment asking nobody to type it is not a control;
/// ``init(_:)`` failing is.
///
/// ⛔ THE ALLOWLIST IS `meet_` AND NOTHING ELSE, WHICH ALSO CLOSES THE
/// SUPERVISOR CASE. `POST /api/district/calls/token` serves two structurally
/// opposite things behind one body: a `meet_`/`video_` prefix means a standalone
/// ROOM (the route stamps `participant`), anything else is read as a `Call.id`
/// and the caller is stamped `supervisor` — whereupon the voice agent
/// unsubscribes their microphone. Only the room case is reachable from this
/// client, and an id-shaped string is refused here rather than answered with a
/// token that silently mutes the operator.
///
/// ⚠️ A ROOM NAME IS NOT AN AUTHORIZATION CLAIM AND MUST NOT BE TREATED AS ONE.
/// The server parses the workspace id back out of it and runs
/// `requireWorkspaceRole` against THAT, so naming another tenant's room answers
/// 403 rather than granting anything. It is also not a secret — suffixes are
/// human-typed and low entropy, which is exactly why an unauthenticated guest
/// needs a signed invite instead of a name.
public struct RoomName: Sendable, Equatable {
    /// The wire value, exactly as the server will read it.
    public let value: String

    /// ⛔ THE ONLY PREFIX THIS CLIENT MAY MINT. See the type note.
    public static let meetingPrefix = "meet_"

    /// ⛔ NAMED SO THE REFUSAL CAN BE ASSERTED. `RoomNameTests` builds this
    /// string and requires ``init(_:)`` to answer nil for it, which is a test
    /// that the guard EXISTS rather than a test of a comment.
    public static let billableAvatarPrefix = "video_"

    /// - Returns: nil for anything that is not a `meet_` room — a `video_`
    ///   avatar room, a bare `Call.id`, an empty suffix, or a name carrying a
    ///   path separator.
    public init?(_ value: String) {
        guard value.hasPrefix(RoomName.meetingPrefix) else { return nil }
        guard value.count > RoomName.meetingPrefix.count else { return nil }
        // ⚠️ The server restricts room suffixes to `[a-zA-Z0-9-]`. Mirrored here
        // rather than trusted to the round trip, because the value also reaches
        // a LiveKit room join where a separator would be a different room.
        let suffix = value.dropFirst(RoomName.meetingPrefix.count)
        guard suffix.allSatisfy(RoomName.isAllowedSuffixCharacter) else { return nil }
        self.value = value
    }

    /// Mint the name for a workspace and a human-typed suffix.
    ///
    /// ⛔ THE ONE PLACE THIS CLIENT BUILDS A ROOM NAME, AND IT WRITES THE PREFIX
    /// ITSELF RATHER THAN ACCEPTING ONE. That is the whole `video_` guard restated
    /// for the minting direction: ``init(_:)`` can only REFUSE a bad name somebody
    /// already assembled, and a `"\(prefix)\(id)_\(name)"` at a call site is one
    /// character from a billable Tavus avatar with nothing to review. The Kotlin
    /// client centralises it the same way, in `MeetRoomName.of`.
    ///
    /// ⛔ AND THE RESULT DELIBERATELY DOES NOT SATISFY ``init(_:)``. A real name is
    /// `meet_<workspaceId>_<suffix>` and therefore carries a SECOND underscore,
    /// which that initialiser refuses on purpose (`RoomNameTests` pins
    /// `meet_a_b` as nil, mirroring the web lobby's stricter suffix rule). The two
    /// are different questions: that one asks "is this a name I would have typed",
    /// this one asks "what name does this workspace and this suffix make". Routing
    /// this through it would make every joinable room unmintable.
    ///
    /// - Returns: nil when `suffix` normalises to nothing, or when `workspaceId` is
    ///   blank or carries a character the server's own
    ///   `^(meet|video)_([a-zA-Z0-9-]+)_(.+)$` would not match in its FIRST group.
    ///   ⛔ nil rather than a name with an empty tail: `meet_<ws>_` fails that regex
    ///   and comes back as a 400 "Invalid meeting room format", which reads as a
    ///   server fault for what is really an empty field.
    public init?(workspaceId: String, suffix: String) {
        let tail = RoomName.normalizeSuffix(suffix)
        guard !tail.isEmpty else { return nil }
        let head = workspaceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !head.isEmpty else { return nil }
        guard head.allSatisfy(RoomName.isAllowedSuffixCharacter) else { return nil }
        value = RoomName.meetingPrefix + head + "_" + tail
    }

    /// Accept a room name the SERVER wrote, so an in-progress meeting can be rejoined.
    ///
    /// ⛔ A SECOND ENTRY POINT RATHER THAN A LOOSENING OF ``init(_:)``, AND THE
    /// DIFFERENCE IS UNDERSCORES. The server's regex ends in `.+`, so a stored
    /// `Meeting.roomName` legitimately contains the workspace separator and may
    /// contain more; ``init(_:)`` mirrors the WEB LOBBY's stricter minting rule and
    /// must keep refusing those, because it is what stops a hand-assembled name.
    /// ``MeetingsRepository`` records the same distinction from the reading side.
    ///
    /// ⛔ THE `video_` GUARD IS UNCHANGED AND IS THE ONLY THING THAT MATTERS HERE.
    /// The prefix test is what refuses a billable avatar room and a bare `Call.id`
    /// (which would be answered with a `supervisor` token); what is relaxed is only
    /// the character set of the tail, and a separator is still refused because the
    /// value reaches a LiveKit room join where one would be a different room.
    ///
    /// - Returns: nil for anything that is not a `meet_` room, an empty tail, or a
    ///   tail carrying a path separator or whitespace.
    public init?(joining value: String) {
        guard value.hasPrefix(RoomName.meetingPrefix) else { return nil }
        let tail = value.dropFirst(RoomName.meetingPrefix.count)
        guard !tail.isEmpty else { return nil }
        guard tail.allSatisfy(RoomName.isJoinableCharacter) else { return nil }
        self.value = value
    }

    /// Lower-case, hyphen-separated, and stripped of everything else.
    ///
    /// ⚠️ EXPOSED SO A LOBBY CAN SHOW SOMEBODY WHAT THEIR INPUT WILL BECOME BEFORE
    /// THEY JOIN. A field that silently rewrote "Weekly Review" at submit time would
    /// leave two people unable to explain why they are in different rooms, and a
    /// field that rewrote itself as they typed would move the cursor and eat spaces.
    /// Holding the raw text and this value separately is what lets a screen do
    /// neither.
    public static func normalizeSuffix(_ suffix: String) -> String {
        let spaced = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")
        let kept = String(spaced.filter(RoomName.isAllowedSuffixCharacter))
        return kept.trimmingCharacters(in: RoomName.hyphens).lowercased()
    }

    /// The human half of a room name, for display.
    ///
    /// ⚠️ SPLITS FROM THE LEFT ON EXACTLY TWO SEPARATORS, because the tail may
    /// legitimately contain further underscores when the name came from somewhere
    /// other than ``init(workspaceId:suffix:)`` — the server accepts `.+` there.
    /// ⚠️ RETURNS THE WHOLE NAME UNCHANGED when it does not have the shape, so a
    /// display never silently blanks; `meet_<uuid>_standup` is not a title, and
    /// neither is an empty line.
    public static func displayName(_ roomName: String) -> String {
        let parts = roomName.split(separator: "_", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return roomName }
        guard parts[0] == "meet", !parts[2].isEmpty else { return roomName }
        return String(parts[2])
    }

    private static let hyphens = CharacterSet(charactersIn: "-")

    private static func isAllowedSuffixCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || character == "-")
    }

    /// ⚠️ THE MINTING SET PLUS THE SEPARATOR THE SERVER ITSELF WRITES. See
    /// ``init(joining:)``.
    private static func isJoinableCharacter(_ character: Character) -> Bool {
        RoomName.isAllowedSuffixCharacter(character) || character == "_"
    }
}

/// The `identity` this client sends with a room token request.
///
/// ⛔ A CONSTANT, DELIBERATELY. The route REQUIRES the key (a missing value is a
/// 400) and IGNORES the value: it derives a hashed participant identity from the
/// SESSION, because accepting a client-supplied identity was an impersonation
/// hole, and a random one per join produced duplicate tiles — LiveKit evicts only
/// on a REPEATED identity. Sending a device id or an email would put a value on
/// the wire that is neither used nor needed.
public enum RoomIdentity {
    public static let value = "ios"
}
