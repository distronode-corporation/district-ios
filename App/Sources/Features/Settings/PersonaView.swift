import DistrictModel
import SwiftUI

/// The persona an operator may edit from a phone, and the audition that proves it.
/// Ported from Android's `PersonaFormScreen.kt`, which has neither the pickers nor the
/// preview.
///
/// ⛔ NO FIELD AND NO SAVE BUTTON EXISTS WHEN THE CONFIGURATION DID NOT LOAD. That
/// absence is the feature, not an oversight in the layout: this whole surface's rule
/// is that a save is built on a successful read, and the load-failure branch below
/// renders a retry and nothing else. See the ⛔ on ``SettingsLoadFailureView``.
///
/// ⛔ THE LANGUAGE PANEL IS FILLED ONLY FROM THE SERVER'S CATALOGUE. Every field on it
/// COERCES rather than rejects server-side, so the choice is between offering free text
/// that produces a persona nobody chose and reading the catalogue the web derives its own
/// pickers from. `persona/options` is that catalogue, and ``PersonaIdentityDraft`` is the
/// only thing that may fill these controls. ⛔ WHEN IT DOES NOT LOAD THE PANEL FALLS BACK
/// TO SHOWING THE STORED VALUES AND NOTHING ELSE — never to a built-in list.
///
/// ⛔ THE ENGINE, THE VOICE AND THE TUNING ARE THE VOICE STUDIO'S, its own row in workspace
/// settings (``VoiceStudioView``), and the panel says so.
///
/// ⛔ THE AVATAR ROW IS A STATUS AND NEVER A CONTROL. Turning video on starts a
/// billable Tavus stream, and App Store Review Guideline 3.1.3(b) plus the ⛔ on
/// `AiPersona.videoEnabled` both point the same way: nothing in this app writes it.
///
/// ⚠️ THE PREVIEW IS A SHEET AND A DELIBERATE PRESS. It mints a credential that invites
/// the voice agent into a room and starts burning speech and model minutes, so it is
/// never an effect of arriving on the screen.
struct PersonaView: View {
    @State private var model: PersonaModel
    @State private var previewing = false

    @Environment(\.colorScheme) private var colorScheme

    init(container: AppContainer, workspaceId: String, role: WorkspaceRole?) {
        // ⚠️ `State(initialValue:)` in `init`, the `@Observable` equivalent of the
        // old `StateObject(wrappedValue:)` autoclosure. Building it in `body` would
        // be a new model, and a new config read, on every redraw.
        _model = State(initialValue: PersonaModel(
            container: container,
            workspaceId: workspaceId,
            role: role
        ))
        self.container = container
        self.workspaceId = workspaceId
    }

    private let container: AppContainer
    private let workspaceId: String

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DistrictSpacing.section) {
                content
            }
            .padding(DistrictSpacing.gutter)
            .districtReadableWidth()
        }
        .accessibilityIdentifier(A11yID.Persona.root)
        .navigationTitle(SettingsCopy.personaTitle)
        .task {
            await model.loadConfig()
        }
        .sheet(isPresented: $previewing) {
            preview
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.load {
        case .loading:
            SettingsSkeleton()
        case .ready:
            form
            PersonaIdentitySection(model: model)
            avatar
        case let .failed(failure):
            SettingsLoadFailureView(failure: failure, onRetry: reload)
        }
    }

    // MARK: - The three free-text fields

    private var form: some View {
        SettingsCard(eyebrow: SettingsCopy.personaTitle) {
            SettingsField(
                label: SettingsCopy.personaNameLabel,
                text: binding(.name),
                enabled: model.canWrite && !model.save.isSaving
            )
            .accessibilityIdentifier(A11yID.Persona.name)
            SettingsField(
                label: SettingsCopy.personaGreetingLabel,
                text: binding(.greeting),
                enabled: model.canWrite && !model.save.isSaving,
                multiline: true
            )
            .accessibilityIdentifier(A11yID.Persona.greeting)
            SettingsField(
                label: SettingsCopy.personaPersonalityLabel,
                text: binding(.personality),
                enabled: model.canWrite && !model.save.isSaving,
                multiline: true
            )
            .accessibilityIdentifier(A11yID.Persona.personality)
            SettingsSaveNotice(state: model.save, onReread: reload, onDismiss: model.dismissNotice)
            saveButton
            previewButton
        }
    }

    /// ⚠️ DISABLED RATHER THAN HIDDEN WHEN NOTHING IS DIRTY. A button that vanishes
    /// as you type the last character back is harder to understand than one that
    /// greys out, and this screen has nowhere else to put the affordance.
    private var saveButton: some View {
        Button(model.save.isSaving ? "Saving…" : SettingsCopy.personaSave, action: submit)
            .buttonStyle(.districtPrimary)
            .disabled(!model.canSave)
            .accessibilityIdentifier(A11yID.Persona.save)
    }

    /// ⛔ DISABLED UNTIL THE CATALOGUE IS IN, WHICH IS THE SAME RULE THE PICKERS FOLLOW
    /// AND MATTERS MORE HERE. The preview route coerces an unrecognised `modelId` the
    /// way the save route does, so auditioning a form this build could not check would
    /// spend a billed session on an engine nobody chose. ``PersonaModel/previewForm``
    /// is nil in exactly that case.
    @ViewBuilder
    private var previewButton: some View {
        if model.canWrite {
            VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
                Button(SettingsCopy.previewTitle) { previewing = true }
                    .buttonStyle(.districtSecondary)
                    .disabled(model.previewForm == nil)
                    .accessibilityIdentifier(A11yID.Persona.preview)
                Text(SettingsCopy.previewIntro)
                    .font(DistrictType.caption)
                    .foregroundStyle(colors.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// ⚠️ BUILT WHEN THE SHEET OPENS, so the form it auditions is the one on screen at
    /// that moment rather than the one that existed when the screen was drawn.
    @ViewBuilder
    private var preview: some View {
        if let form = model.previewForm {
            PersonaPreviewView(
                container: container,
                workspaceId: workspaceId,
                form: form
            )
        }
    }

    // MARK: - The avatar, which is a status

    private var avatar: some View {
        SettingsCard(eyebrow: SettingsCopy.personaAvatarLabel) {
            SettingsReadOnlyRow(label: SettingsCopy.personaAvatarLabel, value: avatarState)
            Text(SettingsCopy.personaAvatarNote)
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// ⚠️ THREE ANSWERS, NOT TWO. Nil means the workspace has never answered, which
    /// is not the same as having turned it off, and on a billable feature the
    /// difference is worth a word.
    private var avatarState: String? {
        guard let enabled = model.persona?.videoEnabled else { return nil }
        return enabled ? "On" : "Off"
    }

    // MARK: - Wiring

    /// ⛔ EVERY EDIT GOES THROUGH ``PersonaModel/edit(_:to:)``, WHICH IS WHERE THE
    /// "no baseline, no draft" GUARD LIVES. A binding straight to a property would
    /// let a keystroke accumulate against a configuration that never loaded.
    private func binding(_ field: PersonaModel.Field) -> Binding<String> {
        Binding(get: { model.value(field) }, set: { model.edit(field, to: $0) })
    }

    private func submit() {
        Task { await model.saveChanges() }
    }

    private func reload() {
        Task { await model.loadConfig() }
    }
}
