/// Accessibility identifiers for the native Voice Studio.
///
/// ⚠️ THE STRINGS ARE ANDROID'S (`VoiceStudioHandles.kt`), so one UI walk can be written
/// against both clients: `district-voice-studio-<kind>-<id>`, with `-selected` on the tile
/// or block that is selected.
///
/// ⚠️ ONE LEVEL OF NESTING, for the reason `A11yID+SchedulingWrites.swift` records:
/// `.swiftlint.yml` warns at `nesting.type_level: 2` and `--strict` turns that into an error.
extension A11yID {
    enum VoiceStudio {
        static let root = "district-voice-studio-root"
        /// ⛔ A FORBIDDEN SURFACE FOR AN AUTOMATED RUN: it moves the engine every call runs on.
        static let save = "district-voice-studio-save"
        static let notice = "district-voice-studio-notice"
        static let dirty = "district-voice-studio-dirty"
        static let basedOn = "district-voice-studio-based-on"
        static let reset = "district-voice-studio-reset"
        static let meter = "district-voice-studio-meter"
        static let residency = "district-voice-studio-residency"

        static let tierKind = "tier"
        static let recipeKind = "recipe"
        static let blockKind = "block"
        static let pickerKind = "picker"
        static let advancedKind = "advanced"
        static let tuningKind = "tuning"
        static let sliderKind = "slider"
        static let defaultKind = "default"
        static let checkboxKind = "checkbox"
        static let keytermsKind = "keyterms"

        /// `district-voice-studio-<kind>-<id>`, with `-selected` when selected.
        static func handle(_ kind: String, _ id: String, selected: Bool = false) -> String {
            "district-voice-studio-\(kind)-\(id)" + (selected ? "-selected" : "")
        }
    }
}
