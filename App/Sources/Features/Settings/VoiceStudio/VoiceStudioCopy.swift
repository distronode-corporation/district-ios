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
    /// ⚠️ THE HUB ROW'S NAME, AND THE SAME WORD THE READ SENDS. The service's heading is
    /// "Voice" (`district-voice-studio.json`), as the web's District Studio page is called, so
    /// the title before the read lands and the one after it agree. If they ever differ again,
    /// the title changes word mid-load.
    static var title: String {
        SettingsCopy.voiceStudioTitle
    }

    /// A tuning value: two decimals, or none for a whole-number control.
    static func tuningValue(_ value: Double, whole: Bool) -> String {
        whole
            ? value.formatted(.number.precision(.fractionLength(0)))
            : value.formatted(.number.precision(.fractionLength(2)))
    }
}
