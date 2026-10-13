import Foundation

/// The persona form's language and answer length, the persona preview, and the
/// routing-rule editor. (The engine, voice and tuning are the Voice Studio's; see
/// ``VoiceStudioCopy``.)
///
/// ⚠️ A THIRD FILE FOR THE SAME NAMESPACE, WHICH IS A LINT CEILING RATHER THAN A
/// SPLIT WITH MEANING — `swiftlint --strict` promotes `file_length` at 500 lines to an
/// error, and `SettingsCopy.swift` is already the whole of the rest of this surface.
/// What is here is the copy for editing the persona and its rules.
///
/// ⛔ NO SENTENCE ON THIS SURFACE MAY SAY THE PHONE CANNOT DO THIS. "chosen from lists
/// this app cannot see", "They cannot be edited in this app" and "Rules cannot be added
/// in this app" would each be false; a stale refusal is worse than no sentence, because
/// an operator believes it and goes looking for a browser.
extension SettingsCopy {
    // MARK: - The preview

    /// ⚠️ SPOKEN AS A LEVEL RATHER THAN DRAWN AS ONE. A bar with no label is invisible
    /// to VoiceOver, and "is the agent actually saying anything" is the question this
    /// screen exists to answer.
    static func previewLevelValue(_ level: Double) -> String {
        previewLevelPercent(Int((level * 100).rounded()))
    }
}
