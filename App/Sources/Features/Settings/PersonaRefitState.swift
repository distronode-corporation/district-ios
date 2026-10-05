import DistrictData
import Foundation

/// Fitting a chain of the member's own to a new persona language, after the save that changed
/// it. The flow is `VoiceStudioRefit` in district-core-swift; this is what the persona screen
/// says about it, in the same words district-linux uses.
///
/// ⛔ WHY. The persona screen saves a new language with the stored chain left as it was, and a
/// chain whose ear or voice does not speak the new language is one the service no longer
/// accepts. The Studio's read for the new language says so (`current.engineMix` null); the
/// chain is then moved to the nearest offered models that speak it, saved, and read again.
enum PersonaRefitState: Equatable {
    /// Reading, saving and reading again.
    case running
    /// What it did.
    case finished(VoiceStudioRefitOutcome)

    static let runningLine = "Checking that the voice chain speaks the new language."
    static let refittedLine = "The voice chain was moved to models that speak the new language. "
        + "The Voice screen shows it."
    static let noFitLine = "No model this workspace may use speaks the new language for every part "
        + "of the voice chain. Choose them on the Voice screen."
    static let failedLine = "The voice chain could not be moved to the new language. "
        + "Fit it on the Voice screen."
    static let notSeenLine = "The voice chain was saved, but the Voice screen does not show it fitting "
        + "the new language. Check it there."

    var isRunning: Bool {
        self == .running
    }

    /// What to say; nil when there is nothing to say (the chain still fits).
    ///
    /// ⚠️ `@MainActor` because a refusal is said the way the Studio screen says it
    /// (``VoiceStudioModel/failure(_:)``), which is main-actor isolated.
    @MainActor
    var line: String? {
        switch self {
        case .running:
            Self.runningLine
        case .finished(.fits):
            nil
        case .finished(.refitted):
            Self.refittedLine
        case .finished(.noFit):
            Self.noFitLine
        case let .finished(.failed(refusal)):
            "\(Self.failedLine) \(VoiceStudioModel.failure(refusal).message)"
        case .finished(.notSeen):
            Self.notSeenLine
        }
    }
}
