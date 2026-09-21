import DistrictModel
import DistrictNetwork
import SwiftUI

/// The dynamic-persona rules: how the agent changes voice or engine depending on who is
/// calling. Ported from Android's `RoutingRulesScreen.kt`, editor included.
///
/// ⛔ THE SAVE REPLACES THE WHOLE LIST, WHICH IS WHY THIS IS SHAPED THE WAY IT IS.
/// `POST workspace/routing-rules` replaces the stored array
/// wholesale, the column is `Json`, and its per-rule schema is `.passthrough()` — so:
///
///   1. every row carries its STORED object and overwrites only the six keys this form
///      owns, and a row this build cannot read is sent back byte-identically rather than
///      rebuilt or dropped (``RoutingRuleDraft``);
///   2. an unrecognised row is SHOWN and is not offered an editor, because an editor
///      over it would have to invent those six keys;
///   3. a save that would send an empty array is CONFIRMED, naming what happens on the
///      next call rather than asking whether the operator is sure;
///   4. nothing is pre-validated against a guess. The per-workspace voice and engine
///      allow-list is invisible to this client, so the pickers offer the catalogue
///      `persona/options` publishes and a refusal is shown verbatim — it names the value.
///
/// ⚠️ AN EMPTY LIST IS A REAL ANSWER AND THE ORDINARY ONE. Most workspaces have no
/// dynamic rules and every caller hears the configured persona, which the empty state
/// says rather than implying something is missing.
///
/// ⚠️ A VIEWER NEVER REACHES THIS SCREEN: `workspace/config` excludes them server-side,
/// which is why ``RouteGate`` hides the row. The model still gates every write, because
/// a control that was not drawn is not a boundary.
struct RoutingView: View {
    @State private var model: RoutingModel
    @State private var confirmingEmpty = false

    @Environment(\.colorScheme) private var colorScheme

    init(container: AppContainer, workspaceId: String, role: WorkspaceRole?) {
        _model = State(initialValue: RoutingModel(
            container: container,
            workspaceId: workspaceId,
            role: role
        ))
    }

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    private var enabled: Bool {
        model.canWrite && !model.save.isSaving
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DistrictSpacing.section) {
                content
            }
            .padding(DistrictSpacing.gutter)
            .districtReadableWidth()
        }
        .accessibilityIdentifier(A11yID.Routing.root)
        .navigationTitle(SettingsCopy.routingTitle)
        .task {
            await model.loadConfig()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.load {
        case .loading:
            SettingsSkeleton()
        case .ready:
            if model.notEditable {
                SettingsNotEditableNotice()
            } else if let drafts = model.drafts {
                editor(drafts)
            }
        case let .failed(failure):
            SettingsLoadFailureView(failure: failure, onRetry: reload)
        }
    }

    @ViewBuilder
    private func editor(_ drafts: [RoutingRuleDraft]) -> some View {
        if drafts.isEmpty {
            EmptyStateView(
                systemImage: "arrow.triangle.branch",
                title: SettingsCopy.routingEmptyTitle,
                message: SettingsCopy.routingEmptyBody
            )
        } else {
            ForEach(drafts) { draft in
                SettingsCard(eyebrow: SettingsCopy.routingRuleEyebrow) {
                    rule(draft)
                }
                .accessibilityIdentifier(A11yID.Routing.row(draft.id))
            }
        }
        controls
    }

    // MARK: - One rule

    @ViewBuilder
    private func rule(_ draft: RoutingRuleDraft) -> some View {
        if draft.isRecognised {
            match(draft)
            action(draft)
        } else {
            // ⛔ SHOWN, KEPT, AND NOT EDITED. See the ⛔ on ``RoutingRuleDraft``.
            note(SettingsCopy.routingUnrecognised, colors.warning)
        }
        if draft.isIncomplete {
            // ⚠️ FLAGGED, NOT REFUSED. A rule with nothing to match on is legal, is
            // stored, and simply never fires.
            note(SettingsCopy.routingIncomplete, colors.warning)
        }
        if model.canWrite {
            Button(SettingsCopy.routingRemove) { model.removeRule(draft.id) }
                .buttonStyle(.districtGhost)
                .disabled(model.save.isSaving)
                .accessibilityIdentifier(A11yID.Routing.remove(draft.id))
        }
    }

    /// ⛔ THE FIELD AND OPERATOR LISTS ARE THE ONE HARDCODED VOCABULARY IN THIS FEATURE
    /// AND THE ONE THAT HAS TO BE: no route publishes them, and the save route validates
    /// neither — a misspelled field is stored, answered 200, and then matches no caller
    /// for the life of the rule. ⚠️ THE LABELS CARRY THEIR VALUE HINTS ("Caller Type
    /// (business/consumer)") because the match is a substring test against a value
    /// nothing documents on screen.
    @ViewBuilder
    private func match(_ draft: RoutingRuleDraft) -> some View {
        picker(
            label: SettingsCopy.routingFieldLabel,
            selection: Binding(
                get: { draft.field },
                set: { value in model.edit(draft.id) { $0.field = value } }
            ),
            identifier: A11yID.Routing.field(draft.id)
        ) {
            ForEach(RoutingRuleField.allCases, id: \.rawValue) { field in
                Text(field.label).tag(field.rawValue)
            }
        }
        picker(
            label: SettingsCopy.routingOperatorLabel,
            selection: Binding(
                get: { draft.ruleOperator },
                set: { value in model.edit(draft.id) { $0.ruleOperator = value } }
            ),
            identifier: A11yID.Routing.ruleOperator(draft.id)
        ) {
            ForEach(RoutingRuleOperator.allCases, id: \.rawValue) { option in
                Text(option.label).tag(option.rawValue)
            }
        }
        SettingsField(
            label: SettingsCopy.routingValueLabel,
            text: Binding(
                get: { draft.value },
                set: { value in model.edit(draft.id) { $0.value = value } }
            ),
            enabled: enabled
        )
        .accessibilityIdentifier(A11yID.Routing.value(draft.id))
    }

    @ViewBuilder
    private func action(_ draft: RoutingRuleDraft) -> some View {
        voice(draft)
        engine(draft)
        SettingsField(
            label: SettingsCopy.routingInstructionLabel,
            text: Binding(
                get: { draft.instruction },
                set: { value in model.edit(draft.id) { $0.instruction = value } }
            ),
            enabled: enabled,
            multiline: true
        )
        .accessibilityIdentifier(A11yID.Routing.instruction(draft.id))
    }

    /// ⚠️ AN EMPTY CATALOGUE IS A REAL ANSWER: the stored voice is shown and cannot be
    /// changed, which is honest about a list this build could not read.
    @ViewBuilder
    private func voice(_ draft: RoutingRuleDraft) -> some View {
        if model.ruleVoices.isEmpty {
            SettingsReadOnlyRow(label: SettingsCopy.routingVoiceLabel, value: stored(draft.voice))
            note(SettingsCopy.routingVoicesEmpty, colors.mutedForeground)
        } else {
            picker(
                label: SettingsCopy.routingVoiceLabel,
                selection: Binding(
                    get: { draft.voice },
                    set: { value in model.edit(draft.id) { $0.voice = value } }
                ),
                identifier: A11yID.Routing.voice(draft.id)
            ) {
                if !model.ruleVoices.contains(where: { $0.value == draft.voice }) {
                    // ⚠️ THE STORED VALUE IS CARRIED AS ITS OWN ROW. A picker whose
                    // selection matches no tag renders blank and adopts the first tag on
                    // the next interaction, which here would silently change a live rule.
                    Text(stored(draft.voice)).tag(draft.voice)
                }
                ForEach(model.ruleVoices) { option in
                    Text(option.label).tag(option.value)
                }
            }
        }
    }

    /// ⛔ AN EMPTY `model` IS A REAL, MEANINGFUL VALUE AND IS OFFERED AS ONE. The route
    /// reads a falsy model as "no override, use the workspace engine"; dropping the key
    /// instead would work today and mean something different the day the route starts
    /// distinguishing them.
    @ViewBuilder
    private func engine(_ draft: RoutingRuleDraft) -> some View {
        let offered = model.ruleEngines.filter(\.inRegion)
        if offered.isEmpty {
            SettingsReadOnlyRow(label: SettingsCopy.routingModelLabel, value: stored(draft.model))
        } else {
            picker(
                label: SettingsCopy.routingModelLabel,
                selection: Binding(
                    get: { draft.model },
                    set: { value in model.edit(draft.id) { $0.model = value } }
                ),
                identifier: A11yID.Routing.model(draft.id)
            ) {
                Text(SettingsCopy.routingModelInherit).tag("")
                // ⛔ OUT-OF-REGION ENGINES ARE OMITTED HERE AND MERELY DISABLED ON THE
                // PERSONA FORM, AND THE DIFFERENCE IS THE CONTROL RATHER THAN THE RULE.
                // That form draws each engine as a real `Button`, where `.disabled`
                // is honoured and the label can still state where the audio would go.
                // A `Picker` row is menu content whose response to `.disabled` is not
                // something this client should stake a residency decision on — so the
                // rule is enforced by what is in the list. A stored value outside it is
                // carried below rather than dropped.
                ForEach(offered, id: \.id) { option in
                    Text(option.label).tag(option.id)
                }
                if !draft.model.isEmpty, !offered.contains(where: { $0.id == draft.model }) {
                    Text(draft.model).tag(draft.model)
                }
            }
        }
    }

    // MARK: - The controls

    @ViewBuilder
    private var controls: some View {
        if model.canWrite {
            VStack(alignment: .leading, spacing: DistrictSpacing.tight) {
                note(SettingsCopy.routingNote, colors.mutedForeground)
                Button(SettingsCopy.routingAdd) { model.addRule() }
                    .buttonStyle(.districtSecondary)
                    .disabled(model.save.isSaving)
                    .accessibilityIdentifier(A11yID.Routing.add)
                SettingsSaveNotice(state: model.save, onReread: reload, onDismiss: model.dismissNotices)
                note(SettingsCopy.routingSaveHint, colors.mutedForeground)
                Button(model.save.isSaving ? "Saving…" : SettingsCopy.routingSave, action: submit)
                    .buttonStyle(.districtPrimary)
                    .disabled(!model.canSave)
                    .accessibilityIdentifier(A11yID.Routing.save)
                    // ⛔ ON THE SAVE THAT ASKS FOR IT, AND IT FIRES ON WHAT WOULD BE SENT
                    // RATHER THAN ON WHETHER THE LIST LOOKS EMPTY. A screen of abandoned
                    // blank rows saves as an empty array too, and that is the case an
                    // operator would least expect to delete every rule.
                    .confirmationDialog(
                        SettingsCopy.routingEmptyConfirm,
                        isPresented: $confirmingEmpty,
                        titleVisibility: .visible
                    ) {
                        Button(SettingsCopy.routingEmptyConfirmAction, role: .destructive, action: commit)
                        Button("Cancel", role: .cancel) {}
                    }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Chrome

    private func picker(
        label title: String,
        selection: Binding<String>,
        identifier: String,
        @ViewBuilder options: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            Text(title)
                .font(DistrictType.labelSmall)
                .foregroundStyle(colors.mutedForeground)
            Picker(title, selection: selection, content: options)
                .pickerStyle(.menu)
                .disabled(!enabled)
                .accessibilityIdentifier(identifier)
        }
    }

    private func note(_ text: String, _ tint: Color) -> some View {
        Text(text)
            .font(DistrictType.caption)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// ⚠️ "Not set" RATHER THAN A BLANK, the rule ``SettingsReadOnlyRow`` follows: an
    /// empty line beside a label reads as a value that failed to load.
    private func stored(_ value: String) -> String {
        value.isEmpty ? SettingsCopy.personaUnset : value
    }

    /// ⛔ THE EMPTY CASE ASKS FIRST. Everything else commits straight away: changing one
    /// rule's voice is an ordinary edit, and a prompt on every save would teach the
    /// operator to tap through the one that matters.
    private func submit() {
        guard model.wouldSaveEmpty else {
            commit()
            return
        }
        confirmingEmpty = true
    }

    private func commit() {
        Task { await model.saveRules() }
    }

    private func reload() {
        Task { await model.loadConfig() }
    }
}
