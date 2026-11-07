/// District HQ by voice: the voice bar, the region notice, a proposal card and the settings.
///
/// ⚠️ iOS-FIRST: no other client has these tags yet. ⛔ `start` and `noticeStart` open a billed
/// session against a real workspace.
extension A11yID {
    enum HQVoice {
        static let bar = "district-hq-voice-bar"
        static let start = "district-hq-voice-start"
        static let state = "district-hq-voice-state"
        static let stop = "district-hq-voice-stop"
        static let mute = "district-hq-voice-mute"
        static let holdToTalk = "district-hq-voice-hold"
        static let transcript = "district-hq-voice-transcript"
        static let ended = "district-hq-voice-ended"
        static let notice = "district-hq-voice-notice"
        static let noticeStart = "district-hq-voice-notice-start"
        static let noticeCancel = "district-hq-voice-notice-cancel"
        static let proposalBase = "district-hq-voice-proposal"
        static func proposal(_ id: String) -> String {
            A11yID.row(proposalBase, id)
        }

        static let confirmBase = "district-hq-voice-confirm"
        static func confirm(_ id: String) -> String {
            A11yID.row(confirmBase, id)
        }

        static let cancelBase = "district-hq-voice-cancel"
        static func cancel(_ id: String) -> String {
            A11yID.row(cancelBase, id)
        }

        static let settings = "district-hq-voice-settings"
        static let settingsVoice = "district-hq-voice-settings-voice"
        static let settingsLength = "district-hq-voice-settings-length"
        static let settingsPace = "district-hq-voice-settings-pace"
        static let settingsLanguage = "district-hq-voice-settings-language"
        static let settingsMic = "district-hq-voice-settings-mic"
        static let settingsSave = "district-hq-voice-settings-save"
    }
}
