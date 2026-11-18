import Foundation

extension ActiveRoomModel {
    /// Is this participant the note-taking Companion rather than a person?
    ///
    /// ⛔ THE SAME TWO TESTS THE WEB APPLIES, IN THE SAME ORDER, AND THE DUPLICATION
    /// IS THE POINT. Getting this wrong on one platform and not the other produces a
    /// blank muted tile that only phone users see. The KIND is the real test (the
    /// voice agent joins through the Agents framework with the agent kind); the
    /// prefix is a retired browser-side signalling participant that nothing mints any
    /// more, kept because a room built before the metadata cutover could still
    /// contain one.
    static func isCompanion(_ participant: RoomParticipantSnapshot) -> Bool {
        participant.isAgent || participant.identity.hasPrefix(retiredCompanionPrefix)
    }

    private static let retiredCompanionPrefix = "ai-companion-"
}
