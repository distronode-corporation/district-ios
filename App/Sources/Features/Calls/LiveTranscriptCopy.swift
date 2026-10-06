import DistrictLive
import DistrictModel

/// The live transcript's words, in one place.
///
/// ⚠️ ENGLISH ONLY, like the rest of this app. The wire never carries a label: the speaker is
/// a role (`caller`, `agent`), and the persona's name is the only name it sends.
enum LiveTranscriptCopy {
    static let heading = "Live transcript"
    static let connecting = "Connecting…"
    static let live = "Live"
    static let ended = "Call ended"
    /// After `agent_error`: the call may be handed to a fresh assistant, so it is not over.
    static let reconnecting = "Reconnecting…"
    static let waiting = "Nothing has been said yet."

    /// ⛔ D3: THE SERVER'S MEMORY DID NOT REACH BACK TO THE CALL'S FIRST LINE (it restarted, or
    /// the call is long). Saying so is what keeps a partial transcript from reading as the
    /// whole call.
    static let incomplete = "Earlier lines will appear in the full transcript after the call."

    static let loadingFull = "Loading the full transcript…"
    static let noTranscript = "No transcript for this call."
    static let fullTranscript = "Transcript"

    /// Under an assistant line that was cut off: what it said is what was actually played.
    static let interrupted = "Interrupted"

    /// The speaker's label. ⚠️ An assistant line names its persona when the server sends
    /// one; a speaker this app does not know yet (a colleague who joined, say) is a third
    /// party rather than a guess.
    static func speaker(_ segment: TranscriptSegment) -> String {
        switch segment.speaker {
        case .caller: "Caller"
        case .agent: segment.speakerName.flatMap { $0.isEmpty ? nil : $0 } ?? "Assistant"
        case .other: "Other speaker"
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
