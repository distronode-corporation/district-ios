import DistrictModel
import SwiftUI

/// The seven persona controls whose values come from the server's own catalogue.
///
/// ⛔ ITS OWN FILE BECAUSE `swiftlint --strict` PROMOTES `file_length` AT 500 LINES TO
/// AN ERROR, the same split ``RoomsCopy`` and ``SettingsCopy+Sections`` are. Nothing
/// here is a separate concern from ``PersonaView``; it is the half of that screen that
/// cannot be drawn without ``PersonaOptionsResponse``.
///
/// ⛔ THERE IS NO BRANCH THAT INVENTS A LIST. Either ``PersonaModel/draft`` exists —
/// built from this workspace's own catalogue — or the panel shows what is STORED and
/// says why it cannot be changed. A hardcoded fallback would not fail when it drifted:
/// every value it offered would still be accepted, stored, and then quietly replaced
/// by the agent at synthesis time, with a 200 and nothing anywhere reporting it.
///
/// ⛔ AND THE ENGINE PICKER IS A LIST OF ROWS RATHER THAN A MENU, WHICH IS A CONTENT
/// DECISION AND NOT A STYLISTIC ONE. Each option's label carries where its audio is
/// processed ("Deepgram Pipeline — US (processed in your region)"); a menu shows one
/// label at a time and hides the rest behind a tap, which is exactly the information an
/// operator is choosing between. The out-of-region ones are rendered DISABLED with
/// their labels rather than hidden, so a shorter list than a colleague's has a visible
/// reason.
struct PersonaEngineSection: View {
    let model: PersonaModel

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    /// ⚠️ ONE PREDICATE FOR EVERY CONTROL, so a save in flight cannot be edited under
    /// and a viewer that somehow reached the screen cannot move a picker that would
    /// 403.
    private var enabled: Bool {
        model.canWrite && !model.save.isSaving
    }

    var body: some View {
        SettingsCard(eyebrow: SettingsCopy.personaEngineEyebrow) {
            if let draft = model.draft {
                pickers(draft)
            } else {
                unavailable
            }
        }
    }

    // MARK: - The editable panel

    @ViewBuilder
    private func pickers(_ draft: PersonaEngineDraft) -> some View {
        note(SettingsCopy.personaReadOnlyNote)
        engineRows(draft)
        answerLength(draft)
        preemptive(draft)
        language(draft)
        voice(draft)
        voiceStyle(draft)
        temperature(draft)
    }

    /// ⛔ EVERY ENGINE IS DRAWN AND ONLY THE IN-REGION ONES ARE SELECTABLE. See the ⛔
    /// on this type.
    private func engineRows(_ draft: PersonaEngineDraft) -> some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            label(SettingsCopy.personaEngineLabel)
            ForEach(draft.engines, id: \.id) { engine in
                engineRow(engine, selected: engine.id == draft.values.modelId)
            }
            note(SettingsCopy.personaEngineNote)
            note(SettingsCopy.personaEngineOutOfRegion)
        }
        .accessibilityIdentifier(A11yID.Persona.engine)
    }

    /// ⚠️ THE STYLE IS CONSTRUCTED RATHER THAN PICKED WITH A TERNARY OF TWO
    /// IMPLICIT-MEMBER EXPRESSIONS, the trap ``DirectoryView/typeButton(_:title:value:)``
    /// records: `.buttonStyle` is generic over its argument, so two leading dots ask the
    /// type checker to infer a style from nothing.
    private func engineRow(_ engine: PersonaEngineOption, selected: Bool) -> some View {
        Button(engine.label) { select(engine.id) }
            .buttonStyle(DistrictButtonStyle(variant: selected ? .primary : .secondary))
            .disabled(!enabled || !engine.inRegion)
            // ⚠️ THE SELECTION IS ANNOUNCED RATHER THAN SHOWN BY FILL ALONE. A filled
            // button and an unfilled one are the same sentence to VoiceOver.
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// ⚠️ HIDDEN RATHER THAN EMPTY FOR AN ENGINE THE CATALOGUE CARRIES NO LEVELS FOR.
    /// An empty picker would offer a value the route is about to discard.
    @ViewBuilder
    private func answerLength(_ draft: PersonaEngineDraft) -> some View {
        if !draft.responseLengths.isEmpty {
            menu(
                label: SettingsCopy.personaAnswerLengthLabel,
                options: draft.responseLengths,
                selection: Binding(
                    get: { draft.values.responseLength },
                    set: { value in model.editEngine { $0.values.responseLength = value } }
                ),
                identifier: A11yID.Persona.answerLength
            )
            note(SettingsCopy.personaAnswerLengthNote)
        }
    }

    /// ⛔ ABSENT FOR THE REALTIME ENGINE, WHICH WOULD ACCEPT IT, STORE IT AND IGNORE IT.
    /// A control with no effect is worse than no control.
    @ViewBuilder
    private func preemptive(_ draft: PersonaEngineDraft) -> some View {
        if draft.capabilities.showsPreemptiveTts {
            VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
                Toggle(SettingsCopy.personaPreemptiveLabel, isOn: Binding(
                    get: { draft.values.preemptiveTts },
                    set: { value in model.editEngine { $0.values.preemptiveTts = value } }
                ))
                .disabled(!enabled)
                .accessibilityIdentifier(A11yID.Persona.preemptiveTts)
                note(SettingsCopy.personaPreemptiveNote)
            }
        }
    }

    /// ⛔ THE DEEPGRAM LIST OR THE GENERAL ONE — see ``PersonaLanguageCatalog``. The
    /// empty selection is a real state after an engine change dropped a language the new
    /// engine does not publish, and it is said rather than hidden.
    @ViewBuilder
    private func language(_ draft: PersonaEngineDraft) -> some View {
        menu(
            label: SettingsCopy.personaLanguageLabel,
            options: draft.languages,
            selection: Binding(
                get: { draft.values.language },
                set: { value in model.editEngine { $0.selectLanguage(value) } }
            ),
            identifier: A11yID.Persona.language
        )
        if draft.values.language.isEmpty {
            note(SettingsCopy.personaLanguageUnset)
        }
    }

    /// ⛔ GROUPED, AND A STORED VALUE THE CATALOGUE HAS DROPPED IS CARRIED AS ITS OWN
    /// ROW. That id is what the workspace speaks in today; leaving it out would make the
    /// picker show nothing selected and the next move would silently replace it.
    private func voice(_ draft: PersonaEngineDraft) -> some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            label(SettingsCopy.personaVoiceLabel)
            Picker(SettingsCopy.personaVoiceLabel, selection: Binding(
                get: { draft.values.voice },
                set: { value in model.editEngine { $0.values.voice = value } }
            )) {
                unsetRow(draft.values.voice.isEmpty)
                if draft.voiceIsOffCatalogue {
                    Text(draft.values.voice).tag(draft.values.voice)
                }
                ForEach(draft.voiceGroups) { group in
                    Section(group.label) {
                        ForEach(group.options) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                }
            }
            .pickerStyle(.menu)
            .disabled(!enabled)
            .accessibilityIdentifier(A11yID.Persona.voice)
            if draft.voiceGroups.isEmpty {
                note(SettingsCopy.personaVoiceEmpty)
            }
            if draft.voiceIsOffCatalogue {
                note(SettingsCopy.personaVoiceOffCatalogue)
            }
        }
    }

    /// ⚠️ THE REALTIME ENGINE ONLY. The chained pipelines have no synthesis stage to
    /// posture, so this would be stored and ignored.
    @ViewBuilder
    private func voiceStyle(_ draft: PersonaEngineDraft) -> some View {
        if draft.capabilities.showsVoiceStyle {
            menu(
                label: SettingsCopy.personaVoiceStyleLabel,
                options: draft.voiceStyles,
                selection: Binding(
                    get: { draft.values.voiceStyle },
                    set: { value in model.editEngine { $0.values.voiceStyle = value } }
                ),
                identifier: A11yID.Persona.voiceStyle
            )
            note(SettingsCopy.personaVoiceStyleNote)
        }
    }

    /// ⚠️ STEPS OF 0.1 RATHER THAN THE WEB'S 0.05. A thumb on a phone cannot reliably
    /// land on twenty-one positions, and the value is read out beside it so the
    /// difference is visible rather than guessed.
    private func temperature(_ draft: PersonaEngineDraft) -> some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            HStack {
                label(SettingsCopy.personaTemperatureLabel)
                Spacer(minLength: DistrictSpacing.tight)
                Text(SettingsCopy.personaTemperatureValue(draft.values.temperature))
                    .font(DistrictType.labelLarge)
                    .foregroundStyle(colors.foreground)
            }
            Slider(
                value: Binding(
                    get: { draft.values.temperature },
                    set: { value in model.editEngine { $0.values.temperature = value } }
                ),
                in: 0 ... 1,
                step: 0.1
            )
            .disabled(!enabled)
            .accessibilityIdentifier(A11yID.Persona.temperature)
            .accessibilityLabel(SettingsCopy.personaTemperatureLabel)
            .accessibilityValue(SettingsCopy.personaTemperatureValue(draft.values.temperature))
            note(SettingsCopy.personaTemperatureNote)
        }
    }

    // MARK: - The panel when the catalogue did not load

    /// ⛔ THE STORED VALUES, SHOWN AS THEY ARE, WITH A RETRY THAT READS THE CATALOGUE
    /// ALONE. It does not re-read the configuration, so it cannot discard what the
    /// operator has typed into the three text fields above.
    @ViewBuilder
    private var unavailable: some View {
        DistrictEyebrow(text: SettingsCopy.personaOptionsFailedEyebrow)
        note(SettingsCopy.personaOptionsFailedNote)
        SettingsReadOnlyRow(label: SettingsCopy.personaEngineLabel, value: model.persona?.modelId)
        SettingsReadOnlyRow(label: SettingsCopy.personaVoiceLabel, value: model.persona?.voice)
        SettingsReadOnlyRow(label: SettingsCopy.personaLanguageLabel, value: model.persona?.language)
        SettingsReadOnlyRow(label: SettingsCopy.personaVoiceStyleLabel, value: model.persona?.voiceStyle)
        if let failure = model.optionsFailure {
            Text(failure.message)
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
            retry(failure)
        }
    }

    /// ⚠️ OFFERED ONLY WHERE ``FailureText/Action/retry`` SAYS SO. A 403 or a contract
    /// mismatch returns the identical answer, and a button that cannot help is worse
    /// than none.
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
    /// ⚠️ IT ALWAYS CARRIES AN "UNSET" ROW WHEN NOTHING IS SELECTED. A SwiftUI `Picker`
    /// whose selection matches no tag renders blank and silently adopts the first tag on
    /// the next interaction, which on this form would be a value nobody chose.
    private func menu(
        label title: String,
        options: [PersonaLabelledValue],
        selection: Binding<String>,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            label(title)
            Picker(title, selection: selection) {
                unsetRow(selection.wrappedValue.isEmpty)
                ForEach(options) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .pickerStyle(.menu)
            .disabled(!enabled)
            .accessibilityIdentifier(identifier)
        }
    }

    /// ⚠️ PRESENT ONLY WHILE NOTHING IS CHOSEN, so a form that has a value cannot be
    /// put back to "not set" — this client can set a vocabulary field and change one,
    /// and deliberately cannot unset one. See the ⛔ on ``PersonaEngineValues``.
    @ViewBuilder
    private func unsetRow(_ visible: Bool) -> some View {
        if visible {
            Text(SettingsCopy.personaUnset).tag("")
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(DistrictType.labelSmall)
            .foregroundStyle(colors.mutedForeground)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(DistrictType.caption)
            .foregroundStyle(colors.mutedForeground)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func select(_ engineId: String) {
        model.editEngine { $0.selectEngine(engineId) }
    }
}
