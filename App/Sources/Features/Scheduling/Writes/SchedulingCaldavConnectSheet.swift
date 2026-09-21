import SwiftUI

/// "Connect a CalDAV calendar" — preset or server URL, username, app password.
///
/// ⛔ THE PASSWORD BOX IS A `SecureField` AND ITS VALUE IS NEVER RENDERED BACK. It
/// is an app-specific password the host generated at their provider; it travels
/// once, into `calendar.caldav.connect`, and nothing here reads it again. The
/// accessibility identifier names the BOX, never the value, so a UI-test failure
/// message cannot quote it.
///
/// ⚠️ `districtField()` RATHER THAN THE PLATFORM STYLE, and `SecureField` is exactly
/// why the treatment is a `ViewModifier` rather than a `TextFieldStyle`: a style
/// reaches a secure field only by accident of the environment.
struct SchedulingCaldavConnectSheet: View {
    @Bindable var model: SchedulingCaldavConnectModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        SchedulingWriteSheetC(title: SchedulingWriteCopyC.caldavTitle) {
            presetPicker
            serverURLField
            usernameField
            passwordField
            messages
            buttons
        }
    }

    // MARK: - Fields

    private var presetPicker: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            Text(SchedulingWriteCopyC.caldavPresetLabel)
                .font(DistrictType.labelSmall)
                .foregroundStyle(colors.mutedForeground)
            Picker(SchedulingWriteCopyC.caldavPresetLabel, selection: $model.preset) {
                ForEach(SchedulingCaldavPresetC.allCases) { preset in
                    Text(preset.label).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .disabled(model.busy)
            .accessibilityIdentifier(A11yID.SchedulingCalendarWrites.caldavPreset)
            Text(model.preset.note)
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
        }
    }

    /// ⚠️ DRAWN ONLY FOR THE TWO PRESETS THAT NEED ONE. `caldav.Presets` holds
    /// `icloud` and `fastmail` at the far end and nothing else; asking a Fastmail
    /// host for a server address would be asking for a value the fork ignores.
    @ViewBuilder
    private var serverURLField: some View {
        if model.needsServerURL {
            SettingsField(
                label: SchedulingWriteCopyC.caldavServerUrlLabel,
                text: $model.serverURL,
                enabled: !model.busy
            )
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityIdentifier(A11yID.SchedulingCalendarWrites.caldavServerUrlField)
            fieldNote(SchedulingWriteCopyC.caldavServerUrlHint, field: .serverURL)
        }
    }

    private var usernameField: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            SettingsField(
                label: SchedulingWriteCopyC.caldavUsernameLabel,
                text: $model.username,
                enabled: !model.busy
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityIdentifier(A11yID.SchedulingCalendarWrites.caldavUsernameField)
            errorNote(for: .username)
        }
    }

    private var passwordField: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            Text(SchedulingWriteCopyC.caldavPasswordLabel)
                .font(DistrictType.labelSmall)
                .foregroundStyle(colors.mutedForeground)
            SecureField(SchedulingWriteCopyC.caldavPasswordLabel, text: $model.appPassword)
                .textContentType(.password)
                .disabled(model.busy)
                .districtField()
                .accessibilityIdentifier(A11yID.SchedulingCalendarWrites.caldavPasswordField)
            fieldNote(SchedulingWriteCopyC.caldavPasswordHint, field: .appPassword)
        }
    }

    // MARK: - Messages and controls

    @ViewBuilder
    private func fieldNote(_ hint: String, field: SchedulingCaldavFieldC) -> some View {
        if model.erroredField == field, let message = model.fieldMessage {
            caption(message, colors.destructive)
        } else {
            caption(hint, colors.mutedForeground)
        }
    }

    @ViewBuilder
    private func errorNote(for field: SchedulingCaldavFieldC) -> some View {
        if model.erroredField == field, let message = model.fieldMessage {
            caption(message, colors.destructive)
        }
    }

    @ViewBuilder
    private var messages: some View {
        if let failure = model.failure {
            SchedulingWriteFailureLineC(
                failure: failure,
                onRetry: submit,
                onDismiss: model.dismissFailure
            )
        }
        if let account = model.connectedAccountEmail {
            SchedulingWriteNoticeLineC(
                message: SchedulingWriteCopyC.caldavConnectedTo(account),
                onDismiss: model.dismissConfirmation
            )
        }
    }

    private var buttons: some View {
        HStack(spacing: DistrictSpacing.tight) {
            Button(SchedulingWriteCopyC.cancel) { dismiss() }
                .buttonStyle(.districtGhost)
                .disabled(model.busy)
            Button(
                model.busy ? SchedulingWriteCopyC.caldavConnecting : SchedulingWriteCopyC.caldavConnectAction,
                action: submit
            )
            .buttonStyle(.districtPrimary)
            .disabled(!model.canSubmit)
            .accessibilityIdentifier(A11yID.SchedulingCalendarWrites.caldavSubmit)
        }
    }

    private func caption(_ text: String, _ tint: Color) -> some View {
        Text(text)
            .font(DistrictType.caption)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func submit() {
        Task { await model.connect() }
    }
}
