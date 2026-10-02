import DistrictData
import DistrictModel
import SwiftUI
import UIKit

/// "Add webhook" / "Edit webhook" — a URL, the events to send and the fields each
/// delivery carries.
///
/// ⛔ THE URL IS A FIELD ON CREATE AND A FACT ON EDIT, because `webhooks.patch`
/// takes only `events` and `fields`. An editable box that silently kept the old
/// value is worse than none: the person believes deliveries have moved.
///
/// ⚠️ THE ATTENDEE'S OWN FIELDS OPEN UNTICKED ON A NEW WEBHOOK. Sending a
/// stranger's name and email address to a third-party system should be a tick
/// somebody made, not a default they inherited — which is what the red badge on
/// those rows is for.
struct SchedulingWebhookEditorSheet: View {
    let model: SchedulingWebhookEditorModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    private var title: String {
        model.isEditing ? SchedulingWriteCopyC.webhookEditTitle : SchedulingWriteCopyC.webhookAddTitle
    }

    var body: some View {
        SchedulingWriteSheet(title: title) {
            urlSection
            droppedEventsNote
            eventsSection
            fieldsSection
            messages
            buttons
        }
        .sheet(item: mintedBinding) { secret in
            SchedulingWebhookSecretSheet(secret: secret)
        }
    }

    // MARK: - URL

    @ViewBuilder
    private var urlSection: some View {
        if let fixed = model.fixedURL {
            SchedulingWriteFact(label: SchedulingWriteCopyC.webhookUrlLabel, value: fixed)
            Text(SchedulingWriteCopyC.webhookUrlFixed)
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
        } else {
            Text(SchedulingWriteCopyC.webhookUrlHint)
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
            SettingsField(
                label: SchedulingWriteCopyC.webhookUrlLabel,
                text: urlBinding,
                enabled: !model.busy
            )
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityIdentifier(A11yID.SchedulingDeveloperWrites.webhookUrlField)
            if let urlError = model.urlError {
                caption(urlError, colors.destructive)
            }
        }
    }

    /// ⛔ SAID OUT LOUD RATHER THAN DROPPED QUIETLY. A row created before an event
    /// was renamed can carry a name this build does not know, the form cannot draw a
    /// box for it, and a save would not send it back.
    @ViewBuilder
    private var droppedEventsNote: some View {
        let dropped = model.droppedEvents
        if !dropped.isEmpty {
            caption(SchedulingWriteCopyC.webhookDroppedEvents(dropped), colors.warning)
        }
    }

    // MARK: - Events and fields

    private var eventsSection: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            Text(SchedulingWriteCopyC.webhookEventsLabel)
                .font(DistrictType.labelSmall)
                .foregroundStyle(colors.mutedForeground)
            Text(SchedulingWriteCopyC.webhookEventsHint)
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
            ForEach(SchedulingWebhookEvent.allCases, id: \.self) { event in
                SchedulingWriteToggleRow(
                    label: event.rawValue,
                    isOn: eventBinding(event),
                    enabled: !model.busy
                )
                .accessibilityIdentifier(A11yID.SchedulingDeveloperWrites.event(event.rawValue))
            }
            if let eventsError = model.eventsError {
                caption(eventsError, colors.destructive)
            }
        }
    }

    private var fieldsSection: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            Text(SchedulingWriteCopyC.webhookFieldsLabel)
                .font(DistrictType.labelSmall)
                .foregroundStyle(colors.mutedForeground)
            Text(SchedulingWriteCopyC.webhookFieldsHint)
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
            ForEach(SchedulingWebhookFieldsC.all, id: \.self) { field in
                SchedulingWriteToggleRow(
                    label: field,
                    isOn: fieldBinding(field),
                    badge: SchedulingDeveloperFormat.isPersonalDataField(field)
                        ? SchedulingWriteCopyC.webhookPersonalData
                        : nil,
                    enabled: !model.busy
                )
                .accessibilityIdentifier(A11yID.SchedulingDeveloperWrites.field(field))
            }
        }
    }

    // MARK: - Messages and controls

    @ViewBuilder
    private var messages: some View {
        if let failure = model.failure {
            SchedulingWriteFailureLine(
                failure: failure,
                onRetry: submit,
                onDismiss: model.dismissFailure
            )
        }
        if let notice = model.savedNotice {
            SchedulingWriteNoticeLine(message: notice, onDismiss: model.dismissNotice)
        }
    }

    private var buttons: some View {
        HStack(spacing: DistrictSpacing.tight) {
            Button(SchedulingWriteCopyC.cancel) { dismiss() }
                .buttonStyle(.districtGhost)
                .disabled(model.busy)
            Button(submitLabel, action: submit)
                .buttonStyle(.districtPrimary)
                .disabled(!model.canSubmit)
                .accessibilityIdentifier(A11yID.SchedulingDeveloperWrites.webhookSubmit)
        }
    }

    private var submitLabel: String {
        if model.busy {
            return SchedulingWriteCopyC.webhookSaving
        }
        return model.isEditing ? SchedulingWriteCopyC.webhookSaveAction : SchedulingWriteCopyC.webhookAddAction
    }

    private func caption(_ text: String, _ tint: Color) -> some View {
        Text(text)
            .font(DistrictType.caption)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Wiring

    private var urlBinding: Binding<String> {
        Binding(
            get: { model.draft.url },
            set: { model.draft.url = $0 }
        )
    }

    private func eventBinding(_ event: SchedulingWebhookEvent) -> Binding<Bool> {
        Binding(
            get: { model.draft.events.contains(event) },
            set: { on in
                if on {
                    model.draft.events.insert(event)
                } else {
                    model.draft.events.remove(event)
                }
            }
        )
    }

    private func fieldBinding(_ field: String) -> Binding<Bool> {
        Binding(
            get: { model.draft.fields.contains(field) },
            set: { on in
                if on {
                    model.draft.fields.insert(field)
                } else {
                    model.draft.fields.remove(field)
                }
            }
        )
    }

    private var mintedBinding: Binding<SchedulingWebhookSecretC?> {
        Binding(
            get: { model.minted },
            set: { value in
                if value == nil {
                    model.dismissMinted()
                }
            }
        )
    }

    private func submit() {
        Task { await model.submit() }
    }
}

/// The signing secret, shown once.
struct SchedulingWebhookSecretSheet: View {
    let secret: SchedulingWebhookSecretC

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        SchedulingWriteSheet(title: SchedulingWriteCopyC.webhookSecretTitle) {
            Text(SchedulingWriteCopyC.keyRevealWarning)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.foreground)
            Text(SchedulingWriteCopyC.webhookSecretNote(secret.url))
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
            Text(secret.secret)
                .font(DistrictType.bodySmall)
                .monospaced()
                .textSelection(.enabled)
                .foregroundStyle(colors.foreground)
                .padding(DistrictSpacing.tight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(colors.muted, in: RoundedRectangle(cornerRadius: DistrictRadius.control))
                .accessibilityIdentifier(A11yID.SchedulingDeveloperWrites.webhookSecretRevealed)
            HStack(spacing: DistrictSpacing.tight) {
                Button(SchedulingWriteCopyC.webhookSecretCopyAction, action: copy)
                    .buttonStyle(.districtSecondary)
                Button(SchedulingWriteCopyC.keyDone) { dismiss() }
                    .buttonStyle(.districtPrimary)
            }
        }
    }

    /// ⚠️ NO "copied" STATE, UNLIKE THE API KEY SHEET. There is nothing to confirm
    /// against: an API key is named, so a person can tell which one they copied,
    /// while a signing secret belongs to the one webhook this sheet is about.
    private func copy() {
        UIPasteboard.general.string = secret.secret
    }
}
