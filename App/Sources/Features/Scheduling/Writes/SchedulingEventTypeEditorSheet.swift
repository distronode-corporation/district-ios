import SwiftUI

/// Create an event type, or edit the one that is open.
///
/// ⛔ THE CREATE FORM IS THREE FIELDS AND THE EDIT FORM IS FOURTEEN, FROM ONE
/// MODEL. `eventTypes.create` refuses fourteen of the fields `eventTypes.patch`
/// accepts, so drawing the full form on a create would offer controls whose every
/// use is a **400** naming a field the operator was invited to fill in.
///
/// ⛔ NO `NavigationStack` AND NO TOOLBAR, for ``CreateContactSheet``'s reason:
/// the buttons are in the sheet's own body and there is nowhere to navigate to.
///
/// ⚠️ THE SLUG IS SHOWN AND NOT EDITABLE. It is the public address of the booking
/// page and `eventTypes.patch` cannot change it — the schema's `slug` ADDRESSES
/// the row, so a different one patches something that does not exist.
struct SchedulingEventTypeEditorSheet: View {
    @Bindable var model: SchedulingEventTypeEditorModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DistrictSpacing.row) {
                Text(model.title)
                    .font(DistrictType.title)
                    .foregroundStyle(colors.foreground)
                nameField
                if model.isCreating {
                    durationField(label: SchedulingWriteCopy.durationLabel, text: $model.form.duration)
                    locationPicker
                } else {
                    editFields
                }
                messages
                SchedulingWriteButtons(
                    saveTitle: SchedulingWriteCopy.save,
                    saving: model.state.isSaving,
                    enabled: model.canSave,
                    saveIdentifier: A11yID.SchedulingWrites.editorSave,
                    onCancel: { dismiss() },
                    onSave: { save() }
                )
            }
            .padding(DistrictSpacing.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier(A11yID.SchedulingWrites.editorRoot)
    }

    // MARK: - Fields

    private var nameField: some View {
        SchedulingWriteField(label: SchedulingWriteCopy.nameLabel) {
            TextField(SchedulingWriteCopy.namePlaceholder, text: $model.form.name)
                .districtField()
                .disabled(model.state.isSaving)
                .accessibilityIdentifier(A11yID.SchedulingWrites.editorName)
        }
    }

    @ViewBuilder
    private var editFields: some View {
        bookingPage
        SchedulingWriteField(
            label: SchedulingWriteCopy.descriptionLabel,
            hint: SchedulingWriteCopy.descriptionHint
        ) {
            TextField(SchedulingWriteCopy.descriptionLabel, text: $model.form.description, axis: .vertical)
                .districtField()
                .disabled(model.state.isSaving)
                .accessibilityIdentifier(A11yID.SchedulingWrites.editorDescription)
        }
        durationField(label: SchedulingWriteCopy.durationLabel, text: $model.form.duration)
        SchedulingWriteField(
            label: SchedulingWriteCopy.intervalLabel,
            hint: SchedulingWriteCopy.intervalHint
        ) {
            TextField(SchedulingWriteCopy.intervalLabel, text: $model.form.interval)
                .districtField()
                .keyboardType(.numberPad)
                .disabled(model.state.isSaving)
                .accessibilityIdentifier(A11yID.SchedulingWrites.editorInterval)
        }
        locationPicker
        locationValueField
        toggles
        limits
    }

    private var bookingPage: some View {
        SchedulingWriteField(
            label: SchedulingWriteCopy.bookingPageLabel,
            hint: SchedulingWriteCopy.bookingPageHint
        ) {
            Text(model.slug ?? "")
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.mutedForeground)
        }
    }

    private func durationField(label: String, text: Binding<String>) -> some View {
        SchedulingWriteField(label: label, hint: SchedulingWriteCopy.durationHint) {
            TextField(label, text: text)
                .districtField()
                .keyboardType(.numberPad)
                .disabled(model.state.isSaving)
                .accessibilityIdentifier(A11yID.SchedulingWrites.editorDuration)
        }
    }

    /// ⚠️ A `Picker` RATHER THAN THE WEB'S TILES. The four choices are the same
    /// four; a tile grid on a phone-width sheet is a row of unreadable labels.
    private var locationPicker: some View {
        SchedulingWriteField(label: SchedulingWriteCopy.locationLabel) {
            Picker(SchedulingWriteCopy.locationLabel, selection: $model.form.location) {
                ForEach(model.locationChoices, id: \.value) { choice in
                    Text(choice.label).tag(choice.value)
                }
            }
            .pickerStyle(.menu)
            .disabled(model.state.isSaving)
            .accessibilityIdentifier(A11yID.SchedulingWrites.editorLocation)
        }
    }

    /// ⛔ DRAWN ONLY WHERE THE COLUMN MEANS SOMETHING. The scheduler generates the
    /// join link for `livekit`, `google_meet` and `teams`, so a value typed for one
    /// of them is at best ignored.
    @ViewBuilder
    private var locationValueField: some View {
        if let title = model.locationValueTitle {
            SchedulingWriteField(label: title) {
                TextField(title, text: $model.form.locationValue)
                    .districtField()
                    .disabled(model.state.isSaving)
                    .accessibilityIdentifier(A11yID.SchedulingWrites.editorLocationValue)
            }
        }
    }

    private var toggles: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.tight) {
            Toggle(SchedulingWriteCopy.activeToggle, isOn: $model.form.isActive)
            Toggle(SchedulingWriteCopy.listedToggle, isOn: $model.form.isPublic)
            Toggle(SchedulingWriteCopy.showTakenToggle, isOn: $model.form.showTakenSlots)
        }
        .font(DistrictType.bodySmall)
        .disabled(model.state.isSaving)
    }

    @ViewBuilder
    private var limits: some View {
        count(SchedulingWriteCopy.bufferBeforeLabel, SchedulingWriteCopy.bufferBeforeHint, $model.form.bufferBefore)
        count(SchedulingWriteCopy.bufferAfterLabel, SchedulingWriteCopy.bufferAfterHint, $model.form.bufferAfter)
        count(SchedulingWriteCopy.minNoticeLabel, SchedulingWriteCopy.minNoticeHint, $model.form.minNotice)
        count(SchedulingWriteCopy.maxFutureLabel, SchedulingWriteCopy.noLimitHint, $model.form.maxFutureDays)
        count(SchedulingWriteCopy.maxActiveLabel, SchedulingWriteCopy.noLimitHint, $model.form.maxActiveBookings)
    }

    private func count(_ label: String, _ hint: String, _ text: Binding<String>) -> some View {
        SchedulingWriteField(label: label, hint: hint) {
            TextField(label, text: text)
                .districtField()
                .keyboardType(.numberPad)
                .disabled(model.state.isSaving)
        }
    }

    /// ⚠️ THE CLIENT REFUSAL AND THE SERVER REFUSAL ARE BOTH SHOWN, IN THAT ORDER,
    /// and they are different slots on the model. One of them means nothing was
    /// sent; the other means something was and came back refused.
    private var messages: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            SchedulingWriteFailureStrip(message: model.validation)
            SchedulingWriteFailureStrip(message: model.state.failure?.message)
        }
        .accessibilityIdentifier(A11yID.SchedulingWrites.editorError)
    }

    private func save() {
        Task {
            await model.save()
            if case .saved = model.state {
                dismiss()
            }
        }
    }
}
