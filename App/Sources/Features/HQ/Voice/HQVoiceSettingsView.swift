import DistrictModel
import SwiftUI

/// The member's HQ voice settings: the voice, the answer length, the pace, the language and
/// how the microphone behaves. Opened from the HQ screen's voice bar.
///
/// ⚠️ THE MEMBER'S OWN, NOT THE WORKSPACE'S, so a viewer may change them too.
struct HQVoiceSettingsView: View {
    @State private var model: HQVoiceSettingsModel

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    init(model: HQVoiceSettingsModel) {
        _model = State(initialValue: model)
    }

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DistrictSpacing.section) {
                if let draft = model.draft {
                    SettingsCard {
                        menus(draft)
                    }
                    footer
                } else if let failure = model.loadFailure {
                    failureText(failure.message)
                    if case .retry = failure.action {
                        Button(HQCopy.retry) { Task { await model.load() } }
                            .buttonStyle(.districtSecondary)
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(DistrictSpacing.gutter)
            .districtReadableWidth()
        }
        .background(colors.background)
        .navigationTitle(HQCopy.voiceSettings)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
    }

    @ViewBuilder
    private func menus(_ draft: HQVoiceSettings) -> some View {
        menu(HQCopy.voiceSettingVoice, draft.voice, HQVoiceOptions.voices, A11yID.HQVoice.settingsVoice) {
            $0.voice = $1
        }
        menu(HQCopy.voiceSettingLength, draft.length, HQVoiceOptions.lengths, A11yID.HQVoice.settingsLength) {
            $0.length = $1
        }
        menu(HQCopy.voiceSettingPace, draft.pace, HQVoiceOptions.paces, A11yID.HQVoice.settingsPace) {
            $0.pace = $1
        }
        menu(
            HQCopy.voiceSettingLanguage,
            draft.language,
            HQVoiceOptions.languages,
            A11yID.HQVoice.settingsLanguage
        ) { $0.language = $1 }
        menu(HQCopy.voiceSettingMic, draft.micMode, HQVoiceOptions.micModes, A11yID.HQVoice.settingsMic) {
            $0.micMode = $1
        }
    }

    private func menu(
        _ title: String,
        _ value: String,
        _ options: [HQVoiceOption],
        _ identifier: String,
        _ write: @escaping (inout HQVoiceSettingsModel.Field, String) -> Void
    ) -> some View {
        // ⚠️ THE TITLE ABOVE ITS MENU, NOT BESIDE IT: side by side, the French values wrapped.
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(DistrictType.labelSmall)
                .foregroundStyle(colors.mutedForeground)
            Picker(title, selection: Binding(
                get: { value },
                set: { picked in model.edit { write(&$0, picked) } }
            )) {
                ForEach(HQVoiceOptions.including(value, in: options)) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .disabled(model.isSaving)
            .accessibilityIdentifier(identifier)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.tight) {
            Button(HQCopy.voiceSettingsSave) { Task { await model.save() } }
                .buttonStyle(.districtPrimary)
                .disabled(!model.isDirty || model.isSaving)
                .accessibilityIdentifier(A11yID.HQVoice.settingsSave)
            if model.isSaved {
                Text(HQCopy.voiceSettingsSaved)
                    .font(DistrictType.caption)
                    .foregroundStyle(colors.mutedForeground)
            }
            if let failure = model.saveFailure {
                failureText(failure.message)
            }
        }
    }

    private func failureText(_ message: String) -> some View {
        Text(message)
            .font(DistrictType.caption)
            .foregroundStyle(colors.destructive)
            .fixedSize(horizontal: false, vertical: true)
    }
}
