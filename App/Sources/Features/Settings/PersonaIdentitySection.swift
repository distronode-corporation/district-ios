import DistrictModel
import SwiftUI

/// The persona's language and answer length, whose values come from the server's own
/// catalogue, and a pointer to where the voice now lives.
///
/// ⛔ THE ENGINE, VOICE AND TUNING ARE NOT HERE, AND THE NOTE SAYS WHERE THEY WENT. They are
/// the Voice Studio's (its own row in workspace settings); without the note this form would
/// read as a persona with no voice at all.
///
/// ⛔ THERE IS NO BRANCH THAT INVENTS A LIST. Either ``PersonaModel/draft`` exists, built from
/// this workspace's own catalogue, or the panel shows what is STORED and says why it cannot
/// be changed. A hardcoded fallback would not fail when it drifted: every value it offered
/// would still be accepted, stored, and then quietly replaced by the agent.
struct PersonaIdentitySection: View {
    let model: PersonaModel

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    /// ⚠️ ONE PREDICATE FOR EVERY CONTROL, so a save in flight cannot be edited under.
    private var enabled: Bool {
        model.canWrite && !model.save.isSaving
    }

    var body: some View {
        SettingsCard(eyebrow: SettingsCopy.personaLanguageEyebrow) {
            if let draft = model.draft {
                pickers(draft)
            } else {
                unavailable
            }
            note(SettingsCopy.personaVoiceStudioNote)
        }
    }

    // MARK: - The editable panel

    @ViewBuilder
    private func pickers(_ draft: PersonaIdentityDraft) -> some View {
        note(SettingsCopy.personaReadOnlyNote)
        menu(
            label: SettingsCopy.personaLanguageLabel,
            options: draft.languages,
            selection: Binding(
                get: { draft.values.language },
                set: { value in model.editIdentity { $0.selectLanguage(value) } }
            ),
            identifier: A11yID.Persona.language
        )
        if draft.values.language.isEmpty {
            note(SettingsCopy.personaLanguageUnset)
        }
        // ⚠️ HIDDEN RATHER THAN EMPTY FOR AN ENGINE THE CATALOGUE CARRIES NO LEVELS FOR.
        if !draft.responseLengths.isEmpty {
            menu(
                label: SettingsCopy.personaAnswerLengthLabel,
                options: draft.responseLengths,
                selection: Binding(
                    get: { draft.values.responseLength },
                    set: { value in model.editIdentity { $0.selectResponseLength(value) } }
                ),
                identifier: A11yID.Persona.answerLength
            )
            note(SettingsCopy.personaAnswerLengthNote)
        }
    }

    // MARK: - The panel when the catalogue did not load

    /// ⛔ THE STORED VALUES, SHOWN AS THEY ARE, WITH A RETRY THAT READS THE CATALOGUE ALONE.
    /// It does not re-read the configuration, so it cannot discard what the operator has
    /// typed into the three text fields above.
    @ViewBuilder
    private var unavailable: some View {
        DistrictEyebrow(text: SettingsCopy.personaOptionsFailedEyebrow)
        note(SettingsCopy.personaOptionsFailedNote)
        SettingsReadOnlyRow(label: SettingsCopy.personaLanguageLabel, value: model.persona?.language)
        if let failure = model.optionsFailure {
            Text(failure.message)
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
            retry(failure)
        }
    }

    /// ⚠️ OFFERED ONLY WHERE ``FailureText/Action/retry`` SAYS SO.
    @ViewBuilder
    private func retry(_ failure: FailureText) -> some View {
        if case .retry = failure.action {
            Button(SettingsCopy.retry) { Task { await model.loadOptions() } }
                .buttonStyle(.districtSecondary)
                .accessibilityIdentifier(A11yID.Persona.engineRetry)
        }
    }

    // MARK: - Shared chrome

    /// One labelled menu over a `value`/`label` list.
    ///
    /// ⚠️ IT CARRIES AN "UNSET" ROW WHILE NOTHING IS SELECTED. A SwiftUI `Picker` whose
    /// selection matches no tag renders blank and silently adopts the first tag on the next
    /// interaction, which on this form would be a value nobody chose.
    private func menu(
        label title: String,
        options: [PersonaLabelledValue],
        selection: Binding<String>,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            Text(title)
                .font(DistrictType.labelSmall)
                .foregroundStyle(colors.mutedForeground)
            Picker(title, selection: selection) {
                if selection.wrappedValue.isEmpty {
                    Text(SettingsCopy.personaUnset).tag("")
                }
                ForEach(options) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .pickerStyle(.menu)
            .disabled(!enabled)
            .accessibilityIdentifier(identifier)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(DistrictType.caption)
            .foregroundStyle(colors.mutedForeground)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
