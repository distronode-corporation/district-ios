/// Live calls and one call's supervision.
///
/// ⚠️ iOS-FIRST: the Android client has no Live screen yet, so there is no tag to copy.
/// ⛔ `listen`, `takeOver` AND `whisperSend` ARE FORBIDDEN SURFACES AGAINST A REAL WORKSPACE:
/// each one reaches a customer's call in progress.
extension A11yID {
    enum Live {
        static let root = "district-live-root"
        static let empty = "district-live-empty"
        static let rowBase = "district-live-row"
        static func row(_ id: String) -> String {
            A11yID.row(rowBase, id)
        }

        static let supervise = "district-live-supervise"
        static let callCard = "district-live-call-card"
        static let problem = "district-live-problem"
        static let listen = "district-live-listen"
        static let stop = "district-live-stop"
        static let takeOver = "district-live-take-over"
        static let handBack = "district-live-hand-back"
        static let mute = "district-live-mute"
        static let whisper = "district-live-whisper"
        static let whisperField = "district-live-whisper-field"
        static let whisperSend = "district-live-whisper-send"
        static let receipt = "district-live-receipt"
        static let noReceptionist = "district-live-no-receptionist"
    }
}
