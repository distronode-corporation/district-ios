import DistrictData
import DistrictModel
import Foundation
import Observation

/// One choice in an HQ voice settings menu: the wire value and what the member reads.
struct HQVoiceOption: Identifiable, Equatable {
    let value: String
    let label: String

    var id: String {
        value
    }
}

/// The member's own HQ voice settings in one workspace (`GET` and `PUT hq/voice-settings`).
///
/// ⚠️ THE WIRE VALUES ARE THE SERVICE'S (`lib/district/hq-voice-settings.ts`). A value this
/// build does not list is kept and shown as itself, so a save never rewrites a newer choice.
@MainActor
@Observable
final class HQVoiceSettingsModel: Identifiable {
    private(set) var draft: HQVoiceSettings?
    private(set) var loadFailure: FailureText?
    private(set) var saveFailure: FailureText?
    private(set) var isSaving = false
    private(set) var isSaved = false
    private var loaded: HQVoiceSettings?

    private let hq: HQRepository
    private let workspaceId: String

    init(hq: HQRepository, workspaceId: String) {
        self.hq = hq
        self.workspaceId = workspaceId
    }

    var isDirty: Bool {
        draft != nil && draft != loaded
    }

    func load() async {
        loadFailure = nil
        switch await hq.voiceSettings(workspaceId: workspaceId) {
        case let .success(settings):
            loaded = settings
            draft = settings
        case let .failure(error):
            loadFailure = FailureText.from(error)
        }
    }

    func edit(_ change: (inout Field) -> Void) {
        guard let current = draft else { return }
        var field = Field(current)
        change(&field)
        draft = field.settings
        isSaved = false
        saveFailure = nil
    }

    /// ⛔ SINGLE-FLIGHT: a second tap while a save is in flight does nothing.
    func save() async {
        guard let settings = draft, !isSaving else { return }
        isSaving = true
        saveFailure = nil
        let result = await hq.saveVoiceSettings(workspaceId: workspaceId, settings: settings)
        isSaving = false
        switch result {
        case let .success(saved):
            loaded = saved
            if draft == settings {
                draft = saved
            }
            isSaved = true
        case let .failure(error):
            saveFailure = FailureText.from(error)
        }
    }

    /// The five settings as one value to edit. `HQVoiceSettings` is immutable.
    struct Field {
        var voice: String
        var length: String
        var pace: String
        var language: String
        var micMode: String

        init(_ settings: HQVoiceSettings) {
            voice = settings.voice
            length = settings.length
            pace = settings.pace
            language = settings.language
            micMode = settings.micMode
        }

        var settings: HQVoiceSettings {
            HQVoiceSettings(voice: voice, length: length, pace: pace, language: language, micMode: micMode)
        }
    }
}

/// The menus' choices, the service's values in its order.
enum HQVoiceOptions {
    /// ⚠️ Gemini's voice names, the same in both languages.
    static let voices = ["Puck", "Charon", "Kore", "Fenrir", "Aoede"].map { HQVoiceOption(value: $0, label: $0) }

    static var lengths: [HQVoiceOption] {
        [
            HQVoiceOption(value: "brief", label: HQCopy.voiceLengthBrief),
            HQVoiceOption(value: "normal", label: HQCopy.voiceLengthNormal),
            HQVoiceOption(value: "detailed", label: HQCopy.voiceLengthDetailed),
        ]
    }

    static var paces: [HQVoiceOption] {
        [
            HQVoiceOption(value: "slower", label: HQCopy.voicePaceSlower),
            HQVoiceOption(value: "normal", label: HQCopy.voicePaceNormal),
            HQVoiceOption(value: "faster", label: HQCopy.voicePaceFaster),
        ]
    }

    static var languages: [HQVoiceOption] {
        [
            HQVoiceOption(value: "portal", label: HQCopy.voiceLanguagePortal),
            HQVoiceOption(value: "en", label: HQCopy.voiceLanguageEn),
            HQVoiceOption(value: "fr", label: HQCopy.voiceLanguageFr),
        ]
    }

    static var micModes: [HQVoiceOption] {
        [
            HQVoiceOption(value: "open", label: HQCopy.voiceMicOpen),
            HQVoiceOption(value: "push", label: HQCopy.voiceMicPush),
        ]
    }

    /// The list, with a value this build does not know added as itself.
    static func including(_ value: String, in options: [HQVoiceOption]) -> [HQVoiceOption] {
        options.contains { $0.value == value } ? options : options + [HQVoiceOption(value: value, label: value)]
    }
}
