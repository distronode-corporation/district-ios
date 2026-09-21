import SwiftUI

/// Create or edit one carrier account. Ported from Android's
/// `MessagingAccountForm.kt`.
///
/// ⛔ AN ORDINARY EDIT TYPES NO CREDENTIAL AT ALL, AND THAT IS THE WHOLE REASON THIS
/// FORM CAN EXIST. The read carries no secret, so there is nothing to pre-fill with;
/// the route reads a blank or absent secret as "keep the stored ciphertext", so leaving
/// the boxes alone preserves what is stored. ⛔ EXCEPT ON A PROVIDER CHANGE, where the
/// stored secrets are DISCARDED rather than reused, so a blank box there means "store
/// nothing" — which is what ``MessagingDraft/secretsRequired`` makes the form say.
///
/// ⛔ THE PROBE IS NOT A SAVE AND THE FORM NEVER SAVES ON THE STRENGTH OF ONE. It sends
/// plaintext, unsaved credentials to a route that makes one authenticated third-party
/// call per request from the platform's own egress; it is offered only when every field
/// for the provider is filled, and its three outcomes are three different sentences.
///
/// ⛔ THE DRAFT LIVES ON THE MODEL AND IS READ THROUGH IT ON EVERY RENDER, NOT COPIED
/// INTO A STORED PROPERTY. A stored copy would be the value as it was when the sheet
/// was presented, and every keystroke after that would be written into the model and
/// then read back from a snapshot that never moved — a form that appears to ignore
/// typing. ``MessagingModel`` is `@Observable`, so reading it here is what re-renders
/// this view.
///
/// ⛔ NO `NavigationStack` AND NO TOOLBAR, matching ``CreateContactSheet``: a stack here
/// would be a second `Route.self` destination registration waiting to happen, and the
/// sheet has nowhere to navigate to.
struct MessagingAccountSheet: View {
    let model: MessagingModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    private var saving: Bool {
        model.accountSave.isSaving
    }

    var body: some View {
        ScrollView {
            // ⚠️ NOTHING IS DRAWN WITHOUT A DRAFT. The sheet is presented from the
            // draft's own presence, so this is the dismissal frame rather than a state
            // anyone sees.
            if let draft = model.draft {
                form(draft)
            }
        }
    }

    private func form(_ draft: MessagingDraft) -> some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.row) {
            Text(title(draft))
                .font(DistrictType.title)
                .foregroundStyle(colors.foreground)
            providerPicker(draft)
            sourcePicker(draft)
            SettingsField(label: "Label", text: field(draft, \.label), enabled: !saving)
            numbers(draft)
            credentials(draft)
            defaultToggle(draft)
            probeResult
            SettingsSaveNotice(state: model.accountSave)
            buttons(draft)
        }
        .padding(DistrictSpacing.gutter)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Pickers

    /// ⛔ CHANGING THE PROVIDER ON AN EXISTING ACCOUNT DISCARDS ITS STORED SECRETS
    /// SERVER-SIDE, so the picker's change also clears the typed ones: carrying Twilio's
    /// SID into a Sinch draft would offer to save a value under a field the new provider
    /// does not have, and the route carries an unknown key through as a PLAINTEXT
    /// identifier.
    private func providerPicker(_ draft: MessagingDraft) -> some View {
        labelled("Carrier") {
            Picker("Carrier", selection: providerSelection(draft)) {
                ForEach(MessagingCatalog.providers, id: \.self) { provider in
                    Text(MessagingCatalog.providerLabel(provider)).tag(provider)
                }
            }
            .pickerStyle(.segmented)
            .disabled(saving)
        }
    }

    /// ⚠️ OFFERED AND NEVER PRE-DECIDED. `managed` is an entitlement the server checks
    /// independently and refuses with a 403 naming support; nothing this client can read
    /// tells it whether the workspace has one.
    private func sourcePicker(_ draft: MessagingDraft) -> some View {
        labelled("Credentials") {
            Picker("Credentials", selection: field(draft, \.credentialSource)) {
                ForEach(MessagingCatalog.credentialSources, id: \.self) { source in
                    Text(Self.sourceLabel(source)).tag(source)
                }
            }
            .pickerStyle(.segmented)
            .disabled(saving)
        }
    }

    private func labelled(_ text: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            Text(text)
                .font(DistrictType.labelSmall)
                .foregroundStyle(colors.mutedForeground)
            content()
        }
    }

    // MARK: - Numbers

    /// ⛔ THE NUMBERS ARE SENT ONLY IF SOMEONE TYPES IN THIS BOX. Sending the rendered
    /// list on every save would rewrite the account's numbers from whatever this client
    /// happened to draw, and an emptied box would REMOVE them all and release their hub
    /// claims — the claims that stop another tenant sending as this workspace.
    private func numbers(_ draft: MessagingDraft) -> some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            SettingsField(
                label: "Phone numbers, one per line",
                text: numbersBinding(draft),
                enabled: !saving,
                multiline: true
            )
            Text(numbersNote(draft))
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
        }
    }

    // MARK: - Credentials

    private func credentials(_ draft: MessagingDraft) -> some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.row) {
            ForEach(MessagingCatalog.credentialFields(for: draft.provider)) { credential in
                SettingsField(
                    label: credential.label,
                    text: secretBinding(draft, credential.key),
                    enabled: !saving
                )
            }
            Text(credentialNote(draft))
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
        }
    }

    /// ⚠️ UNTICKED SENDS NOTHING RATHER THAN `false`. The route makes the first account
    /// of a workspace the default regardless, so a `false` would not prevent it and
    /// would claim an instruction nobody gave.
    private func defaultToggle(_ draft: MessagingDraft) -> some View {
        Toggle("Make this the default sender", isOn: field(draft, \.makeDefault))
            .font(DistrictType.bodySmall)
            .foregroundStyle(colors.foreground)
            .disabled(saving)
    }

    // MARK: - The probe

    /// ⛔ THREE OUTCOMES, THREE SENTENCES. A rejection is the carrier's own words about
    /// what was typed; an unreachable probe says nothing about the credentials at all
    /// and must not be worded as though it did.
    @ViewBuilder
    private var probeResult: some View {
        switch model.probe {
        case .idle:
            EmptyView()
        case .running:
            caption("Asking the carrier…", colors.mutedForeground)
        case let .passed(detail):
            caption(Self.passedText(detail), colors.success)
        case let .rejected(message):
            caption("Those credentials were refused: \(message)", colors.destructive)
        case let .unreachable(failure):
            caption("\(Self.probeUnreachablePrefix) \(failure.message)", colors.mutedForeground)
        }
    }

    private func caption(_ text: String, _ tint: Color) -> some View {
        Text(text)
            .font(DistrictType.caption)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// ⛔ TEST AND SAVE GATE ON ``MessagingModel/canEditNow`` AS WELL AS ON THE DRAFT,
    /// BECAUSE THE MODEL DOES AND THE TWO MUST NOT BE ABLE TO DISAGREE. `canEditNow` also
    /// requires `case .ready = load` and no probe in flight, so gating only on
    /// `draft.canSave`/`canTest` and `saving` would leave both buttons drawn ENABLED after
    /// a failed re-read (or during a probe) and doing nothing at all: no request, no
    /// message, no state change. A control that looks live and is not is worse than one
    /// that is greyed out, because there is nothing on screen to read.
    ///
    /// ⚠️ CANCEL IS GATED ONLY ON `saving`, DELIBERATELY. Whatever else is wrong, the
    /// operator must be able to close a form; the only thing that must not interrupt is
    /// a create already on the wire.
    private func buttons(_ draft: MessagingDraft) -> some View {
        HStack(spacing: DistrictSpacing.tight) {
            Button("Cancel", action: cancel)
                .buttonStyle(.districtGhost)
                .disabled(saving)
                .keyboardShortcut(.cancelAction)
            Button("Test", action: test)
                .buttonStyle(.districtSecondary)
                .disabled(!draft.canTest || !model.canEditNow)
            Button(saving ? "Saving…" : "Save", action: submit)
                .buttonStyle(.districtPrimary)
                .disabled(!draft.canSave || !model.canEditNow)
                .keyboardShortcut(.districtSubmit)
        }
    }

    // MARK: - Copy

    //
    // ⚠️ HOISTED TO `String` RATHER THAN WRITTEN AS A TERNARY INSIDE `Text(…)`, which is
    // the call ``DevicesView`` records for `.confirmationDialog`: a ternary of two
    // string LITERALS makes the type checker choose between the `LocalizedStringKey`
    // overload and the `StringProtocol` one at the call site, and that is exactly the
    // kind of inference question that produces an unreadable error.

    private func title(_ draft: MessagingDraft) -> String {
        draft.isCreate ? "Add carrier account" : "Edit carrier account"
    }

    private func numbersNote(_ draft: MessagingDraft) -> String {
        guard draft.numbersEdited else {
            return "Shown as stored. They are only sent if you change them."
        }
        return "These numbers will replace the account's current list when you save."
    }

    private func credentialNote(_ draft: MessagingDraft) -> String {
        guard draft.secretsRequired else { return SettingsCopy.messagingCredentialsRedacted }
        return "Every field is required, because this account has no stored credentials to keep."
    }

    private static func sourceLabel(_ source: String) -> String {
        source == "byok" ? "This workspace's own" : "Managed by Distronode"
    }

    private static func passedText(_ detail: String?) -> String {
        guard let detail else { return "Those credentials work." }
        return "Those credentials work: \(detail)"
    }

    private static let probeUnreachablePrefix =
        "We could not ask the carrier, so this says nothing about the credentials."

    // MARK: - Wiring

    /// ⚠️ ONE BINDING FACTORY OVER A WRITABLE KEY PATH RATHER THAN A SETTER PER FIELD.
    /// The form has nine of them, and nine setters would be nine places for the probe
    /// reset inside ``MessagingModel/editDraft(_:)`` to be forgotten.
    private func field<Value>(
        _ draft: MessagingDraft,
        _ path: WritableKeyPath<MessagingDraft, Value>
    ) -> Binding<Value> {
        Binding(
            get: { draft[keyPath: path] },
            set: { value in
                var next = draft
                next[keyPath: path] = value
                model.editDraft(next)
            }
        )
    }

    private func providerSelection(_ draft: MessagingDraft) -> Binding<String> {
        Binding(
            get: { draft.provider },
            set: { value in
                var next = draft
                next.provider = value
                next.secrets = [:]
                model.editDraft(next)
            }
        )
    }

    private func numbersBinding(_ draft: MessagingDraft) -> Binding<String> {
        Binding(
            get: { draft.phoneNumbers },
            set: { value in
                var next = draft
                next.phoneNumbers = value
                next.numbersEdited = true
                model.editDraft(next)
            }
        )
    }

    private func secretBinding(_ draft: MessagingDraft, _ key: String) -> Binding<String> {
        Binding(
            get: { draft.secrets[key] ?? "" },
            set: { value in
                var next = draft
                next.secrets[key] = value
                model.editDraft(next)
            }
        )
    }

    /// ⚠️ THE SHEET CLOSES ONLY ON A WRITE THAT LANDED. A failed one keeps the form and
    /// everything typed into it, because the refusal is often something the operator can
    /// act on (a number another workspace holds, a managed plan they do not have).
    ///
    /// ⚠️ THE SIGNAL IS THE DRAFT, NOT `case .saved`. A write that landed and could not
    /// be read back settles as ``SettingsSaveState/savedButStale(_:)``, which is still a
    /// stored account and still a finished form; matching only on `.saved` would leave
    /// the sheet sitting over one. ``MessagingModel`` clears the draft on both, so the
    /// draft is the honest question.
    private func submit() {
        Task {
            await model.saveAccount()
            if model.draft == nil {
                dismiss()
            }
        }
    }

    private func test() {
        Task { await model.testCredentials() }
    }

    private func cancel() {
        model.editDraft(nil)
        dismiss()
    }
}
