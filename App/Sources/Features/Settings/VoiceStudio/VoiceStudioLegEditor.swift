import DistrictData
import DistrictModel
import SwiftUI

/// The editor for the leg the chain strip has selected: its vendor, model and location
/// pickers, the voice picker on the Voice leg (and on a realtime engine), the leg's main tuning
/// keys, and the rest behind Advanced.
///
/// ⛔ EVERY LIST IS THE SERVER'S, and every choice goes through ``VoiceStudioLegEdits``, which
/// moves the dependent fields with it (a new mouth's starting voice, a location the new model
/// is offered in) so the chain stays one the PATCH accepts. A binding straight to a mix field
/// would save a chain the server refuses with `invalid_engine_mix`.
struct VoiceStudioLegEditor: View {
    let model: VoiceStudioModel
    let session: VoiceStudioSession

    @State private var showsAdvanced = false

    private var labels: VoiceStudioLabels {
        session.studio.labels
    }

    private var studio: VoiceStudioResponse {
        session.studio
    }

    var body: some View {
        SettingsCard(eyebrow: "\(labels.editLeg): \(legTitle)") {
            ForEach(pickers, id: \.handle) { picker in
                VoiceStudioPickerRow(picker: picker, enabled: model.canEdit)
            }
            voicePicker
            VoiceStudioTuningList(model: model, session: session, keys: keys(in: "main"))
            advanced
        }
    }

    private var legTitle: String {
        switch session.leg {
        case .stt: labels.legs.stt
        case .turn: labels.legs.turn
        case .llm: labels.legs.llm
        case .tts: labels.legs.tts
        case .realtime: VoiceStudioReadout.blocks(session.held.engine, in: studio).first?.title ?? labels.modelLabel
        }
    }

    // MARK: - Pickers

    /// The vendor, model and location pickers the held leg has.
    ///
    /// ⚠️ TURN-TAKING HAS NO MODEL OF ITS OWN TO PICK: Flux's, or the agent's detector. Its
    /// controls are all tuning keys.
    private var pickers: [VoiceStudioPicker] {
        let held = session.held
        guard case let .chained(mix) = held.engine else {
            return [realtimePicker(held.engine)]
        }
        let bilingual = held.bilingual
        var rows: [VoiceStudioPicker]
        switch session.leg {
        case .stt:
            rows = [
                VoiceStudioPicker(
                    label: labels.providerLabel,
                    options: VoiceStudioPickers.earVendors(mix, bilingual: bilingual, in: studio),
                    selected: mix.stt.provider,
                    handle: "ear-vendor"
                ) { provider in
                    model.editMix { mix in
                        VoiceStudioLegEdits.earVendor(mix, provider: provider, bilingual: bilingual, in: studio)
                    }
                },
                VoiceStudioPicker(
                    label: labels.modelLabel,
                    options: VoiceStudioPickers.earModels(mix, bilingual: bilingual, in: studio),
                    selected: mix.stt.model,
                    handle: "ear-model"
                ) { name in
                    model.editMix { VoiceStudioLegEdits.earModel($0, model: name, in: studio) }
                },
            ]
        case .llm:
            rows = [
                VoiceStudioPicker(
                    label: labels.modelLabel,
                    options: VoiceStudioPickers.brainModels(mix, in: studio),
                    selected: mix.llm.model,
                    handle: "brain-model"
                ) { name in
                    model.editMix { VoiceStudioLegEdits.brainModel($0, model: name, in: studio) }
                },
            ]
        case .tts:
            rows = mouthPickers(mix, bilingual: bilingual)
        case .turn, .realtime:
            return []
        }
        if let location = locationPicker(mix) {
            rows.append(location)
        }
        return rows
    }

    private func mouthPickers(_ mix: EngineMix, bilingual: Bool) -> [VoiceStudioPicker] {
        [
            VoiceStudioPicker(
                label: labels.providerLabel,
                options: VoiceStudioPickers.voiceVendors(mix, bilingual: bilingual, in: studio),
                selected: mix.tts.provider,
                handle: "voice-vendor"
            ) { provider in
                model.editMix { mix in
                    VoiceStudioLegEdits.voiceVendor(mix, provider: provider, bilingual: bilingual, in: studio)
                }
            },
            VoiceStudioPicker(
                label: labels.modelLabel,
                options: VoiceStudioPickers.voiceModels(mix, bilingual: bilingual, in: studio),
                selected: mix.tts.model,
                handle: "voice-model"
            ) { name in
                model.editMix { VoiceStudioLegEdits.voiceModel($0, model: name, in: studio) }
            },
        ]
    }

    /// A leg's location, when its model has a list (a vendor endpoint has none).
    private func locationPicker(_ mix: EngineMix) -> VoiceStudioPicker? {
        let leg = session.leg
        let options = VoiceStudioPickers.locations(for: leg, mix: mix, in: studio)
        guard !options.isEmpty else { return nil }
        return VoiceStudioPicker(
            label: labels.locationLabel,
            options: options,
            selected: VoiceStudioPickers.heldLocation(for: leg, mix: mix, options: options),
            handle: "\(leg.rawValue)-location"
        ) { location in
            model.editMix { VoiceStudioLegEdits.location($0, leg: leg, location: location) }
        }
    }

    private func realtimePicker(_ engine: VoiceStudioEngine) -> VoiceStudioPicker {
        VoiceStudioPicker(
            label: labels.modelLabel,
            options: VoiceStudioPickers.realtimeModels(modelId: engine.realtimeModelId, in: studio),
            selected: engine.realtimeModelId,
            handle: "realtime-model"
        ) { name in
            model.updateHeld { state in
                var next = state
                next.engine = VoiceStudioLegEdits.realtimeModel(voice: state.engine.voice, model: name, in: studio)
                return next
            }
        }
    }

    // MARK: - The voice

    /// The voice picker, on the Voice leg of a chain and on a realtime engine.
    @ViewBuilder
    private var voicePicker: some View {
        let engine = session.held.engine
        if session.leg == .tts || session.leg == .realtime {
            VoiceStudioVoicePicker(
                labels: labels,
                list: VoiceStudioRecipes.voices(for: engine, in: studio),
                selected: engine.voice,
                enabled: model.canEdit
            ) { voice in
                model.updateHeld { state in
                    var next = state
                    next.engine = state.engine.withVoice(voice)
                    return next
                }
            }
        }
    }

    // MARK: - Tuning

    private func keys(in section: String) -> [VoiceStudioTuningKey] {
        VoiceStudioTuning.keys(for: session.leg, engine: session.held.engine, in: studio)
            .filter { $0.section == section }
    }

    @ViewBuilder
    private var advanced: some View {
        let advancedKeys = keys(in: "advanced")
        if !advancedKeys.isEmpty {
            Button(showsAdvanced ? VoiceStudioCopy.advancedHide : VoiceStudioCopy.advancedShow) {
                showsAdvanced.toggle()
            }
            .buttonStyle(.districtGhost)
            .accessibilityLabel(labels.advanced)
            .accessibilityValue(showsAdvanced ? VoiceStudioCopy.advancedHide : VoiceStudioCopy.advancedShow)
            .accessibilityIdentifier(A11yID.VoiceStudio.handle(A11yID.VoiceStudio.advancedKind, session.leg.rawValue))
            if showsAdvanced {
                DistrictEyebrow(text: labels.advanced)
                VoiceStudioTuningList(model: model, session: session, keys: advancedKeys)
            }
        }
    }
}

/// One picker as the leg editor draws it: what it offers, what is held, and what a choice does.
struct VoiceStudioPicker {
    let label: String
    let options: [VoiceStudioPickerOption]
    let selected: String?
    /// The picker's handle (`ear-vendor`, `llm-location`, ...), as Android names it.
    let handle: String
    let onSelect: (String) -> Void
}

/// One labelled menu over a picker's options.
///
/// ⚠️ A HELD VALUE THE LIST DOES NOT CARRY IS SHOWN AS ITS OWN ROW. A SwiftUI `Picker` whose
/// selection matches no tag renders blank and adopts the first tag on the next interaction,
/// which here would be a model nobody chose.
struct VoiceStudioPickerRow: View {
    let picker: VoiceStudioPicker
    let enabled: Bool

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            Text(picker.label)
                .font(DistrictType.labelSmall)
                .foregroundStyle(colors.mutedForeground)
            Picker(picker.label, selection: Binding(
                get: { picker.selected ?? "" },
                set: { value in picker.onSelect(value) }
            )) {
                if let held = picker.selected, !picker.options.contains(where: { $0.value == held }) {
                    Text(held).tag(held)
                }
                ForEach(picker.options) { option in
                    Text(option.text).tag(option.value)
                }
            }
            .pickerStyle(.menu)
            .disabled(!enabled)
            .accessibilityIdentifier(A11yID.VoiceStudio.handle(A11yID.VoiceStudio.pickerKind, picker.handle))
        }
    }
}

/// The voice picker: every voice of the held mouth (or realtime model), under its headings.
struct VoiceStudioVoicePicker: View {
    let labels: VoiceStudioLabels
    let list: VoiceStudioVoiceList?
    let selected: String
    let enabled: Bool
    let onSelect: (String) -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    private var held: Bool {
        VoiceStudioRecipes.voiceOption(selected, in: list) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            Text(labels.voiceLabel)
                .font(DistrictType.labelSmall)
                .foregroundStyle(colors.mutedForeground)
            Picker(labels.voiceLabel, selection: Binding(
                get: { selected },
                set: { value in onSelect(value) }
            )) {
                if !held {
                    Text(selected.isEmpty ? labels.voicePlaceholder : selected).tag(selected)
                }
                ForEach(Array((list?.groups ?? []).enumerated()), id: \.offset) { entry in
                    group(entry.element)
                }
            }
            .pickerStyle(.menu)
            .disabled(!enabled)
            .accessibilityIdentifier(A11yID.VoiceStudio.handle(A11yID.VoiceStudio.pickerKind, "voice"))
        }
    }

    /// ⚠️ A HEADING OF `""` IS NO HEADING (Gemini Live's flat list).
    @ViewBuilder
    private func group(_ group: VoiceStudioVoiceGroup) -> some View {
        if group.label.isEmpty {
            ForEach(group.options, id: \.value) { option in
                Text(option.label).tag(option.value)
            }
        } else {
            Section(group.label) {
                ForEach(group.options, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
        }
    }
}
