import Foundation

/// The Voice Studio's own chrome, in English, as the app's copy is by decision.
///
/// ⛔ ONLY CHROME. Every Studio label (headings, recipe names, leg names, channels, residency
/// and latency sentences, the save and saved lines) arrives from the server in the reader's
/// PORTAL language and is rendered verbatim (Sean, 2026-10-03: "Follow the portal language").
/// What is here is the title before the read lands, the change count, the words around a
/// meter the server has not described yet, and the two refusals' fallbacks, the same set
/// Android keeps in `strings.xml`.
enum VoiceStudioCopy {
    static let title = SettingsCopy.voiceStudioTitle

    static let saving = "Saving…"

    /// "Based on Fastest, 2 changes". ⚠️ Nothing when the held engine IS the recipe.
    static func basedOn(_ name: String, changes: Int) -> String {
        changes == 1 ? "Based on \(name), 1 change" : "Based on \(name), \(changes) changes"
    }

    /// ⛔ "ABOUT" ONLY WHEN EVERY STAGE IS MEASURED. The numbers are measured medians the server
    /// sent; nothing here estimates one.
    static func meterAbout(_ ms: Double) -> String {
        "About \(milliseconds(ms))"
    }

    /// ⛔ "AT LEAST", NEVER "ABOUT", WHEN A STAGE IS UNMEASURED: the missing stage is not
    /// estimated, so the real time is longer than the sum shown.
    static func meterAtLeast(_ ms: Double) -> String {
        "At least \(milliseconds(ms))"
    }

    /// A whole number of milliseconds, grouped for the device's locale.
    static func milliseconds(_ ms: Double) -> String {
        "\(Int(ms.rounded()).formatted()) ms"
    }

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
