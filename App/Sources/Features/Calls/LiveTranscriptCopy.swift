import DistrictLive
import DistrictModel

/// The live transcript's words, in one place.
///
/// ⚠️ ENGLISH ONLY, like the rest of this app. The wire never carries a label: the speaker is
/// a role (`caller`, `agent`), and the persona's name is the only name it sends.
enum LiveTranscriptCopy {
    /// The speaker's label. ⚠️ An assistant line names its persona when the server sends
    /// one; a speaker this app does not know yet (a colleague who joined, say) is a third
    /// party rather than a guess.
    static func speaker(_ segment: TranscriptSegment) -> String {
        switch segment.speaker {
        case .caller: speakerCaller
        case .agent: segment.speakerName.flatMap { $0.isEmpty ? nil : $0 } ?? speakerAssistant
        case .other: speakerOther
        }
    }

    /// The line under the heading.
    static func status(phase: LiveTranscriptPhase, connection: LiveTranscriptModel.Connection) -> String {
        if case .ended = phase {
            return ended
        }
        if phase == .reconnecting {
            return reconnecting
        }
        return connection == .open && phase == .live ? live : connecting
    }
}
