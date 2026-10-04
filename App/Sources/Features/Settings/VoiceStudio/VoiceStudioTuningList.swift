import DistrictData
import DistrictModel
import SwiftUI

/// The tuning controls for one leg's keys, each drawn only for the model that honours it.
///
/// ⛔ A KEY THIS APP CANNOT MAP IS NOT DRAWN (``VoiceStudioTuning/keys(for:engine:in:)`` filters
/// by ``VoiceStudioTuningPath``), and every number goes through
/// ``VoiceStudioTuning/snap(_:to:)`` and ``VoiceStudioTuning/conform(_:in:)`` on its way into
/// the mix: a value off its step or out of its range would read back differently and the save
/// would report as failed.
///
/// ⛔ TWO TEMPERATURES, TWO KEYS. The realtime model's is `temperature`, 0 to 1, a top-level
/// persona key with no "use the default"; a chain brain's is `engineMix.llm.temperature`, 0 to 2
/// for Gemini, null for the model's own default. The server publishes them as two keys and
/// this list draws whichever the held engine has.
struct VoiceStudioTuningList: View {
    let model: VoiceStudioModel
    let session: VoiceStudioSession
    let keys: [VoiceStudioTuningKey]

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    private static let interruptionPrefix = "engineMix.turn.interruption."

    var body: some View {
        ForEach(keys, id: \.key) { key in
            if key.key == firstInterruption {
                DistrictEyebrow(text: session.studio.labels.interruptions)
            }
            control(key)
        }
    }

    /// The Advanced control above which the "Interruptions" heading goes.
    private var firstInterruption: String? {
        keys.first { $0.key.hasPrefix(Self.interruptionPrefix) }?.key
    }

    private func control(_ key: VoiceStudioTuningKey) -> some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            switch key.control {
            case "slider":
                slider(key)
            case "select":
                select(key)
            case "checkbox":
                checkbox(key)
            default:
                keyterms(key)
            }
            if let description = key.description {
                Text(description)
                    .font(DistrictType.caption)
                    .foregroundStyle(colors.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier(A11yID.VoiceStudio.handle(A11yID.VoiceStudio.tuningKind, key.key))
    }

    // MARK: - Numbers

    @ViewBuilder
    private func slider(_ key: VoiceStudioTuningKey) -> some View {
        let engine = session.held.engine
        if let range = VoiceStudioTuning.range(key, for: engine) {
            if key.key == VoiceStudioTuningPath.realtimeTemperature {
                VoiceStudioSlider(
                    label: key.label,
                    handle: key.key,
                    value: session.held.realtimeTemperature,
                    range: range,
                    enabled: model.canEdit,
                    onSlide: { raw in
                        let value = VoiceStudioTuning.snap(raw, to: range)
                        model.updateHeld { state in
                            var next = state
                            next.realtimeTemperature = value
                            return next
                        }
                    },
                    onUseDefault: nil
                )
            } else if let path = VoiceStudioNumberPath(rawValue: key.key), let mix = engine.mix {
                VoiceStudioSlider(
                    label: key.label,
                    handle: key.key,
                    value: path.value(in: mix),
                    range: range,
                    enabled: model.canEdit,
                    onSlide: { raw in setNumber(path, VoiceStudioTuning.snap(raw, to: range)) },
                    onUseDefault: { useDefault in setNumber(path, useDefault ? nil : range.start) }
                )
            }
        }
    }

    private func setNumber(_ path: VoiceStudioNumberPath, _ value: Double?) {
        let studio = session.studio
        model.editMix { VoiceStudioTuning.conform(path.setting(value, in: $0), in: studio) }
    }

    // MARK: - Choices

    @ViewBuilder
    private func select(_ key: VoiceStudioTuningKey) -> some View {
        if key.key == VoiceStudioTuningPath.voiceStyle {
            choice(key, options: key.options ?? [], selected: session.held.voiceStyle ?? "") { style in
                model.updateHeld { state in
                    var next = state
                    next.voiceStyle = style
                    return next
                }
            }
        } else if let path = VoiceStudioChoicePath(rawValue: key.key), let mix = session.held.engine.mix {
            // ⚠️ THINKING'S OPTIONS ARE PER BRAIN, so they come from the catalogue, not the key.
            let brain = session.studio.catalog.llm.first(where: { $0.model == mix.llm.model })
            let options = path == .llmThinking ? brain?.thinking ?? [] : key.options ?? []
            choice(key, options: options, selected: path.value(in: mix)) { value in
                model.editMix { path.setting(value, in: $0) }
            }
        }
    }

    private func choice(
        _ key: VoiceStudioTuningKey,
        options: [VoiceStudioOption],
        selected: String,
        onSelect: @escaping (String) -> Void
    ) -> some View {
        let picker = VoiceStudioPicker(
            label: key.label,
            options: options.map { VoiceStudioPickerOption(value: $0.value, label: $0.label) },
            selected: selected.isEmpty ? nil : selected,
            handle: key.key,
            onSelect: onSelect
        )
        return VoiceStudioPickerRow(picker: picker, enabled: model.canEdit)
    }

    // MARK: - Speak sooner and key terms

    /// "Start speaking sooner": `engineMix.preemptiveTts`, chains only.
    @ViewBuilder
    private func checkbox(_ key: VoiceStudioTuningKey) -> some View {
        if let mix = session.held.engine.mix {
            Toggle(key.label, isOn: Binding(
                get: { mix.preemptiveTts },
                set: { on in setPreemptive(on) }
            ))
            .disabled(!model.canEdit)
            .accessibilityIdentifier(A11yID.VoiceStudio.handle(A11yID.VoiceStudio.checkboxKind, key.key))
        }
    }

    private func setPreemptive(_ on: Bool) {
        model.editMix { current in
            var next = current
            next.preemptiveTts = on
            return next
        }
    }

    @ViewBuilder
    private func keyterms(_ key: VoiceStudioTuningKey) -> some View {
        if let mix = session.held.engine.mix {
            VoiceStudioKeytermsField(key: key, terms: mix.stt.keyterms ?? [], enabled: model.canEdit) { text in
                let terms = VoiceStudioTuning.parseKeyterms(text, key: key)
                model.editMix { current in
                    var next = current
                    next.stt.keyterms = terms.isEmpty ? nil : terms
                    return next
                }
            }
        }
    }
}

/// One number: a slider, its value in words, and, for a nullable key, "use the default".
struct VoiceStudioSlider: View {
    let label: String
    /// The tuning key's path, for the test handles.
    let handle: String
    /// Nil: the default is in force.
    let value: Double?
    let range: VoiceStudioTuningRange
    let enabled: Bool
    let onSlide: (Double) -> Void
    /// Nil for a number that always has a value (the realtime temperature).
    let onUseDefault: ((Bool) -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    private var shown: Double {
        value ?? range.start
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            HStack {
                Text(label)
                    .font(DistrictType.labelSmall)
                    .foregroundStyle(colors.mutedForeground)
                Spacer(minLength: DistrictSpacing.tight)
                Text(VoiceStudioCopy.tuningValue(shown, whole: range.isWhole))
                    .font(DistrictType.labelLarge)
                    .foregroundStyle(colors.foreground)
            }
            slider
                .disabled(!enabled || (onUseDefault != nil && value == nil))
                .accessibilityLabel(label)
                .accessibilityValue(VoiceStudioCopy.tuningValue(shown, whole: range.isWhole))
                .accessibilityIdentifier(A11yID.VoiceStudio.handle(A11yID.VoiceStudio.sliderKind, handle))
            if let onUseDefault {
                Toggle(range.useDefaultLabel ?? VoiceStudioCopy.useDefault, isOn: Binding(
                    get: { value == nil },
                    set: { useDefault in onUseDefault(useDefault) }
                ))
                .disabled(!enabled)
                .accessibilityIdentifier(A11yID.VoiceStudio.handle(A11yID.VoiceStudio.defaultKind, handle))
            }
        }
    }

    @ViewBuilder
    private var slider: some View {
        let binding = Binding(get: { shown }, set: { raw in onSlide(raw) })
        if let step = range.step, step > 0 {
            Slider(value: binding, in: range.min ... range.max, step: step)
        } else {
            Slider(value: binding, in: range.min ... range.max)
        }
    }
}

/// Key terms, one per line.
///
/// ⚠️ THE BOX SHOWS WHAT WAS TYPED WHILE IT STILL PARSES TO THE HELD LIST, so a trailing newline
/// or a space being typed is not eaten; after a reset it shows the held list again.
struct VoiceStudioKeytermsField: View {
    let key: VoiceStudioTuningKey
    let terms: [String]
    let enabled: Bool
    let onText: (String) -> Void

    @State private var typed = ""

    private var shown: String {
        VoiceStudioTuning.parseKeyterms(typed, key: key) == terms ? typed : terms.joined(separator: "\n")
    }

    var body: some View {
        SettingsField(
            label: key.label,
            text: Binding(
                get: { shown },
                set: { text in
                    typed = text
                    onText(text)
                }
            ),
            enabled: enabled,
            multiline: true
        )
        .accessibilityIdentifier(A11yID.VoiceStudio.handle(A11yID.VoiceStudio.keytermsKind, key.key))
    }
}
