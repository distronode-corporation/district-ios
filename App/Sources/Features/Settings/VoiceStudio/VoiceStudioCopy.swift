import Foundation

/// The Voice Studio's own chrome, in English, as the app's copy is by decision.
///
/// ⛔ ONLY CHROME. Every Studio label (headings, recipe names, leg names, channels, residency
/// and latency sentences, the save and saved lines) arrives from the server in the reader's
/// PORTAL language and is rendered verbatim (Sean, 2026-10-03: "Follow the portal language").
/// What is here is the title before the read lands, the tuning chrome and the two refusals'
/// fallbacks. ⛔ The "Based on" line and an unsaved edit's meter are NOT here: they are filled
/// from the read's own templates (`VoiceStudioText`), so they follow the portal language too.
enum VoiceStudioCopy {
    /// ⚠️ NOT THE HUB ROW'S NAME. The row says "Voice", as the web's District Studio page
    /// does, but the heading the read sends is still "Voice Studio" (the wire key stays until
    /// the apps read a new one), and a title that changed word the moment the read landed
    /// would read as a glitch. This moves with the wire heading.
    static let title = "Voice Studio"

    static let saving = "Saving…"

    /// A tuning value: two decimals, or none for a whole-number control.
    static func tuningValue(_ value: Double, whole: Bool) -> String {
        whole
            ? value.formatted(.number.precision(.fractionLength(0)))
            : value.formatted(.number.precision(.fractionLength(2)))
    }

    static let useDefault = "Use the default"
    static let selected = "Selected"
    static let advancedShow = "Show"
    static let advancedHide = "Hide"

    /// ⚠️ THE TWO REFUSALS' FALLBACKS, for a refusal that carried no sentence of its own. The
    /// server's own sentence is preferred: it is the one the web shows.
    static let invalidEngineMix = "That voice chain cannot be saved: a model, voice or location in it "
        + "is not available for this workspace and language."
    static let modelUnavailableInRegion = "That model is not available for workspaces in this region."
}
